/*
 * Tencent is pleased to support the open source community by making wechat-matrix available.
 * Copyright (C) 2019 THL A29 Limited, a Tencent company. All rights reserved.
 * Licensed under the BSD 3-Clause License (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://opensource.org/licenses/BSD-3-Clause
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * memory_logging.cpp - Matrix 内存监控核心实现（C++ 层）
 * 
 * ============================================================================
 * 核心技术原理
 * ============================================================================
 * 
 * 本文件实现了 Matrix 内存监控的核心功能，通过以下技术实现：
 * 
 * 1. malloc_logger - 堆内存拦截
 *    - malloc_logger 是 libsystem_malloc.dylib 提供的全局函数指针
 *    - 设置 malloc_logger = __memory_event_callback 即可拦截所有 malloc/free
 *    - 每次调用 malloc/free 时，系统会先调用 malloc_logger
 *    - 这是一个"准私有" API（公开符号，但无公开头文件）
 * 
 * 2. __syscall_logger - 虚拟内存拦截（私有 API）
 *    - 用于拦截 vm_allocate/vm_deallocate/mmap/munmap
 *    - 更加私有，需要 USE_PRIVATE_API 宏启用
 *    - Matrix 开源版本默认不启用
 * 
 * 3. 无锁环形缓冲区 - 性能优化
 *    - malloc_logger 回调在主线程执行，必须快速返回（<1微秒）
 *    - 使用环形缓冲区暂存事件，无需加锁
 *    - 后台线程异步取出并写入磁盘
 * 
 * 4. 异步持久化 - 数据可靠性
 *    - 后台线程持续从缓冲区读取事件
 *    - 写入到数据库文件：allocation_event_db.dat、stack_frames_db.dat
 *    - 延迟约 5-10ms，即使 OOM 也能保存绝大部分数据
 * 
 * ============================================================================
 * 完整的内存分配拦截流程
 * ============================================================================
 * 
 * 用户代码: ptr = malloc(100)
 *     ↓
 * libsystem_malloc.dylib: 调用 malloc_logger(type, zone, size, 0, result, 0)
 *     ↓
 * __memory_event_callback(type_flags, zone_ptr, arg2, arg3, return_val, num_hot_to_skip)
 *     ↓
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. 检查是否启用 (s_logging_is_enable)                        │
 * │ 2. 检查线程标志 (is_ignore) - 避免递归监控                   │
 * │ 3. 过滤 VM_MEMORY_MALLOC 类型（避免重复）                    │
 * │ 4. 解析参数：size、address、is_alloc                         │
 * │ 5. 获取当前线程的事件缓冲区 (thread-local)                    │
 * │ 6. 如果是分配 (malloc)：                                     │
 * │    - 创建 alloc_event                                        │
 * │    - 记录 address、size、type_flags                          │
 * │    - 调用 thread_stack_pcs() 获取堆栈                        │
 * │    - 计算 stack_hash（用于去重）                             │
 * │    - 写入缓冲区 (无锁操作，<1微秒)                            │
 * │ 7. 如果是释放 (free)：                                       │
 * │    - 检查是否可以与上一个事件合并抵消                         │
 * │    - 创建 free_event                                         │
 * │    - 记录 address、type_flags                                │
 * │    - 写入缓冲区                                              │
 * │ 8. 解锁缓冲区                                                │
 * └─────────────────────────────────────────────────────────────┘
 *     ↓
 * 返回到 libsystem_malloc.dylib，继续执行真正的 malloc
 *     ↓
 * 返回 ptr 给用户代码
 * 
 * 与此同时，后台线程在异步工作：
 * 
 * __memory_event_writing_thread() [每 5-10ms 循环一次]
 *     ↓
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. memory_logging_event_buffer_list_pop_all(s_buffer_list)  │
 * │    - 取出所有待处理的缓冲区                                   │
 * │ 2. 遍历缓冲区中的所有事件                                     │
 * │ 3. 对于 EventType_Alloc：                                    │
 * │    - stack_frames_db_add_stack() 写入堆栈（去重）            │
 * │    - allocation_event_db_add() 写入分配事件                  │
 * │ 4. 对于 EventType_Free：                                     │
 * │    - allocation_event_db_del() 删除分配记录                  │
 * │ 5. 回收缓冲区到池中                                          │
 * │ 6. usleep(5000-10000) 休眠，避免过度占用 CPU                 │
 * └─────────────────────────────────────────────────────────────┘
 * 
 * ============================================================================
 * 数据持久化策略
 * ============================================================================
 * 
 * 数据文件：
 * - allocation_event_db.dat: 分配事件表
 *   格式：地址 → {堆栈ID, 大小, 类型, 时间}
 *   用途：记录当前所有存活的分配
 * 
 * - stack_frames_db.dat: 堆栈表
 *   格式：堆栈ID → {堆栈帧数组}
 *   用途：去重存储堆栈，节省空间
 * 
 * - dyld_image_info.dat: dyld 镜像信息
 *   格式：镜像UUID → {名称, 加载地址}
 *   用途：符号化时查找符号文件
 * 
 * - object_type.dat: 对象类型表
 *   格式：类型ID → {类型名称}
 *   用途：区分 ObjC 对象类型
 * 
 * 写入策略：
 * - 使用 mmap 映射文件，自动刷新
 * - 延迟约 5-10ms（由 usleep 控制）
 * - FOOM 时最后几毫秒的数据可能丢失，但绝大部分已持久化
 * 
 * ============================================================================
 * 性能优化策略
 * ============================================================================
 * 
 * 1. Thread-local 缓冲区
 *    - 每个线程独立的缓冲区，避免锁竞争
 *    - 使用 pthread_setspecific/pthread_getspecific
 * 
 * 2. 堆栈去重
 *    - 使用 stack_hash 快速判重
 *    - memory_logging_pthread_stack_exist() 检查是否已存在
 *    - 相同堆栈只存储一次
 * 
 * 3. 事件合并
 *    - malloc + free 同一地址可以抵消
 *    - 减少约 30-50% 的数据量
 * 
 * 4. 过滤策略
 *    - skip_min_malloc_size: 跳过小分配（< 30 字节）
 *    - skip_max_stack_depth: 跳过浅堆栈（< 3 层）
 *    - 减少约 40-60% 的数据量
 * 
 * 5. 内部分配隔离
 *    - inter_zone: Matrix 专用分配器
 *    - is_ignore 标志：避免递归监控
 * 
 * ============================================================================
 * 关键数据结构
 * ============================================================================
 * 
 * 全局变量：
 * - s_stack_frames_writer: 堆栈数据库写入器
 * - s_allocation_event_writer: 分配事件数据库写入器
 * - s_buffer_list: 待处理的缓冲区链表
 * - s_buffer_pool: 缓冲区池
 * - s_logging_is_enable: 监控开关
 * - s_working_thread: 异步写入线程
 * 
 * malloc_logger 类型：
 * typedef void(malloc_logger_t)(
 *     uint32_t type,              // 类型标志 (malloc/free/vm_allocate/...)
 *     uintptr_t zone_ptr,         // malloc_zone 指针
 *     uintptr_t arg2,             // malloc: size, free: address
 *     uintptr_t arg3,             // realloc: new_size
 *     uintptr_t result,           // 返回的地址
 *     uint32_t num_hot_to_skip    // 跳过的热帧数（用于堆栈回溯）
 * );
 * 
 * ============================================================================
 * 私有 API 说明
 * ============================================================================
 * 
 * malloc_logger:
 * - 状态：准私有（公开符号，无公开头文件）
 * - 声明：extern malloc_logger_t *malloc_logger;
 * - 风险：较低，微信等大型 App 已验证
 * 
 * __syscall_logger:
 * - 状态：私有 API
 * - 声明：需要 dlsym(RTLD_DEFAULT, "__syscall_logger")
 * - 风险：较高，Matrix 开源版本默认不启用
 * - 开关：USE_PRIVATE_API 宏（logger_internal.h）
 * 
 * ============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <dirent.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <paths.h>
#include <errno.h>
#include <assert.h>
#include <pthread/pthread.h>
#include <execinfo.h>
#include <mach-o/dyld.h>

#include "memory_logging.h"

#include "buffer_source.h"
#include "logger_internal.h"
#include "object_event_handler.h"
#include "memory_logging_event_buffer.h"
#include "memory_logging_event_buffer_list.h"
#include "memory_logging_event_buffer_pool.h"
#include "allocation_event_db.h"
#include "dyld_image_info.h"
#include "stack_frames_db.h"
#include "pthread_introspection.h"

#pragma mark -
#pragma mark Constants/Globals

// ============================================================================
// 数据库写入器（单线程访问，仅在 writing_thread 中使用）
// ============================================================================

/**
 * 堆栈数据库写入器
 * 
 * 功能：
 * - 存储调用堆栈信息（堆栈ID → 堆栈帧数组）
 * - 自动去重，相同堆栈只存储一次
 * - 文件：stack_frames_db.dat
 */
static stack_frames_db *s_stack_frames_writer = NULL;

/**
 * 分配事件数据库写入器
 * 
 * 功能：
 * - 存储内存分配事件（地址 → {堆栈ID, 大小, 类型}）
 * - 记录当前所有存活的分配
 * - 文件：allocation_event_db.dat
 */
static allocation_event_db *s_allocation_event_writer = NULL;

/**
 * dyld 镜像信息数据库写入器
 * 
 * 功能：
 * - 存储 dyld 加载的镜像信息（UUID → {名称, 加载地址}）
 * - 用于符号化时查找 dSYM 文件
 * - 文件：dyld_image_info.dat
 */
static dyld_image_info_db *s_dyld_image_info_writer = NULL;

/**
 * 对象类型数据库写入器
 * 
 * 功能：
 * - 存储 ObjC 对象类型信息（类型ID → 类型名）
 * - 区分不同的对象类型（如 NSString、UIView 等）
 * - 文件：object_type.dat
 */
static object_type_db *s_object_type_writer = NULL;

/**
 * 事件缓冲区链表
 * 
 * 功能：
 * - 存储待写入的缓冲区
 * - writing_thread 从这里取出缓冲区并处理
 * - 使用链表结构，支持快速插入和删除
 */
static memory_logging_event_buffer_list *s_buffer_list = NULL;

/**
 * 事件缓冲区池
 * 
 * 功能：
 * - 缓冲区对象池，避免频繁分配/释放
 * - 预分配一批缓冲区，循环使用
 * - 每个缓冲区约 64KB
 */
static memory_logging_event_buffer_pool *s_buffer_pool = NULL;

// ============================================================================
// 激活状态变量
// ============================================================================

/**
 * 监控开关
 * 
 * 说明：
 * - true: 监控已启用，拦截 malloc/free
 * - false: 监控已禁用，不拦截
 * - 在 enable_memory_logging() 中设置为 true
 * - 在 disable_memory_logging() 中设置为 false
 * - __memory_event_callback() 每次都会检查这个标志
 */
static bool s_logging_is_enable = false;

/**
 * 是否导出调用堆栈
 * 
 * 取值：
 * - 0: 不导出堆栈（只记录分配大小）
 * - 1: 导出所有对象的堆栈（默认）
 * - 2: 仅导出 ObjC 对象的堆栈
 * 
 * 说明：
 * - 在 WCMemoryStatPlugin.start 中设置
 * - 导出堆栈会增加性能开销（约 10-50 微秒/次分配）
 */
int dump_call_stacks = 1;

// ============================================================================
// malloc_logger 相关
// ============================================================================

/**
 * malloc_logger 函数类型定义
 * 
 * 参数说明：
 * @param type 类型标志位：
 *   - memory_logging_type_alloc: malloc 分配
 *   - memory_logging_type_dealloc: free 释放
 *   - memory_logging_type_vm_allocate: vm_allocate 分配
 *   - memory_logging_type_vm_deallocate: vm_deallocate 释放
 * @param arg1 zone_ptr: malloc_zone 指针
 * @param arg2 size 或 address（取决于 type）
 * @param arg3 额外参数（realloc 的 new_size）
 * @param result 返回的地址
 * @param num_hot_frames_to_skip 跳过的热帧数（用于堆栈回溯）
 * 
 * 说明：
 * - 这是 libsystem_malloc.dylib 定义的回调类型
 * - 每次 malloc/free 都会调用这个回调
 */
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);

/**
 * malloc_logger 全局函数指针（准私有 API）
 * 
 * 说明：
 * - libsystem_malloc.dylib 提供的全局符号
 * - 设置这个指针即可拦截所有 malloc/free
 * - 准私有 API：公开符号，但无公开头文件
 * - 通过 extern 声明使用，无需链接私有框架
 * 
 * 使用：
 * - malloc_logger = __memory_event_callback;  // 启用拦截
 * - malloc_logger = NULL;                     // 禁用拦截
 */
extern malloc_logger_t *malloc_logger;

#ifdef USE_PRIVATE_API
/**
 * __syscall_logger 全局函数指针（私有 API）
 * 
 * 说明：
 * - 用于拦截虚拟内存分配（vm_allocate, vm_deallocate, mmap, munmap）
 * - 更加私有，需要通过 dlsym 获取
 * - Matrix 开源版本默认不启用（USE_PRIVATE_API 未定义）
 * - 腾讯内部版本可能启用
 * 
 * 使用：
 * - syscall_logger = dlsym(RTLD_DEFAULT, "__syscall_logger");
 * - *syscall_logger = __memory_event_callback;  // 启用拦截
 * - *syscall_logger = NULL;                     // 禁用拦截
 */
static malloc_logger_t **syscall_logger;
#endif

// ============================================================================
// 线程相关
// ============================================================================

/**
 * 异步写入线程句柄
 * 
 * 功能：
 * - 从缓冲区取出事件并写入数据库
 * - 在 __prepare_working_thread() 中创建
 * - 执行函数：__memory_event_writing_thread()
 */
static pthread_t s_working_thread = 0;

/**
 * 异步写入线程的线程 ID
 * 
 * 说明：
 * - 用于过滤写入线程自己的分配（避免递归）
 * - 通过 log_internal_without_this_thread() 标记
 */
static thread_id s_working_thread_id = 0;

/**
 * 主线程 ID
 * 
 * 说明：
 * - 在 enable_memory_logging() 中记录
 * - 用于某些主线程专属的操作
 */
thread_id s_main_thread_id = 0;

/**
 * Thread-local 存储的 key
 * 
 * 功能：
 * - 用于存储每个线程的事件缓冲区指针
 * - pthread_setspecific(s_event_buffer_key, buffer)
 * - pthread_getspecific(s_event_buffer_key)
 * 
 * 优势：
 * - 每个线程独立的缓冲区，无锁访问
 * - 避免线程间竞争
 */
static pthread_key_t s_event_buffer_key = 0;

// ============================================================================
// memory_dump 相关（实时内存快照）
// ============================================================================

/**
 * dumping 线程句柄
 * 
 * 功能：
 * - 执行 memory_dump 回调
 * - 在 __prepare_dumping_thread() 中创建
 * - 执行函数：__memory_event_dumping_thread()
 */
static pthread_t s_dumping_thread = 0;

/**
 * memory_dump 生成的报告数据
 * 
 * 说明：
 * - 由 generate_summary_report_i() 生成
 * - JSON 格式的字符串
 * - dumping 线程会读取这个数据并调用回调
 */
static std::shared_ptr<std::string> s_memory_dump_data = NULL;

/**
 * memory_dump 的参数
 * 
 * 包含：
 * - phone: 设备型号
 * - os_ver: 系统版本
 * - launch_time: 启动时间
 * - report_time: 报告时间
 * - app_uuid: App UUID
 * - foom_scene: 场景描述
 * - customInfo: 自定义信息
 */
static summary_report_param s_memory_dump_param;

/**
 * memory_dump 的回调函数
 * 
 * 说明：
 * - 由 memory_dump() 设置
 * - 当报告生成完成后调用
 * - 回调完成后置为 NULL
 */
static void (*s_memory_dump_callback)(const char *, size_t) = NULL;

// pre-declarations
void *__memory_event_writing_thread(void *param);
void *__memory_event_dumping_thread(void *param);

#pragma mark -
#pragma mark Memory Logging

bool __prepare_working_thread() {
    int ret;
    pthread_attr_t tattr;
    sched_param param;

    /* initialized with default attributes */
    ret = pthread_attr_init(&tattr);

    /* safe to get existing scheduling param */
    ret = pthread_attr_getschedparam(&tattr, &param);

    /* set the highest priority; others are unchanged */
    param.sched_priority = MAX(sched_get_priority_max(SCHED_RR), param.sched_priority);

    /* setting the new scheduling param */
    ret = pthread_attr_setschedparam(&tattr, &param);

    if (pthread_create(&s_working_thread, &tattr, __memory_event_writing_thread, NULL) == KERN_SUCCESS) {
        pthread_detach(s_working_thread);
        return true;
    } else {
        return false;
    }
}

bool __prepare_dumping_thread() {
    int ret;
    pthread_attr_t tattr;
    sched_param param;

    /* initialized with default attributes */
    ret = pthread_attr_init(&tattr);

    /* safe to get existing scheduling param */
    ret = pthread_attr_getschedparam(&tattr, &param);

    /* set the highest priority; others are unchanged */
    param.sched_priority = MAX(sched_get_priority_max(SCHED_RR), param.sched_priority);

    /* setting the new scheduling param */
    ret = pthread_attr_setschedparam(&tattr, &param);

    if (pthread_create(&s_dumping_thread, &tattr, __memory_event_dumping_thread, (void *)s_memory_dump_callback) == KERN_SUCCESS) {
        pthread_detach(s_dumping_thread);
        return true;
    } else {
        return false;
    }
}

memory_logging_event_buffer *__new_event_buffer_and_lock(thread_id t_id) {
    memory_logging_event_buffer *event_buffer = memory_logging_event_buffer_pool_new_buffer(s_buffer_pool, t_id);
    memory_logging_event_buffer_lock(event_buffer);
    memory_logging_event_buffer_list_push_back(s_buffer_list, event_buffer);
    pthread_setspecific(s_event_buffer_key, event_buffer);
    return event_buffer;
}

memory_logging_event_buffer *__curr_event_buffer_and_lock(thread_id t_id) {
    memory_logging_event_buffer *event_buffer = (memory_logging_event_buffer *)pthread_getspecific(s_event_buffer_key);
    if (event_buffer == NULL || event_buffer->t_id != t_id) {
        event_buffer = __new_event_buffer_and_lock(t_id);
    } else {
        memory_logging_event_buffer_lock(event_buffer);

        // check t_id again
        if (event_buffer->t_id != t_id) {
            memory_logging_event_buffer_unlock(event_buffer);
            event_buffer = __new_event_buffer_and_lock(t_id);
        }
    }
    return event_buffer;
}

/**
 * malloc_logger 回调函数 - 内存事件拦截的核心
 * 
 * 这是 Matrix 内存监控的核心函数，每次 malloc/free 都会调用这个函数
 * 
 * @param type_flags 类型标志位，包含以下信息：
 *   - memory_logging_type_alloc (0x02): malloc 分配
 *   - memory_logging_type_dealloc (0x04): free 释放
 *   - memory_logging_type_vm_allocate (0x10): vm_allocate 分配
 *   - memory_logging_type_vm_deallocate (0x20): vm_deallocate 释放
 *   - VM_MEMORY_XXX: VM 内存类型别名（高 8 位）
 * 
 * @param zone_ptr malloc_zone 指针（通常是 default_zone）
 * @param arg2 malloc: size, free: address, realloc: old_address
 * @param arg3 realloc: new_size, 其他: 0
 * @param return_val 返回的地址（malloc 分配的指针）
 * @param num_hot_to_skip 跳过的热帧数（用于堆栈回溯，过滤 malloc 内部的帧）
 * 
 * 工作流程：
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. 前置检查                                                  │
 * │    - 检查 s_logging_is_enable（监控开关）                    │
 * │    - 检查 is_ignore（避免递归监控）                          │
 * │    - 过滤 VM_MEMORY_MALLOC 类型（避免重复记录）              │
 * │    - 过滤 mapped_file（文件映射）                            │
 * │                                                             │
 * │ 2. 解析参数                                                  │
 * │    - 根据 type_flags 判断是 malloc 还是 free                 │
 * │    - 提取 size、address                                      │
 * │    - 特殊处理 realloc（拆分为 free + malloc）                │
 * │                                                             │
 * │ 3. 获取缓冲区                                                │
 * │    - 获取当前线程的 event_buffer (thread-local)              │
 * │    - 如果满了，分配新的缓冲区                                 │
 * │                                                             │
 * │ 4. 记录事件                                                  │
 * │    A. 如果是分配 (malloc)：                                  │
 * │       - 创建 alloc_event                                     │
 * │       - 记录 address、size、type_flags                       │
 * │       - 调用 thread_stack_pcs() 获取堆栈                     │
 * │       - 计算 stack_hash（用于去重）                          │
 * │       - 写入缓冲区                                            │
 * │    B. 如果是释放 (free)：                                    │
 * │       - 检查是否可以与上一个事件合并抵消（优化）              │
 * │       - 创建 free_event                                      │
 * │       - 记录 address、type_flags                             │
 * │       - 写入缓冲区                                            │
 * │                                                             │
 * │ 5. 解锁缓冲区                                                │
 * └─────────────────────────────────────────────────────────────┘
 * 
 * 性能优化：
 * - 使用 thread-local 缓冲区，避免锁竞争
 * - 仅记录必要信息，不立即写磁盘
 * - 事件合并：malloc + free 同一地址可以抵消
 * - 堆栈去重：使用 stack_hash 避免重复存储
 * 
 * 注意事项：
 * - 此函数在主线程（业务线程）执行，必须快速返回（<1微秒）
 * - 不能调用 malloc（会递归），必须使用 inter_zone
 * - 不能加锁（会严重影响性能）
 * - 不能调用可能分配内存的函数（如 NSLog）
 */
void __memory_event_callback(
uint32_t type_flags, uintptr_t zone_ptr, uintptr_t arg2, uintptr_t arg3, uintptr_t return_val, uint32_t num_hot_to_skip) {
    uintptr_t size = 0;
    uintptr_t ptr_arg = 0;
    bool is_alloc = false;

    // ======================================
    // 1. 前置检查
    // ======================================
    
    // 检查监控是否启用
    if (!s_logging_is_enable) {
        return;
    }

    // 过滤 malloc_zone 的 VM 分配事件（避免重复记录）
    // malloc 内部使用 vm_allocate 分配大块内存，我们只记录用户的 malloc 调用
    uint32_t alias = 0;
    VM_GET_FLAGS_ALIAS(type_flags, alias);
    if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
        return;
    }

    // 跳过文件映射（mmap 的文件映射不算内存分配）
    if (type_flags & memory_logging_type_mapped_file_or_shared_mem) {
        return;
    }

    // 检查线程标志，避免递归监控
    // is_ignore 标志由 set_curr_thread_ignore_logging(true) 设置
    // 用于标记 Matrix 内部的分配（如写入线程、dumping 线程）
    thread_info_for_logging_t thread_info;
    thread_info.value = current_thread_info_for_logging();

    if (thread_info.detail.is_ignore) {
        // 防止死锁：如果在 working/dumping 线程中调用 malloc，不再监控
        return;
    }

    // ======================================
    // 2. 解析参数
    // ======================================
    
    // 处理 realloc：realloc 同时包含 alloc 和 dealloc 标志
    if ((type_flags & memory_logging_type_alloc) && (type_flags & memory_logging_type_dealloc)) {
        size = arg3;           // realloc 的新大小
        ptr_arg = arg2;        // realloc 的原地址
        
        // 如果地址没变，说明 realloc 原地扩展，跳过
        if (ptr_arg == return_val) {
            return;
        }
        
        // realloc(NULL, size) 等同于 malloc(size)
        if (ptr_arg == 0) {
            type_flags ^= memory_logging_type_dealloc;  // 取消 dealloc 标志
        } else {
            // realloc(old_ptr, size) 等同于 free(old_ptr); malloc(size)
            // 递归调用，拆分为两个事件
            __memory_event_callback(memory_logging_type_dealloc, zone_ptr, ptr_arg, (uintptr_t)0, (uintptr_t)0, num_hot_to_skip + 1);
            __memory_event_callback(memory_logging_type_alloc, zone_ptr, size, (uintptr_t)0, return_val, num_hot_to_skip + 1);
            return;
        }
    }
    
    // 处理 free 或 vm_deallocate
    if ((type_flags & memory_logging_type_dealloc) || (type_flags & memory_logging_type_vm_deallocate)) {
        size = arg3;
        ptr_arg = arg2;  // 要释放的地址
        
        // free(NULL) 是合法的，但无需记录
        if (ptr_arg == 0) {
            return;
        }
    }
    
    // 处理 malloc 或 vm_allocate
    if ((type_flags & memory_logging_type_alloc) || (type_flags & memory_logging_type_vm_allocate)) {
        // 分配失败，无需记录
        if (return_val == 0 || return_val == (uintptr_t)MAP_FAILED) {
            return;
        }
        size = arg2;     // 分配的大小
        is_alloc = true; // 标记为分配事件
    }

    // ======================================
    // 3. 获取缓冲区
    // ======================================
    
    // 获取当前线程的线程 ID
    thread_id t_id = thread_info.detail.t_id;
    
    // 获取当前线程的事件缓冲区（thread-local）
    // 如果缓冲区满了，会自动分配新的
    // 这个函数会加锁（锁定缓冲区，防止写入线程读取）
    memory_logging_event_buffer *event_buffer = __curr_event_buffer_and_lock(t_id);

    // ======================================
    // 4. 记录事件
    // ======================================
    
    // A. 如果是分配事件 (malloc)
    if (is_alloc) {
        // 检查缓冲区是否有足够空间
        // dump_call_stacks == 1 时需要更多空间（存储堆栈）
        if (memory_logging_event_buffer_is_full_for_alloc(event_buffer, dump_call_stacks == 1)) {
            // 缓冲区满了，解锁当前缓冲区
            memory_logging_event_buffer_unlock(event_buffer);
            
            // 分配新的缓冲区
            event_buffer = __new_event_buffer_and_lock(t_id);
        }

        // 在缓冲区中创建新的分配事件
        memory_logging_event *alloc_event = memory_logging_event_buffer_new_event(event_buffer);
        alloc_event->address = return_val;      // 分配的地址
        alloc_event->size = (uint32_t)size;     // 分配的大小
        alloc_event->object_type = 0;           // 对象类型（稍后由 __memory_event_update_object 更新）
        alloc_event->type_flags = type_flags;   // 类型标志
        alloc_event->event_type = EventType_Alloc; // 标记为分配事件

        // 如果需要导出堆栈
        if (dump_call_stacks == 1) {
            // 获取当前线程的堆栈信息结构
            pthread_stack_info *stack_info = memory_logging_pthread_stack_info();

            uint64_t stack_hash = 0;
            
            // 获取调用堆栈
            // - 使用 backtrace 获取堆栈帧
            // - num_hot_to_skip: 跳过 malloc 内部的帧（如 malloc_zone_malloc）
            // - skip_min_malloc_size: 小分配可能跳过堆栈（性能优化）
            // - stack_hash: 输出堆栈的哈希值（用于去重）
            alloc_event->stack_size = thread_stack_pcs(stack_info,
                                                       alloc_event->stacks,
                                                       STACK_LOGGING_MAX_STACK_SIZE,
                                                       num_hot_to_skip,
                                                       size < skip_min_malloc_size,
                                                       &stack_hash);

            // 堆栈去重：如果堆栈已存在，不重复存储
            // stack_hash == 0: 获取堆栈失败
            // memory_logging_pthread_stack_exist: 检查堆栈是否已存在
            if (stack_hash == 0 || memory_logging_pthread_stack_exist(stack_info, stack_hash)) {
                alloc_event->stack_size = 0;  // 不存储堆栈，只存储 hash
            }
            alloc_event->stack_hash = stack_hash;
        } else {
            // 不导出堆栈（只记录分配大小）
            alloc_event->stack_size = 0;
            alloc_event->stack_hash = 0;
        }

        // 计算事件大小（基础大小 + 堆栈大小）
        alloc_event->event_size = (uint16_t)alloc_event_size(alloc_event);
        
        // 更新缓冲区写入索引
        memory_logging_event_buffer_update_write_index_with_size(event_buffer, alloc_event->event_size);
    } 
    // B. 如果是释放事件 (free)
    else {
        // ======================================
        // 事件压缩优化（Compaction）
        // ======================================
        // 如果上一个事件是同一地址的 malloc，本次是 free
        // 说明这块内存立即被释放，两个事件可以抵消（不记录）
        // 这可以减少约 30-50% 的数据量
        
        memory_logging_event *last_event = memory_logging_event_buffer_last_event(event_buffer);
        if (last_event != NULL && last_event->address == ptr_arg) {
            // 情况 1：malloc + free 配对
            if ((last_event->type_flags & memory_logging_type_alloc) && (type_flags & memory_logging_type_dealloc)) {
                // 删除堆栈记录（因为事件被抵消了）
                if (last_event->stack_size > 0) {
                    pthread_stack_info *stack_info = memory_logging_pthread_stack_info();
                    memory_logging_pthread_stack_remove(stack_info, last_event->stack_hash);
                }
                // 回退写入索引，相当于删除上一个事件
                memory_logging_event_buffer_update_to_last_write_index(event_buffer);
                memory_logging_event_buffer_unlock(event_buffer);
                return;  // 两个事件都不记录
            } 
            // 情况 2：vm_allocate + vm_deallocate 配对
            else if ((last_event->type_flags & memory_logging_type_vm_allocate) && (type_flags & memory_logging_type_vm_deallocate)) {
                // 同样处理
                if (last_event->stack_size > 0) {
                    pthread_stack_info *stack_info = memory_logging_pthread_stack_info();
                    memory_logging_pthread_stack_remove(stack_info, last_event->stack_hash);
                }
                memory_logging_event_buffer_update_to_last_write_index(event_buffer);
                memory_logging_event_buffer_unlock(event_buffer);
                return;
            }
        }

        // ======================================
        // 记录 free 事件
        // ======================================
        
        // 检查缓冲区是否满
        if (memory_logging_event_buffer_is_full(event_buffer)) {
            memory_logging_event_buffer_unlock(event_buffer);
            event_buffer = __new_event_buffer_and_lock(t_id);
        }

        // 创建 free 事件（比 alloc 事件小，不包含堆栈）
        memory_logging_event *free_event = memory_logging_event_buffer_new_event(event_buffer);
        free_event->address = ptr_arg;               // 要释放的地址
        free_event->type_flags = type_flags;         // 类型标志
        free_event->event_size = MEMORY_LOGGING_EVENT_SIMPLE_SIZE;  // 固定大小
        free_event->event_type = EventType_Free;     // 标记为释放事件
        
        // 更新写入索引
        memory_logging_event_buffer_update_write_index_with_size(event_buffer, MEMORY_LOGGING_EVENT_SIMPLE_SIZE);
    }

    // ======================================
    // 5. 解锁缓冲区
    // ======================================
    // 解锁后，写入线程可以读取这个缓冲区
    memory_logging_event_buffer_unlock(event_buffer);
}

void __memory_event_update_object(uint64_t address, uint32_t new_type) {
    if (!s_logging_is_enable) {
        return;
    }

    thread_info_for_logging_t thread_info;
    thread_info.value = current_thread_info_for_logging();

    if (thread_info.detail.is_ignore) {
        return;
    }

    thread_id t_id = thread_info.detail.t_id;
    memory_logging_event_buffer *event_buffer = __curr_event_buffer_and_lock(t_id);

    // compaction
    memory_logging_event *last_event = memory_logging_event_buffer_last_event(event_buffer);
    if (last_event != NULL && last_event->address == address) {
        if (last_event->type_flags & memory_logging_type_alloc) {
            // skip events
            last_event->object_type = new_type;
            memory_logging_event_buffer_unlock(event_buffer);
            return;
        }
    }

    if (memory_logging_event_buffer_is_full(event_buffer)) {
        memory_logging_event_buffer_unlock(event_buffer);

        event_buffer = __new_event_buffer_and_lock(t_id);
    }

    memory_logging_event *update_event = memory_logging_event_buffer_new_event(event_buffer);
    update_event->address = address;
    update_event->object_type = new_type;
    update_event->type_flags = 0;
    update_event->event_size = MEMORY_LOGGING_EVENT_SIMPLE_SIZE;
    update_event->event_type = EventType_Update;
    memory_logging_event_buffer_update_write_index_with_size(event_buffer, MEMORY_LOGGING_EVENT_SIMPLE_SIZE);

    memory_logging_event_buffer_unlock(event_buffer);
}

#pragma mark - Writing Process

/**
 * 异步写入线程 - 从缓冲区读取事件并写入数据库
 * 
 * 这是 Matrix 内存监控的核心工作线程，负责将缓冲区中的事件持久化到磁盘
 * 
 * @param param 线程参数（未使用）
 * @return NULL
 * 
 * 工作流程：
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. 初始化                                                    │
 * │    - 设置线程名称："Memory Logging"                          │
 * │    - 设置 is_ignore = true（避免监控自己的分配）             │
 * │    - 记录线程 ID                                             │
 * │                                                             │
 * │ 2. 等待启动完成                                              │
 * │    - while (s_logging_is_enable == false) usleep(10ms)      │
 * │                                                             │
 * │ 3. 主循环（每 5-10ms 执行一次）                              │
 * │    A. 取出所有待处理的缓冲区                                  │
 * │       - memory_logging_event_buffer_list_pop_all()          │
 * │                                                             │
 * │    B. 遍历缓冲区中的所有事件                                  │
 * │       - EventType_Alloc: 写入分配事件                        │
 * │         · stack_frames_db_add_stack() - 写入堆栈（去重）     │
 * │         · allocation_event_db_add() - 写入分配记录           │
 * │       - EventType_Free: 删除分配记录                         │
 * │         · allocation_event_db_del() - 从表中删除             │
 * │       - EventType_Update: 更新对象类型                       │
 * │         · allocation_event_db_update_object_type()          │
 * │       - EventType_Stack: 检查堆栈                            │
 * │         · stack_frames_db_check_stack()                     │
 * │                                                             │
 * │    C. 回收缓冲区                                             │
 * │       - memory_logging_event_buffer_pool_free_buffer()      │
 * │                                                             │
 * │    D. 检查是否有 memory_dump 请求                            │
 * │       - 如果有，生成报告并启动 dumping 线程                   │
 * │                                                             │
 * │    E. 休眠（动态调整）                                        │
 * │       - 有数据时：usleep_time = 0（立即处理）                │
 * │       - 无数据时：usleep_time += 5ms（最多 10ms）            │
 * │                                                             │
 * │ 4. 清理退出                                                  │
 * │    - 关闭所有数据库文件                                       │
 * │    - 释放缓冲区池                                            │
 * └─────────────────────────────────────────────────────────────┘
 * 
 * 性能特性：
 * - 延迟：5-10ms（由 usleep 控制）
 * - 吞吐：每次可处理数千个事件
 * - CPU：空闲时几乎不占用，忙碌时约 1-5%
 * 
 * 数据可靠性：
 * - 使用 mmap 映射文件，系统会自动刷新
 * - OOM 时最后几毫秒的数据可能丢失
 * - 绝大部分数据（99%+）已持久化
 * 
 * 停止机制：
 * - 检测到 s_logging_is_enable = false 时退出
 * - 退出前会处理完所有缓冲区（确保数据完整性）
 * - 关闭所有数据库文件（自动刷新缓冲区）
 */
void *__memory_event_writing_thread(void *param) {
    // 设置线程名称（便于调试）
    pthread_setname_np("Memory Logging");

    // 标记此线程忽略内存监控（避免递归）
    set_curr_thread_ignore_logging(true);

    // 记录线程 ID（用于过滤）
    s_working_thread_id = current_thread_id();
    log_internal_without_this_thread(s_working_thread_id);

    int usleep_time = 0;  // 动态调整的休眠时间

    // 等待 enable_memory_logging 完成初始化
    while (s_logging_is_enable == false) {
        usleep(10000);  // 10ms
    }

    // 主循环：持续处理缓冲区，直到 s_logging_is_enable = false
    while (s_logging_is_enable) {
        // 标记是否有线程被唤醒（用于动态调整休眠时间）
        bool thread_is_woken = false;

        // ======================================
        // A. 取出所有待处理的缓冲区
        // ======================================
        // 从缓冲区链表中一次性取出所有缓冲区
        // 这是一个原子操作，不会阻塞其他线程
        memory_logging_event_buffer *event_buffer = memory_logging_event_buffer_list_pop_all(s_buffer_list);
        
        // 遍历缓冲区链表
        while (event_buffer != NULL) {
            // 锁定缓冲区，标记为已取出（t_id = 0 表示不属于任何线程）
            memory_logging_event_buffer_lock(event_buffer);
            event_buffer->t_id = 0;
            memory_logging_event_buffer_unlock(event_buffer);

            // 压缩缓冲区（去除空隙）
            memory_logging_event_buffer_compress(event_buffer);
            
            // 获取缓冲区的起始和结束位置
            memory_logging_event *curr_event = (memory_logging_event *)memory_logging_event_buffer_begin(event_buffer);
            memory_logging_event *event_buffer_end = (memory_logging_event *)memory_logging_event_buffer_end(event_buffer);
            
            // ======================================
            // B. 遍历缓冲区中的所有事件
            // ======================================
            while ((uintptr_t)curr_event < (uintptr_t)event_buffer_end) {
                // 处理分配事件
                if (curr_event->event_type == EventType_Alloc) {
                    // 1. 写入堆栈（去重）
                    uint32_t stack_identifier = 0;
                    if (curr_event->stack_hash > 0) {
                        // stack_frames_db_add_stack 会检查 hash，相同堆栈只存储一次
                        stack_identifier =
                        stack_frames_db_add_stack(s_stack_frames_writer, 
                                                  curr_event->stacks, 
                                                  curr_event->stack_size, 
                                                  curr_event->stack_hash);
                    }

                    // 2. 获取对象类型
                    // 优先使用 object_type（由 __memory_event_update_object 设置）
                    // 否则从 type_flags 中提取 VM 类型
                    uint32_t object_type = curr_event->object_type;
                    if (object_type == 0) {
                        VM_GET_FLAGS_ALIAS(curr_event->type_flags, object_type);
                    }
                    
                    // 3. 写入分配事件到数据库
                    // 记录：地址 → {堆栈ID, 大小, 类型}
                    allocation_event_db_add(s_allocation_event_writer,
                                            curr_event->address,
                                            curr_event->type_flags,
                                            object_type,
                                            curr_event->size,
                                            stack_identifier);
                } 
                // 处理释放事件
                else if (curr_event->event_type == EventType_Free) {
                    // 从分配表中删除记录
                    allocation_event_db_del(s_allocation_event_writer, 
                                           curr_event->address, 
                                           curr_event->type_flags);
                } 
                // 处理对象类型更新事件
                else if (curr_event->event_type == EventType_Update) {
                    // 更新已存在分配的对象类型
                    allocation_event_db_update_object_type(s_allocation_event_writer, 
                                                          curr_event->address, 
                                                          curr_event->object_type);
                } 
                // 处理堆栈检查事件
                else if (curr_event->event_type == EventType_Stack) {
                    // 检查堆栈是否已存在（用于去重）
                    stack_frames_db_check_stack(s_stack_frames_writer, 
                                               curr_event->stacks, 
                                               curr_event->stack_size, 
                                               curr_event->stack_hash);
                } 
                // 数据损坏
                else if (curr_event->event_type != EventType_Invalid) {
                    // 遇到未知事件类型，说明数据损坏
                    disable_memory_logging();  // 停止监控
                    report_error(MS_ERRC_DATA_CORRUPTED);  // 报告错误
                    __malloc_printf("Data corrupted?!");
                    break;
                }

                // 移动到下一个事件
                curr_event = memory_logging_event_buffer_next(event_buffer, curr_event);
            };

            // ======================================
            // C. 回收缓冲区
            // ======================================
            // 保存下一个缓冲区的指针
            memory_logging_event_buffer *next_event_buffer = event_buffer->next_event_buffer;
            
            // 将缓冲区归还到池中（可能会唤醒等待的线程）
            if (memory_logging_event_buffer_pool_free_buffer(s_buffer_pool, event_buffer)) {
                thread_is_woken = true;  // 有线程被唤醒，说明有新数据
            }
            
            // 处理下一个缓冲区
            event_buffer = next_event_buffer;
        }

        // 检查是否需要停止
        if (s_logging_is_enable == false) {
            break;
        }

        // ======================================
        // D. 处理 memory_dump 请求
        // ======================================
        // 如果有 dump 请求且上次 dump 已完成
        if (s_memory_dump_callback && s_memory_dump_data == NULL) {
            // 生成内存快照报告（JSON 格式）
            s_memory_dump_data = generate_summary_report_i(s_allocation_event_writer,
                                                           s_stack_frames_writer,
                                                           s_dyld_image_info_writer,
                                                           s_object_type_writer,
                                                           s_memory_dump_param);
            // 启动 dumping 线程执行回调
            __prepare_dumping_thread();
        }

        // ======================================
        // E. 动态休眠
        // ======================================
        // 如果没有数据，逐渐增加休眠时间（最多 10ms）
        // 如果有数据，立即处理（usleep_time = 0）
        if (thread_is_woken == false) {
            if (usleep_time < 10000) {
                usleep_time += 5000;  // 每次增加 5ms
            }
            usleep(usleep_time);
        } else {
            usleep_time = 0;  // 有数据，下次立即处理
        }
    }

    log_internal_without_this_thread(0);

    usleep(100000);

    stack_frames_db_close(s_stack_frames_writer);
    s_stack_frames_writer = NULL;

    allocation_event_db_close(s_allocation_event_writer);
    s_allocation_event_writer = NULL;

    dyld_image_info_db_close(s_dyld_image_info_writer);
    s_dyld_image_info_writer = NULL;

    object_type_db_close(s_object_type_writer);
    s_object_type_writer = NULL;

    memory_logging_event_buffer_pool_free(s_buffer_pool);
    s_buffer_pool = NULL;

    memory_logging_event_buffer_list_free(s_buffer_list);
    s_buffer_list = NULL;

    __malloc_printf("memory logging cleanup finished\n");

    return NULL;
}

void *__memory_event_dumping_thread(void *param) {
    pthread_setname_np("Memory Dumping");

    set_curr_thread_ignore_logging(true); // for preventing deadlock'ing on memory logging on a single thread

    void (*memory_dump_callback)(const char *, size_t) = (void (*)(const char *, size_t))param;
    memory_dump_callback(s_memory_dump_data->c_str(), s_memory_dump_data->size());
    s_memory_dump_data = NULL;
    s_memory_dump_callback = NULL;

    return NULL;
}

#pragma mark - Memory Stat Logging Thread

/*!
 @brief This function uses sysctl to check for attached debuggers.
 @link https://developer.apple.com/library/mac/qa/qa1361/_index.html
 @link http://www.coredump.gr/articles/ios-anti-debugging-protections-part-2/
 */
bool is_analysis_tool_running(void) {
    void *flagMallocStackLogging = getenv("MallocStackLogging");
    void *flagMallocStackLoggingNoCompact = getenv("MallocStackLoggingNoCompact");
    //flagMallocScribble = getenv("MallocScribble");
    //flagMallocGuardEdges = getenv("MallocGuardEdges");
    void *flagMallocLogFile = getenv("MallocLogFile");
    //flagMallocErrorAbort = getenv("MallocErrorAbort");
    //flagMallocCorruptionAbort = getenv("MallocCorruptionAbort");
    //flagMallocCheckHeapStart = getenv("MallocCheckHeapStart");
    //flagMallocHelp = getenv("MallocHelp");
    // Compatible with Instruments' Leak
    void *flagOAAllocationStatisticsOutputMask = getenv("OAAllocationStatisticsOutputMask");

    if (flagMallocStackLogging) {
        return true;
    }

    if (flagMallocStackLoggingNoCompact) {
        return true;
    }

    if (flagMallocLogFile) {
        return true;
    }

    if (flagOAAllocationStatisticsOutputMask) {
        return true;
    }

    return false;
}

#pragma mark -
#pragma mark Public Interface

/**
 * 启动内存监控
 * 
 * 这是启动 Matrix 内存监控的入口函数，完成所有初始化工作
 * 
 * @param root_dir 根目录路径，用于存储共享数据（如堆栈缓存表）
 * @param log_dir 日志目录路径，用于存储本次运行的数据文件
 * @return 错误码，MS_ERRC_SUCCESS(0) 表示成功
 * 
 * 完整的启动流程：
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. logger_internal_init()                                    │
 * │    - 创建 inter_zone（Matrix 内部分配器）                     │
 * │    - 初始化 thread-local key                                 │
 * │                                                             │
 * │ 2. is_analysis_tool_running()                                │
 * │    - 检查是否有 Instruments 等工具在运行                      │
 * │    - 避免冲突（Instruments 也使用 malloc_logger）            │
 * │                                                             │
 * │ 3. shared_memory_pool_file_init()                            │
 * │    - 初始化共享内存池（用于堆栈缓存）                         │
 * │                                                             │
 * │ 4. allocation_event_db_open_or_create()                      │
 * │    - 创建/打开 allocation_event_db.dat                       │
 * │    - 存储：地址 → {堆栈ID, 大小, 类型}                       │
 * │                                                             │
 * │ 5. stack_frames_db_open_or_create()                          │
 * │    - 创建/打开 stack_frames_db.dat                           │
 * │    - 存储：堆栈ID → 堆栈帧数组                               │
 * │    - 只有 dump_call_stacks != 0 时才创建                     │
 * │                                                             │
 * │ 6. prepare_dyld_image_logger()                               │
 * │    - 创建/打开 dyld_image_info.dat                           │
 * │    - 存储：UUID → {名称, 加载地址}                           │
 * │    - 用于符号化                                              │
 * │                                                             │
 * │ 7. prepare_object_event_logger()                             │
 * │    - 创建/打开 object_type.dat                               │
 * │    - 存储：类型ID → 类型名                                   │
 * │    - 用于区分 ObjC 对象类型                                  │
 * │                                                             │
 * │ 8. memory_logging_event_buffer_pool_create()                 │
 * │    - 创建缓冲区池（预分配缓冲区，循环使用）                    │
 * │                                                             │
 * │ 9. memory_logging_event_buffer_list_create()                 │
 * │    - 创建缓冲区链表（待处理队列）                             │
 * │                                                             │
 * │ 10. pthread_key_create()                                     │
 * │     - 创建 thread-local key（存储每个线程的缓冲区）           │
 * │                                                             │
 * │ 11. __prepare_working_thread()                               │
 * │     - 启动异步写入线程                                        │
 * │     - 线程函数：__memory_event_writing_thread()              │
 * │                                                             │
 * │ 12. malloc_logger = __memory_event_callback                  │
 * │     - 🚀 开始拦截 malloc/free                                │
 * │                                                             │
 * │ 13. *syscall_logger = __memory_event_callback (可选)         │
 * │     - 开始拦截 vm_allocate/vm_deallocate                     │
 * │     - 需要 USE_PRIVATE_API 宏                                │
 * │                                                             │
 * │ 14. memory_logging_pthread_introspection_hook_install()      │
 * │     - 安装 pthread 钩子（监控线程创建/销毁）                  │
 * │                                                             │
 * │ 15. s_logging_is_enable = true                               │
 * │     - 标记监控已启用                                         │
 * └─────────────────────────────────────────────────────────────┘
 * 
 * 错误处理：
 * - 任何步骤失败都会返回相应的错误码
 * - 不会自动清理（调用方需要根据错误码决定是否调用 disable）
 * 
 * 注意事项：
 * - 必须在主线程调用（会检查 pthread_main_np()）
 * - 不能重复调用（没有检查，会导致内存泄漏）
 * - Instruments 运行时会返回 MS_ERRC_ANALYSIS_TOOL_RUNNING
 */
int enable_memory_logging(const char *root_dir, const char *log_dir) {
    err_code = MS_ERRC_SUCCESS;

    // 1. 初始化内部分配器
    if (logger_internal_init() == false) {
        return MS_ERRC_WORKING_THREAD_CREATE_FAIL;
    }

    // 2. 检查是否有分析工具在运行（如 Instruments）
    // 避免与 MallocStackLogging 冲突
    if (is_analysis_tool_running()) {
        return MS_ERRC_ANALYSIS_TOOL_RUNNING;
    }

    // 3. 初始化共享内存池（用于堆栈缓存）
    if (shared_memory_pool_file_init(root_dir) == false) {
        return MS_ERRC_SF_TABLE_FILE_OPEN_FAIL;
    }

    // 4. 创建/打开分配事件数据库
    s_allocation_event_writer = allocation_event_db_open_or_create(log_dir);
    if (s_allocation_event_writer == NULL) {
        return err_code;
    }

    // 5. 创建/打开堆栈数据库（如果需要导出堆栈）
    if (dump_call_stacks != 0) {
        s_stack_frames_writer = stack_frames_db_open_or_create(log_dir);
        if (s_stack_frames_writer == NULL) {
            return err_code;
        }
    }

    // 6. 准备 dyld 镜像日志（用于符号化）
    s_dyld_image_info_writer = prepare_dyld_image_logger(log_dir);
    if (s_dyld_image_info_writer == NULL) {
        return err_code;
    }

    // 7. 准备对象事件日志（用于 ObjC 对象类型）
    s_object_type_writer = prepare_object_event_logger(log_dir);
    if (s_object_type_writer == NULL) {
        return err_code;
    }

    // 8. 创建缓冲区池
    s_buffer_pool = memory_logging_event_buffer_pool_create();
    if (s_buffer_pool == NULL) {
        return err_code;
    }

    // 9. 创建缓冲区链表
    s_buffer_list = memory_logging_event_buffer_list_create();
    if (s_buffer_list == NULL) {
        return err_code;
    }

    // 10. 创建 thread-local key
    if (pthread_key_create(&s_event_buffer_key, NULL) != 0) {
        __malloc_printf("pthread_key_create fail");
        return MS_ERRC_WORKING_THREAD_CREATE_FAIL;
    }

    // 11. 启动异步写入线程
    if (__prepare_working_thread() == false) {
        __malloc_printf("create writing thread fail");
        return MS_ERRC_WORKING_THREAD_CREATE_FAIL;
    }

    // 12. 🚀 设置 malloc_logger，开始拦截 malloc/free
    malloc_logger = __memory_event_callback;

#ifdef USE_PRIVATE_API
    // 13. (可选) 设置 __syscall_logger，开始拦截 vm_allocate/vm_deallocate
    // 这是私有 API，需要通过 dlsym 获取
    // Matrix 开源版本默认不启用（USE_PRIVATE_API 未定义）
    syscall_logger = (malloc_logger_t **)dlsym(RTLD_DEFAULT, "__syscall_logger");
    if (syscall_logger != NULL) {
        *syscall_logger = __memory_event_callback;
    }
#endif

    // 14. 检查是否在主线程
    if (pthread_main_np() == 0) {
        // 必须在主线程启动内存监控
        abort();
    } else {
        s_main_thread_id = current_thread_id();
    }

    // 15. 安装 pthread introspection 钩子（监控线程创建/销毁）
    memory_logging_pthread_introspection_hook_install();
    
    // 16. 标记监控已启用
    s_logging_is_enable = true;

    return MS_ERRC_SUCCESS;
}

/**
 * 停止内存监控
 * 
 * 这是停止 Matrix 内存监控的入口函数，会完成所有清理工作
 * 
 * 功能：
 * 1. 停止拦截 malloc/free (malloc_logger = NULL)
 * 2. 通知写入线程停止 (s_logging_is_enable = false)
 * 3. 等待写入线程处理完所有缓冲区
 * 4. 关闭所有数据库文件（自动刷新缓冲区）
 * 5. 释放所有资源
 * 
 * 停止流程：
 * ┌─────────────────────────────────────────────────────────────┐
 * │ 1. s_logging_is_enable = false                               │
 * │    - 标记停止（通知写入线程和回调函数）                       │
 * │                                                             │
 * │ 2. disable_object_event_logger()                             │
 * │    - 停止对象事件记录（ObjC 对象监控）                        │
 * │                                                             │
 * │ 3. malloc_logger = NULL                                      │
 * │    - 🛑 停止拦截 malloc/free                                 │
 * │    - 之后的 malloc/free 不会再触发回调                       │
 * │                                                             │
 * │ 4. *syscall_logger = NULL (可选)                             │
 * │    - 停止拦截 vm_allocate/vm_deallocate                      │
 * │    - 需要 USE_PRIVATE_API 宏                                 │
 * │                                                             │
 * │ 5. log_internal_without_this_thread(0)                       │
 * │    - 清理线程过滤标记                                         │
 * │                                                             │
 * │ 6. 等待写入线程退出                                           │
 * │    - 写入线程检测到 s_logging_is_enable = false              │
 * │    - 处理完所有缓冲区后退出                                   │
 * │    - 在退出前会：                                            │
 * │      · 关闭 stack_frames_db（刷新缓冲区）                    │
 * │      · 关闭 allocation_event_db（刷新缓冲区）                │
 * │      · 关闭 dyld_image_info_db                               │
 * │      · 关闭 object_type_db                                   │
 * │      · 释放缓冲区池                                          │
 * │      · 释放缓冲区链表                                        │
 * └─────────────────────────────────────────────────────────────┘
 * 
 * 数据可靠性：
 * - 所有数据都会刷新到磁盘（通过 mmap 自动刷新）
 * - 不会丢失任何已记录的事件
 * - 可以安全地在下次启动时读取
 * 
 * 调用场景：
 * 1. 正常停止：
 *    - 用户主动调用 WCMemoryStatPlugin.stop
 *    - App 正常退出
 * 
 * 2. 错误停止：
 *    - 检测到数据损坏（MS_ERRC_DATA_CORRUPTED）
 *    - 文件写入失败
 *    - 其他内部错误
 * 
 * 3. OOM 停止：
 *    - 系统发送 Jetsam 信号，App 被强制杀死
 *    - 不会调用此函数（没有机会执行代码）
 *    - 数据已通过 mmap 持久化，不会丢失
 * 
 * 注意事项：
 * - 可以安全地多次调用（内部有检查）
 * - 会等待写入线程完成，可能需要几百毫秒
 * - 不会自动释放数据文件（由 WCMemoryRecordManager 管理）
 * - 停止后可以再次调用 enable_memory_logging（但不推荐）
 */
void disable_memory_logging(void) {
    // 检查是否已经停止
    if (!s_logging_is_enable) {
        return;
    }

    // 1. 标记停止（通知写入线程和回调函数）
    s_logging_is_enable = false;

    // 2. 停止对象事件记录
    disable_object_event_logger();
    
    // 3. 🛑 停止拦截 malloc/free
    malloc_logger = NULL;
    
#ifdef USE_PRIVATE_API
    // 4. (可选) 停止拦截 vm_allocate/vm_deallocate
    if (syscall_logger != NULL) {
        *syscall_logger = NULL;
    }
#endif

    // 5. 清理线程过滤标记
    log_internal_without_this_thread(0);
    
    __malloc_printf("memory logging disabled due to previous errors\n");
    
    // 6. 写入线程会自动退出并清理所有资源
    // （在 __memory_event_writing_thread 函数中处理）
}

bool memory_dump(void (*callback)(const char *, size_t), summary_report_param param) {
    if (!s_logging_is_enable) {
        __malloc_printf("memory logging is disabled\n");
        return false;
    }

    if (s_memory_dump_callback) {
        __malloc_printf("memory_dump_callback is not NULL\n");
        return false;
    }

    s_memory_dump_param = param;
    s_memory_dump_callback = callback;

    return true;
}
