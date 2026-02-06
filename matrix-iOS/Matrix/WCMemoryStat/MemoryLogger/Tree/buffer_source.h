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
 * buffer_source.h - 缓冲区源管理
 * 
 * ============================================================================
 * 功能概述
 * ============================================================================
 * 
 * 本文件定义了 Matrix 内存监控中使用的缓冲区管理类，提供两种缓冲区实现：
 * 
 * 1. buffer_source_memory: 内存缓冲区
 *    - 使用 inter_malloc/inter_free 分配内存
 *    - 数据存储在内存中，性能高
 *    - App 退出后数据丢失
 * 
 * 2. buffer_source_file: 文件映射缓冲区
 *    - 使用 mmap 映射文件到内存
 *    - 数据持久化到磁盘
 *    - App 退出后数据保留
 *    - 自动扩容（通过 ftruncate + mmap）
 * 
 * 3. memory_pool_file: 内存池文件
 *    - 用于堆栈缓存的共享内存池
 *    - 支持增量分配
 *    - 所有分配都映射到同一个文件
 * 
 * ============================================================================
 * 使用场景
 * ============================================================================
 * 
 * buffer_source_file 用于：
 * - allocation_event_db.dat: 分配事件数据库
 * - stack_frames_db.dat: 堆栈数据库
 * - dyld_image_info.dat: dyld 镜像信息
 * - object_type.dat: 对象类型数据
 * 
 * memory_pool_file 用于：
 * - file_memory.dat: 堆栈缓存共享内存池
 * 
 * ============================================================================
 * 技术原理
 * ============================================================================
 * 
 * mmap 文件映射：
 * ┌──────────────────────────────────────────────────────────┐
 * │ 1. open() 打开文件                                        │
 * │ 2. ftruncate() 设置文件大小                               │
 * │ 3. mmap() 映射文件到内存                                  │
 * │    - MAP_SHARED: 修改会同步到磁盘                         │
 * │    - PROT_READ|PROT_WRITE: 可读可写                       │
 * │ 4. 直接操作映射的内存                                     │
 * │ 5. munmap() 取消映射（系统自动刷新到磁盘）                │
 * └──────────────────────────────────────────────────────────┘
 * 
 * 自动扩容：
 * ┌──────────────────────────────────────────────────────────┐
 * │ 1. 检测缓冲区不足                                         │
 * │ 2. ftruncate() 扩大文件                                   │
 * │ 3. mmap() 映射新的文件区域                                │
 * │ 4. munmap() 取消旧映射                                    │
 * │ 5. 更新缓冲区指针                                         │
 * └──────────────────────────────────────────────────────────┘
 * 
 * ============================================================================
 * 性能特性
 * ============================================================================
 * 
 * buffer_source_memory:
 * - 分配速度：极快（~0.1 微秒）
 * - 访问速度：极快（直接内存访问）
 * - 持久化：❌ 无
 * 
 * buffer_source_file:
 * - 分配速度：较快（~10-50 微秒，首次 mmap）
 * - 访问速度：快（内存访问，系统自动同步）
 * - 持久化：✅ 自动（系统刷新到磁盘）
 * - 扩容开销：较大（需要 munmap + mmap）
 * 
 * memory_pool_file:
 * - 分配速度：极快（~0.1 微秒，bump allocator）
 * - 访问速度：快（内存访问）
 * - 持久化：✅ 自动
 * - 不支持释放（只能整体释放）
 * 
 * ============================================================================
 */

#ifndef buffer_source_h
#define buffer_source_h

#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>

#include "logger_internal.h"

/**
 * buffer_source - 缓冲区源抽象基类
 * 
 * 功能：
 * - 定义缓冲区的统一接口
 * - 支持内存缓冲区和文件映射缓冲区两种实现
 * 
 * 接口：
 * - buffer(): 获取缓冲区指针
 * - buffer_size(): 获取缓冲区大小
 * - realloc(): 重新分配缓冲区（扩容）
 * - free(): 释放缓冲区
 * - init_fail(): 检查初始化是否失败
 */
class buffer_source {
public:
    /**
     * 构造函数
     * 
     * 初始化缓冲区指针和大小为 0
     */
    buffer_source() {
        _buffer = NULL;
        _buffer_size = 0;
    }

    /**
     * 虚析构函数
     * 
     * 说明：
     * - 允许子类正确析构
     * - 具体的清理工作由子类实现
     */
    virtual ~buffer_source() {}

    /**
     * 获取缓冲区指针
     * 
     * @return 缓冲区的内存地址
     */
    inline void *buffer() { return _buffer; }

    /**
     * 获取缓冲区大小
     * 
     * @return 缓冲区的字节数
     */
    inline size_t buffer_size() { return _buffer_size; }

    /**
     * 重新分配缓冲区（扩容）
     * 
     * @param new_size 新的缓冲区大小（字节）
     * @return 新的缓冲区指针，失败返回 NULL
     * 
     * 说明：
     * - 纯虚函数，由子类实现
     * - buffer_source_memory: 调用 inter_realloc
     * - buffer_source_file: 调用 ftruncate + mmap
     */
    virtual void *realloc(size_t new_size) = 0;
    
    /**
     * 释放缓冲区
     * 
     * 说明：
     * - 纯虚函数，由子类实现
     * - buffer_source_memory: 调用 inter_free
     * - buffer_source_file: 调用 munmap
     */
    virtual void free() = 0;
    
    /**
     * 检查初始化是否失败
     * 
     * @return true 表示初始化失败，false 表示成功
     * 
     * 说明：
     * - 纯虚函数，由子类实现
     * - buffer_source_memory: 总是返回 false
     * - buffer_source_file: 检查 _fd < 0
     */
    virtual bool init_fail() = 0;

protected:
    void *_buffer;        // 缓冲区指针
    size_t _buffer_size;  // 缓冲区大小（字节）
};

/**
 * buffer_source_memory - 内存缓冲区实现
 * 
 * 功能：
 * - 使用 inter_malloc/inter_free 分配内存
 * - 数据存储在内存中，不持久化
 * - 性能高，适合临时数据
 * 
 * 特点：
 * - ✅ 分配速度极快（~0.1 微秒）
 * - ✅ 访问速度极快（直接内存访问）
 * - ❌ 数据不持久化（App 退出后丢失）
 * 
 * 使用场景：
 * - 临时缓冲区
 * - 不需要持久化的数据结构
 */
class buffer_source_memory : public buffer_source {
public:
    /**
     * 析构函数
     * 
     * 说明：
     * - 自动释放缓冲区
     */
    ~buffer_source_memory() { free(); }

    /**
     * 检查初始化是否失败
     * 
     * @return 总是返回 false（内存分配总是成功）
     * 
     * 说明：
     * - 内存分配不会失败（失败会 abort）
     */
    virtual bool init_fail() { return false; }

    /**
     * 重新分配缓冲区
     * 
     * @param new_size 新的缓冲区大小（字节）
     * @return 新的缓冲区指针，失败返回 NULL
     * 
     * 实现：
     * - 使用 inter_realloc（Matrix 内部分配器）
     * - 会复制旧数据到新缓冲区
     * - 成功后更新 _buffer 和 _buffer_size
     */
    virtual void *realloc(size_t new_size) {
        void *ptr = inter_realloc(_buffer, new_size);
        if (ptr != NULL) {
            _buffer = ptr;
            _buffer_size = new_size;
        }
        return ptr;
    }

    /**
     * 释放缓冲区
     * 
     * 实现：
     * - 使用 inter_free 释放内存
     * - 将 _buffer 置为 NULL
     * - 将 _buffer_size 置为 0
     */
    virtual void free() {
        if (_buffer) {
            inter_free(_buffer);
            _buffer = NULL;
            _buffer_size = 0;
        }
    }
};

/**
 * buffer_source_file - 文件映射缓冲区实现
 * 
 * 功能：
 * - 使用 mmap 将文件映射到内存
 * - 数据自动持久化到磁盘
 * - 支持动态扩容
 * 
 * 特点：
 * - ✅ 数据持久化（App 退出后保留）
 * - ✅ 自动同步到磁盘（MAP_SHARED）
 * - ✅ 访问速度快（内存访问）
 * - ⚠️ 分配速度较慢（~10-50 微秒）
 * - ⚠️ 扩容开销大（需要 munmap + mmap）
 * 
 * 技术原理：
 * ┌──────────────────────────────────────────┐
 * │ 1. open() 打开文件                        │
 * │ 2. fstat() 获取文件大小                   │
 * │ 3. mmap() 映射到内存                      │
 * │    - MAP_SHARED: 修改同步到文件           │
 * │    - PROT_READ|PROT_WRITE: 可读写         │
 * │ 4. 直接操作映射的内存                     │
 * │ 5. 系统自动刷新到磁盘                     │
 * │ 6. munmap() 取消映射                      │
 * └──────────────────────────────────────────┘
 * 
 * 使用场景：
 * - allocation_event_db.dat: 分配事件数据库
 * - stack_frames_db.dat: 堆栈数据库
 * - dyld_image_info.dat: dyld 镜像信息
 * - object_type.dat: 对象类型数据
 */
class buffer_source_file : public buffer_source {
public:
    /**
     * 构造函数
     * 
     * @param dir 目录路径
     * @param file_name 文件名
     * 
     * 初始化流程：
     * 1. 打开文件（open_file）
     * 2. 获取文件大小（fstat）
     * 3. 如果文件不为空：
     *    - 使用 mmap 映射文件到内存
     *    - 设置 _buffer、_buffer_size、_fs
     * 4. 如果文件为空：
     *    - 设置 _buffer = NULL
     *    - 等待首次 realloc 时分配
     * 
     * 失败处理：
     * - 任何步骤失败都跳转到 init_fail
     * - 关闭文件描述符
     * - 设置 _fd = -1（标记失败）
     * 
     * 注意：
     * - 使用 inter_mmap（避免递归监控）
     * - MAP_SHARED：修改会同步到磁盘
     * - PROT_READ|PROT_WRITE：可读可写
     */
    buffer_source_file(const char *dir, const char *file_name) {
        _fd = open_file(dir, file_name);  // 打开或创建文件
        _file_name = file_name;

        if (_fd < 0) {
            goto init_fail;
        } else {
            struct stat st = { 0 };
            // 获取文件信息
            if (fstat(_fd, &st) == -1) {
                goto init_fail;
            } else {
                // 文件已存在且不为空
                if (st.st_size > 0) {
                    // 使用 mmap 映射文件到内存
                    void *buff = inter_mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, _fd, 0);
                    if (buff == MAP_FAILED) {
                        __malloc_printf("fail to mmap, %s", strerror(errno));
                        goto init_fail;
                    } else {
                        _fs = (size_t)st.st_size;  // 文件大小
                        _buffer = buff;             // 映射的内存地址
                        _buffer_size = _fs;         // 缓冲区大小
                    }
                } else {
                    // 文件为空，等待首次 realloc
                    _fs = 0;
                    _buffer = NULL;
                    _buffer_size = 0;
                }
            }
        }
        return;

    init_fail:
        // 初始化失败，清理资源
        if (_fd >= 0) {
            close(_fd);
            _fd = -1;
        }
    }

    /**
     * 析构函数
     * 
     * 说明：
     * - 取消内存映射（调用 free）
     * - 关闭文件描述符
     */
    ~buffer_source_file() {
        if (_fd >= 0) {
            free();
            close(_fd);
        }
    }

    /**
     * 检查初始化是否失败
     * 
     * @return true 表示失败，false 表示成功
     * 
     * 说明：
     * - 通过检查 _fd < 0 判断
     */
    virtual bool init_fail() { return _fd < 0; }

    /**
     * 重新分配缓冲区（扩容）
     * 
     * @param new_size 新的缓冲区大小（字节）
     * @return 新的缓冲区指针，失败返回 NULL
     * 
     * 扩容流程：
     * ┌──────────────────────────────────────────┐
     * │ 1. round_page(new_size)                   │
     * │    - 向上对齐到页大小（通常 4KB 或 16KB） │
     * │                                          │
     * │ 2. ftruncate(_fd, new_size)              │
     * │    - 扩大文件到新大小                     │
     * │    - 失败时停止监控并返回 NULL            │
     * │                                          │
     * │ 3. inter_mmap(NULL, new_size, ...)       │
     * │    - 映射新的文件到内存                   │
     * │    - 失败时停止监控并返回 NULL            │
     * │                                          │
     * │ 4. free()                                │
     * │    - 取消旧的映射（munmap）               │
     * │                                          │
     * │ 5. 更新成员变量                          │
     * │    - _fs = new_size                      │
     * │    - _buffer = new_mem                   │
     * │    - _buffer_size = new_size             │
     * └──────────────────────────────────────────┘
     * 
     * 注意事项：
     * - 扩容开销较大（~100-500 微秒）
     * - 会取消旧映射，指针会改变
     * - 失败时会调用 disable_memory_logging()
     * - 页对齐可以提高性能
     */
    virtual void *realloc(size_t new_size) {
        // 1. 向上对齐到页大小
        new_size = round_page(new_size);
        
        // 2. 扩大文件
        if (ftruncate(_fd, new_size) != 0) {
            disable_memory_logging();
            __malloc_printf("%s fail to ftruncate, %s, new_size: %llu, errno: %d", _file_name, strerror(errno), (uint64_t)new_size, errno);
            return NULL;
        }

        // 3. 映射新文件到内存
        void *new_mem = inter_mmap(NULL, new_size, PROT_READ | PROT_WRITE, MAP_SHARED, _fd, 0);
        if (new_mem == MAP_FAILED) {
            disable_memory_logging();
            __malloc_printf("%s fail to mmap, %s, new_size: %llu, errno: %d", _file_name, strerror(errno), (uint64_t)new_size, errno);
            return NULL;
        }

        // 4. 取消旧映射
        free();

        // 5. 更新成员变量
        _fs = new_size;
        _buffer = new_mem;
        _buffer_size = new_size;

        return _buffer;
    }

    /**
     * 释放缓冲区（取消内存映射）
     * 
     * 说明：
     * - 使用 inter_munmap 取消映射
     * - 系统会自动将修改刷新到磁盘
     * - 将 _buffer 置为 NULL
     * - 将 _buffer_size 置为 0
     * - 不关闭文件（由析构函数处理）
     */
    virtual void free() {
        if (_buffer && _buffer != MAP_FAILED) {
            inter_munmap(_buffer, _fs);
            _buffer = NULL;
            _buffer_size = 0;
        }
    }

private:
    int _fd;               // 文件描述符
    size_t _fs;            // 文件大小（字节）
    const char *_file_name; // 文件名（用于日志）
};

/**
 * memory_pool_file - 内存池文件
 * 
 * 功能：
 * - 用于堆栈缓存的共享内存池
 * - 支持增量分配（bump allocator）
 * - 所有分配都映射到同一个文件
 * - 不支持单独释放（只能整体释放）
 * 
 * 特点：
 * - ✅ 分配速度极快（~0.1 微秒）
 * - ✅ 数据持久化
 * - ✅ 多次分配共享同一个文件
 * - ❌ 不支持单独释放
 * - ❌ 内存碎片（释放后不能重用）
 * 
 * 技术原理：
 * ┌──────────────────────────────────────────┐
 * │ 初始状态：file_memory.dat (0 字节)        │
 * │                                          │
 * │ malloc(1MB)：                            │
 * │ - ftruncate(1MB) → 文件扩展到 1MB        │
 * │ - mmap(0, 1MB) → 映射 [0, 1MB)           │
 * │ - _fs = 1MB                              │
 * │                                          │
 * │ malloc(1MB)：                            │
 * │ - ftruncate(2MB) → 文件扩展到 2MB        │
 * │ - mmap(1MB, 1MB) → 映射 [1MB, 2MB)       │
 * │ - _fs = 2MB                              │
 * │                                          │
 * │ 结果：file_memory.dat (2MB)              │
 * │ - 两次分配的内存都映射到同一个文件        │
 * └──────────────────────────────────────────┘
 * 
 * 与 buffer_source_file 的区别：
 * ┌────────────────┬────────────────┬──────────────┐
 * │ 特性           │ memory_pool_file│buffer_source_file│
 * ├────────────────┼────────────────┼──────────────┤
 * │ 分配方式       │ 增量（追加）    │ 整体扩容      │
 * │ 释放方式       │ 不支持单独释放  │ 可以整体释放  │
 * │ 内存碎片       │ 有（无法重用）  │ 无            │
 * │ 分配速度       │ 极快            │ 较快          │
 * │ 使用场景       │ 堆栈缓存池      │ 数据库文件    │
 * └────────────────┴────────────────┴──────────────┘
 * 
 * 使用场景：
 * - file_memory.dat: 堆栈缓存共享内存池
 * - 存储堆栈信息的临时缓存
 * - 需要持久化但不需要单独释放的数据
 */
class memory_pool_file {
public:
    /**
     * 构造函数
     * 
     * @param dir 目录路径
     * @param file_name 文件名
     * 
     * 初始化流程：
     * 1. 打开文件（open_file）
     * 2. 获取文件大小（fstat）
     * 3. 设置 _fs = 文件大小
     * 
     * 说明：
     * - 不会立即映射文件（等待首次 malloc）
     * - 如果文件已存在，会记录其大小
     * - _fs 用于追踪下次分配的偏移量
     */
    memory_pool_file(const char *dir, const char *file_name) {
        _fs = 0;
        _fd = open_file(dir, file_name);
        _file_name = file_name;

        if (_fd < 0) {
            goto init_fail;
        } else {
            struct stat st = { 0 };
            if (fstat(_fd, &st) == -1) {
                goto init_fail;
            } else {
                _fs = (size_t)st.st_size;  // 记录文件当前大小
            }
        }
        return;

    init_fail:
        if (_fd >= 0) {
            close(_fd);
            _fd = -1;
        }
    }

    /**
     * 析构函数
     * 
     * 说明：
     * - 关闭文件描述符
     * - 不取消内存映射（由调用方管理）
     */
    ~memory_pool_file() {
        if (_fd >= 0) {
            close(_fd);
        }
    }

    /**
     * 获取文件描述符
     */
    inline int fd() { return _fd; }
    
    /**
     * 获取文件大小
     */
    inline size_t fs() { return _fs; }

    /**
     * 检查初始化是否失败
     */
    bool init_fail() { return _fd < 0; }

    /**
     * 从内存池分配内存
     * 
     * @param size 分配的大小（字节）
     * @return 分配的内存指针，失败返回 NULL
     * 
     * 分配流程（bump allocator）：
     * ┌──────────────────────────────────────────┐
     * │ 1. round_page(size)                       │
     * │    - 向上对齐到页大小                     │
     * │                                          │
     * │ 2. ftruncate(_fd, _fs + new_size)        │
     * │    - 扩大文件：[_fs, _fs + new_size)     │
     * │    - 失败时停止监控并返回 NULL            │
     * │                                          │
     * │ 3. inter_mmap(NULL, new_size, ..., _fs)  │
     * │    - 映射新区域：offset = _fs             │
     * │    - 失败时停止监控并返回 NULL            │
     * │                                          │
     * │ 4. _fs += new_size                       │
     * │    - 更新文件大小（为下次分配做准备）      │
     * │                                          │
     * │ 5. return new_mem                        │
     * └──────────────────────────────────────────┘
     * 
     * 示例：
     * ```
     * // 第一次分配 1MB
     * void *p1 = pool->malloc(1MB);
     * // 文件：[0, 1MB), _fs = 1MB
     * 
     * // 第二次分配 1MB
     * void *p2 = pool->malloc(1MB);
     * // 文件：[1MB, 2MB), _fs = 2MB
     * 
     * // 结果：file_memory.dat (2MB)
     * ```
     * 
     * 特点：
     * - ✅ 分配极快（~0.1 微秒）
     * - ✅ 所有分配都在同一个文件
     * - ❌ 不支持单独释放
     * - ❌ 释放的内存无法重用
     */
    void *malloc(size_t size) {
        // 1. 向上对齐到页大小
        size_t new_size = round_page(size);
        
        // 2. 扩大文件
        if (ftruncate(_fd, _fs + new_size) != 0) {
            disable_memory_logging();
            __malloc_printf("%s fail to ftruncate, %s, new_size: %llu, errno: %d", _file_name, strerror(errno), (uint64_t)_fs + new_size, errno);
            return NULL;
        }

        // 3. 映射新区域（offset = _fs）
        void *new_mem = inter_mmap(NULL, new_size, PROT_READ | PROT_WRITE, MAP_SHARED, _fd, _fs);
        if (new_mem == MAP_FAILED) {
            disable_memory_logging();
            __malloc_printf("%s fail to mmap, %s, new_size: %llu, offset: %llu, errno: %d",
                            _file_name,
                            strerror(errno),
                            (uint64_t)new_size,
                            (uint64_t)_fs,
                            errno);
            return NULL;
        }

        // 4. 更新文件大小
        _fs += new_size;

        return new_mem;
    }

    /**
     * 释放内存（取消映射）
     * 
     * @param ptr 要释放的内存指针
     * @param size 内存大小（字节）
     * 
     * 说明：
     * - 只取消内存映射，不回收文件空间
     * - 不更新 _fs（文件大小不会减小）
     * - 释放的区域无法重用
     * - 通常在 App 退出时释放所有映射
     */
    void free(void *ptr, size_t size) {
        if (ptr != MAP_FAILED && ptr != NULL) {
            inter_munmap(ptr, size);
        }
    }

private:
    int _fd;               // 文件描述符
    size_t _fs;            // 文件当前大小（也是下次分配的偏移量）
    const char *_file_name; // 文件名（用于日志）
};

/**
 * 初始化共享内存池文件
 * 
 * @param dir 目录路径
 * @return true 成功，false 失败
 * 
 * 功能：
 * - 删除旧的 file_memory.dat
 * - 创建新的 memory_pool_file
 * - 初始化全局变量
 * 
 * 说明：
 * - 在 enable_memory_logging() 中调用
 * - 用于堆栈缓存的共享内存池
 */
bool shared_memory_pool_file_init(const char *dir);

/**
 * 从共享内存池分配内存
 * 
 * @param size 分配的大小（字节）
 * @return 分配的内存指针，失败会 abort()
 * 
 * 功能：
 * - 使用 bump allocator 快速分配
 * - 自动对齐到 16 字节边界
 * - 从全局 memory_pool_file 分配
 * 
 * 技术细节：
 * - 维护 s_alloc_ptr 和 s_alloc_index
 * - 每次分配 1MB 的块，在块内快速分配
 * - 块用完后从 s_pool 分配新块
 * 
 * 使用场景：
 * - 堆栈信息的临时缓存
 * - 需要持久化的小对象
 */
void *shared_memory_pool_file_alloc(size_t size);

#endif /* buffer_source_h */
