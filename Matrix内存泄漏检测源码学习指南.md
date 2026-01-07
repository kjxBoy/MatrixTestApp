# Matrix 内存泄漏检测源码学习指南

> 从零开始理解 iOS 内存监控的底层实现原理

## 📚 目录

- [1. 学习准备](#1-学习准备)
- [2. 整体架构](#2-整体架构)
- [3. 学习路径](#3-学习路径)
  - [3.1 入口层 - ObjC 插件](#31-入口层---objc-插件)
  - [3.2 核心层 - C++ 监控引擎](#32-核心层---c-监控引擎)
  - [3.3 数据层 - 存储与分析](#33-数据层---存储与分析)
- [4. 核心技术原理](#4-核心技术原理)
- [5. 实战调试技巧](#5-实战调试技巧)
- [6. 进阶阅读](#6-进阶阅读)

---

## 1. 学习准备

### 1.1 前置知识

建议先掌握这些概念：

- ✅ **C/C++ 基础**：指针、内存管理、多线程
- ✅ **Objective-C**：对象生命周期、Runtime
- ✅ **iOS 内存管理**：ARC、引用计数、autorelease pool
- ✅ **系统调用**：malloc/free、vm_allocate/vm_deallocate
- ✅ **调试工具**：Instruments、lldb

### 1.2 推荐阅读材料

阅读顺序：

1. 📖 **已完成的文档**：
   - `iOS内存监控技术实现.md` - 了解整体架构
   - `Matrix异步堆栈追溯技术实现.md` - 理解堆栈捕获

2. 🔗 **微信技术文章**：
   - [iOS微信内存监控](https://wetest.qq.com/labs/367) - 必读

3. 📚 **Apple 官方文档**：
   - [Memory Usage Performance Guidelines](https://developer.apple.com/library/content/documentation/Performance/Conceptual/ManagingMemory/)

### 1.3 工具准备

- Xcode（用于浏览源码和调试）
- VS Code 或其他代码编辑器（方便全局搜索）
- Hopper Disassembler（可选，用于分析二进制）

---

## 2. 整体架构

### 2.1 分层架构图

```
┌─────────────────────────────────────────────────────────────┐
│                     应用层 (Application)                      │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              MatrixHandler.mm                         │   │
│  │  - 初始化内存监控插件                                  │   │
│  │  - 处理上报回调                                        │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                   插件层 (Plugin Layer)                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         WCMemoryStatPlugin.mm (ObjC)                  │   │
│  │  - start() / stop()                                   │   │
│  │  - 配置管理（skipMinMallocSize, skipMaxStackDepth）   │   │
│  │  - FOOM 检测和上报                                     │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│              内存监控引擎 (Memory Logging Engine)             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           memory_logging.cpp (C++)                    │   │
│  │  • enable_memory_logging()    ⭐ 启动监控             │   │
│  │  • __memory_event_callback()  ⭐ 拦截分配             │   │
│  │  • malloc_logger              ⭐ 堆内存监控           │   │
│  │  • __syscall_logger           ⭐ 虚拟内存监控         │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         nsobject_hook.mm (ObjC Hook)                  │   │
│  │  • hook +[NSObject alloc]                             │   │
│  │  • 记录 OC 对象类名                                    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                  数据存储层 (Storage Layer)                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │      allocation_event_db.cpp                          │   │
│  │  • 存储存活对象的分配信息                               │   │
│  │  • 地址 → 大小、堆栈 ID 映射                           │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │      stack_frames_db.cpp                              │   │
│  │  • 堆栈去重和存储                                       │   │
│  │  • 堆栈 ID → 堆栈帧数组映射                            │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │      dyld_image_info_db.cpp                           │   │
│  │  • 记录动态库加载信息                                   │   │
│  │  • 符号化需要的 slide 信息                             │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 数据流向

```
App 分配内存 (malloc/vm_allocate/[NSObject alloc])
    ↓
系统回调监控函数 (malloc_logger/__syscall_logger/hook)
    ↓
__memory_event_callback() - 记录到线程本地缓冲区
    ↓
后台写入线程 - 异步写入到数据库文件
    ↓
allocation_event_db + stack_frames_db
    ↓
FOOM 发生时 / 手动 dump
    ↓
生成内存报告 (JSON)
    ↓
上报到服务器 / 符号化分析
```

---

## 3. 学习路径

### 3.1 入口层 - ObjC 插件

**时间：30-60 分钟**  
**难度：⭐⭐**

#### 📁 核心文件

1. **`MatrixTestApp/Matrix/MatrixHandler.mm`**

**关键代码：第 84-95 行**

```objc
WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];
memoryStatPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
[curBuilder addPlugin:memoryStatPlugin];

[matrix addMatrixBuilder:curBuilder];

// 启动插件
[memoryStatPlugin start];

m_msPlugin = memoryStatPlugin;
```

**学习要点：**
- ✅ 理解插件的生命周期（初始化 → 配置 → 启动 → 停止）
- ✅ 了解如何通过 `MatrixPluginListenerDelegate` 接收上报
- ✅ 查看 FOOM 检测的触发条件

---

2. **`matrix-iOS/Matrix/WCMemoryStat/MemoryStatPlugin/WCMemoryStatPlugin.mm`**

**关键函数：**

##### ① `- (id)init` (第 72-88 行)

```objc
- (id)init {
    self = [super init];
    if (self) {
        m_recordManager = [[WCMemoryRecordManager alloc] init];
        
        // 获取上次运行的记录
        m_lastRecord = [m_recordManager getRecordByLaunchTime:...];
        
        // 延迟检测 FOOM
        [self deplayTryReportOOMInfo];
    }
    return self;
}
```

**学习要点：**
- 📌 理解如何通过 `MatrixAppRebootAnalyzer` 判断上次是否 FOOM
- 📌 查看 `WCMemoryRecordManager` 如何管理历史记录

##### ② `- (BOOL)start` (第 220-267 行) ⭐ **核心启动**

```objc
- (BOOL)start {
    // 1. 检查调试状态
    if ([MatrixDeviceInfo isBeingDebugged]) {
        return NO;  // 调试模式下不启动
    }

    // 2. 应用配置
    skip_max_stack_depth = self.pluginConfig.skipMaxStackDepth;
    skip_min_malloc_size = self.pluginConfig.skipMinMallocSize;
    dump_call_stacks = self.pluginConfig.dumpCallStacks;

    // 3. 创建记录
    m_currRecord = [[MemoryRecordInfo alloc] init];
    
    // 4. 🔥 启动 C++ 内存监控引擎
    int ret = enable_memory_logging(rootPath.UTF8String, dataPath.UTF8String);
    
    return ret == MS_ERRC_SUCCESS;
}
```

**学习要点：**
- 🎯 **第 256 行的 `enable_memory_logging()`** 是进入 C++ 层的入口
- 🎯 理解三个配置参数的作用
- 🎯 为什么调试模式下不能启动？（与 malloc_logger 冲突）

##### ③ `- (void)deplayTryReportOOMInfo` (第 94-123 行)

```objc
- (void)deplayTryReportOOMInfo {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), ..., ^{
        // 判断上次退出是否是 FOOM
        if ([MatrixAppRebootAnalyzer lastRebootType] == 
            MatrixAppRebootTypeAppForegroundOOM) {
            
            // 获取上次的内存记录
            MemoryRecordInfo *lastInfo = [self recordOfLastRun];
            
            // 生成报告并上报
            NSData *reportData = [lastInfo generateReportDataWithCustomInfo:...];
            [self reportIssue:issue];
        }
    });
}
```

**学习要点：**
- 📊 FOOM 检测原理：排除法（排除正常退出、崩溃等情况）
- 📊 报告是如何从持久化数据生成的

---

3. **`matrix-iOS/Matrix/WCMemoryStat/MemoryStatPlugin/WCMemoryStatConfig.h`**

**配置参数详解：**

| 参数 | 默认值 | 作用 | 调优建议 |
|------|--------|------|---------|
| `skipMinMallocSize` | PAGE_SIZE (16KB) | 小于此值的分配不记录堆栈 | 开发: 4KB<br>生产: 32KB |
| `skipMaxStackDepth` | 8 | 堆栈前 N 层包含 App 代码时记录 | 开发: 15<br>生产: 8 |
| `dumpCallStacks` | 1 | 0=不dump, 1=全部, 2=仅OC | 生产环境建议 2 |
| `reportStrategy` | Auto | 自动/手动上报 | 看需求 |

**学习任务：**
- [ ] 修改配置参数，观察内存占用变化
- [ ] 理解过滤策略对性能的影响

---

### 3.2 核心层 - C++ 监控引擎

**时间：2-4 小时**  
**难度：⭐⭐⭐⭐**

这是最核心、最复杂的部分，建议分多次学习。

#### 📁 核心文件 #1：`memory_logging.cpp`

**文件位置：** `matrix-iOS/Matrix/WCMemoryStat/MemoryLogger/memory_logging.cpp`

**代码行数：** ~660 行

---

#### 🔍 学习点 1：关键全局变量（第 52-86 行）

```cpp
// 数据库
static stack_frames_db *s_stack_frames_writer = NULL;
static allocation_event_db *s_allocation_event_writer = NULL;
static dyld_image_info_db *s_dyld_image_info_writer = NULL;
static object_type_db *s_object_type_writer = NULL;

// 线程本地缓冲区
static memory_logging_event_buffer_list *s_buffer_list = NULL;
static memory_logging_event_buffer_pool *s_buffer_pool = NULL;

// 监控开关
static bool s_logging_is_enable = false;

// 堆栈 dump 策略
int dump_call_stacks = 1;

// 🔥 核心：系统内存分配监控回调
extern malloc_logger_t *malloc_logger;
static malloc_logger_t **syscall_logger;

// 工作线程
static pthread_t s_working_thread = 0;
static thread_id s_working_thread_id = 0;
```

**理解要点：**
- 💡 为什么要用线程本地缓冲区？（避免锁竞争、提高性能）
- 💡 `malloc_logger` 是什么？（系统提供的私有 API）
- 💡 多个数据库的职责划分

---

#### 🔍 学习点 2：启动流程 `enable_memory_logging()` ⭐⭐⭐

**函数位置：第 537-604 行**

```cpp
int enable_memory_logging(const char *root_dir, const char *log_dir) {
    // 1. 初始化数据库
    s_stack_frames_writer = new stack_frames_db();
    s_stack_frames_writer->open_db(stack_frames_db_path);
    
    s_allocation_event_writer = new allocation_event_db();
    s_allocation_event_writer->open_db(allocation_event_db_path);
    
    s_dyld_image_info_writer = new dyld_image_info_db();
    s_dyld_image_info_writer->open_db(dyld_db_path);
    
    s_object_type_writer = new object_type_db();
    s_object_type_writer->open_db(object_type_db_path);
    
    // 2. 初始化缓冲区池
    s_buffer_pool = new memory_logging_event_buffer_pool();
    s_buffer_list = new memory_logging_event_buffer_list();
    
    // 3. 启动工作线程（异步写入）
    if (__prepare_working_thread() == false) {
        return MS_ERRC_WORKING_THREAD_CREATE_FAIL;
    }
    
    // 4. 🔥 设置系统回调 - 核心！
    malloc_logger = __memory_event_callback;
    
    #ifdef USE_PRIVATE_API
    syscall_logger = (malloc_logger_t **)dlsym(RTLD_DEFAULT, "__syscall_logger");
    if (syscall_logger != NULL) {
        *syscall_logger = __memory_event_callback;
    }
    #endif
    
    // 5. 启用 OC 对象监控
    enable_object_event_logger();
    
    // 6. 启动
    s_logging_is_enable = true;
    
    return MS_ERRC_SUCCESS;
}
```

**重点理解：**

##### ① malloc_logger 是什么？

`malloc_logger` 是 iOS 系统提供的一个**函数指针**，当这个指针不为 NULL 时，每次 malloc/free 调用都会通过它通知上层。

```cpp
// 系统内部的伪代码（简化）
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    
    if (malloc_logger != NULL) {
        malloc_logger(MALLOC_LOG_TYPE_ALLOCATE, zone, size, 0, ptr, 0);
    }
    
    return ptr;
}
```

**这就是为什么调试模式下不能启动** - Xcode 的 Instruments 也使用这个指针！

##### ② 工作线程的作用

为了避免阻塞内存分配（malloc 必须快速返回），采用了**生产者-消费者模式**：

```
分配线程 (生产者)              工作线程 (消费者)
     ↓                              ↓
记录到本地缓冲区  ────────→  异步写入数据库
  (极快，无锁)                  (慢，有 I/O)
```

---

#### 🔍 学习点 3：内存分配回调 `__memory_event_callback()` ⭐⭐⭐⭐⭐

**函数位置：第 169-266 行**

**这是整个监控系统最核心的函数！**

```cpp
void __memory_event_callback(
    uint32_t type_flags,      // 分配类型（malloc/vm_allocate等）
    uintptr_t zone_ptr,       // 内存区域
    uintptr_t arg2,           // 参数2（取决于类型）
    uintptr_t arg3,           // 参数3
    uintptr_t return_val,     // 返回值（分配的地址）
    uint32_t num_hot_to_skip  // 跳过的热帧数
) {
    // 0. 快速检查：是否启用
    if (!s_logging_is_enable) {
        return;
    }
    
    // 1. 过滤：跳过 malloc_zone 的 VM 分配
    uint32_t alias = 0;
    VM_GET_FLAGS_ALIAS(type_flags, alias);
    if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
        return;
    }
    
    // 2. 防止死锁：获取线程信息
    thread_info_for_logging_t thread_info;
    thread_info.value = current_thread_info_for_logging();
    
    if (thread_info.detail.is_ignore) {
        return;  // 如果是工作线程或 dump 线程，忽略
    }
    
    // 3. 解析分配类型和参数
    bool is_alloc = false;
    uintptr_t size = 0;
    uintptr_t ptr_arg = 0;
    
    if (type_flags & memory_logging_type_alloc) {
        is_alloc = true;
        size = arg2;
        ptr_arg = return_val;
    } else if (type_flags & memory_logging_type_dealloc) {
        is_alloc = false;
        ptr_arg = arg2;
    } else if (type_flags & memory_logging_type_vm_allocate) {
        is_alloc = true;
        ptr_arg = arg2;
        size = arg3;
    } else if (type_flags & memory_logging_type_vm_deallocate) {
        is_alloc = false;
        ptr_arg = arg2;
    }
    
    // 4. 判断是否需要捕获堆栈
    bool should_capture_stack = false;
    
    if (is_alloc) {
        // 策略1: 大内存必须捕获
        if (size >= skip_min_malloc_size) {
            should_capture_stack = true;
        }
        // 策略2: 检查最近 N 层堆栈是否包含 App 代码
        else {
            vm_address_t frames[skip_max_stack_depth];
            int count = backtrace((void **)frames, skip_max_stack_depth);
            if (has_app_stack_in_frames(frames, count)) {
                should_capture_stack = true;
            }
        }
    }
    
    // 5. 捕获堆栈
    vm_address_t frames[128];
    uint32_t frames_count = 0;
    
    if (should_capture_stack && dump_call_stacks > 0) {
        frames_count = backtrace((void **)frames, 128);
    }
    
    // 6. 获取线程本地缓冲区
    memory_logging_event_buffer *event_buffer = 
        __curr_event_buffer_and_lock(thread_info.detail.thread_id);
    
    // 7. 写入事件
    if (is_alloc) {
        memory_logging_event_buffer_write_allocation(
            event_buffer, ptr_arg, size, frames, frames_count);
    } else {
        memory_logging_event_buffer_write_deallocation(
            event_buffer, ptr_arg);
    }
    
    // 8. 解锁
    memory_logging_event_buffer_unlock(event_buffer);
}
```

**深度理解：**

##### ① 为什么要过滤？

```cpp
// 过滤 1: malloc_zone 内部的 VM 分配
if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
    return;  // malloc 内部使用 vm_allocate，会重复统计
}

// 过滤 2: 小内存 + 无 App 代码
if (size < skip_min_malloc_size && !has_app_stack) {
    return;  // 大量系统库小分配，没必要记录
}
```

**不过滤会怎样？**
- 数据库爆炸（每秒数万次分配）
- 性能急剧下降（每次 malloc 慢 10-100 倍）
- 无法找到真正的内存泄漏点（被系统噪音淹没）

##### ② 线程本地缓冲区（TLS）的妙用

```cpp
// 每个线程有自己的缓冲区，避免锁竞争
memory_logging_event_buffer *event_buffer = 
    (memory_logging_event_buffer *)pthread_getspecific(s_event_buffer_key);

if (event_buffer == NULL) {
    // 第一次分配，创建缓冲区
    event_buffer = __new_event_buffer_and_lock(thread_id);
    pthread_setspecific(s_event_buffer_key, event_buffer);
}
```

**优势：**
- ✅ 无锁写入（每个线程独立）
- ✅ 缓存友好（局部性好）
- ✅ 批量提交（工作线程统一处理）

---

#### 🔍 学习点 4：工作线程 `__memory_event_writing_thread()` 

**函数位置：第 410-507 行**

```cpp
void *__memory_event_writing_thread(void *param) {
    s_working_thread_id = current_thread_id();
    
    while (s_logging_is_enable) {
        // 1. 等待一段时间（避免频繁唤醒）
        usleep(10000);  // 10ms
        
        // 2. 遍历所有线程的缓冲区
        memory_logging_event_buffer *buffer = 
            memory_logging_event_buffer_list_front(s_buffer_list);
        
        while (buffer != NULL) {
            memory_logging_event_buffer_lock(buffer);
            
            // 3. 检查是否有数据
            if (buffer->event_count > 0) {
                // 4. 处理分配事件
                for (int i = 0; i < buffer->event_count; i++) {
                    memory_logging_event *event = &buffer->events[i];
                    
                    if (event->is_alloc) {
                        // 写入 allocation_event_db
                        s_allocation_event_writer->add_allocation(
                            event->address,
                            event->size,
                            event->stack_id,
                            event->type_id
                        );
                    } else {
                        // 从数据库删除
                        s_allocation_event_writer->del_allocation(
                            event->address
                        );
                    }
                }
                
                // 5. 清空缓冲区
                buffer->event_count = 0;
            }
            
            memory_logging_event_buffer_unlock(buffer);
            buffer = memory_logging_event_buffer_list_next(s_buffer_list, buffer);
        }
    }
    
    return NULL;
}
```

**理解要点：**
- 🔄 生产者-消费者模式的消费者端
- 🔄 10ms 轮询间隔的权衡（太短浪费 CPU，太长丢失实时性）
- 🔄 批量处理的性能优势

---

#### 📁 核心文件 #2：`nsobject_hook.mm`

**文件位置：** `matrix-iOS/Matrix/WCMemoryStat/MemoryLogger/ObjectEvent/nsobject_hook.mm`

**代码行数：** ~150 行

```objc
@implementation NSObject (ObjectEventLogging)

+ (id)event_logging_alloc {
    // 调用原始的 alloc（通过 Method Swizzling）
    id object = [self event_logging_alloc];
    
    // 如果当前线程正在监控
    if (!is_thread_ignoring_logging()) {
        // 设置对象类型名称
        nsobject_set_last_allocation_event_name(object, class_getName(self.class));
    }
    
    return object;
}

@end
```

**关键函数：**

```cpp
void nsobject_set_last_allocation_event_name(void *ptr, const char *class_name) {
    if (ptr == NULL || class_name == NULL) {
        return;
    }
    
    // 查找这个对象对应的分配事件
    allocation_event *event = find_allocation_event_by_address((uintptr_t)ptr);
    
    if (event != NULL) {
        // 记录类型 ID
        uint32_t type_id = s_object_type_writer->get_or_add_type(class_name);
        event->type_id = type_id;
    }
}
```

**学习要点：**
- 🎭 Method Swizzling 的实现（hook +alloc）
- 🎭 如何关联对象指针和分配事件
- 🎭 为什么要单独 hook OC 对象？（普通 malloc 无法知道类型）

---

### 3.3 数据层 - 存储与分析

**时间：1-2 小时**  
**难度：⭐⭐⭐**

#### 📁 核心文件：数据库实现

**位置：** `matrix-iOS/Matrix/WCMemoryStat/MemoryLogger/ObjectEvent/`

---

#### 1️⃣ `allocation_event_db.cpp` - 分配事件数据库

**核心数据结构：**

```cpp
// 分配事件
struct allocation_event {
    uintptr_t address;      // 对象地址
    uint32_t size;          // 分配大小
    uint32_t stack_id;      // 堆栈 ID（去重后）
    uint32_t type_id;       // 类型 ID（OC 类名）
};

// 使用 splay tree 存储（平衡二叉树，查找O(log n)）
splay_map<uintptr_t, allocation_event> allocations;
```

**关键操作：**

```cpp
// 添加分配
void add_allocation(uintptr_t addr, uint32_t size, uint32_t stack_id, uint32_t type_id) {
    allocation_event event = {addr, size, stack_id, type_id};
    allocations.insert(addr, event);
}

// 删除分配（free 时调用）
void del_allocation(uintptr_t addr) {
    allocations.erase(addr);
}

// 查询所有存活对象
vector<allocation_event> get_all_allocations() {
    return allocations.values();
}
```

**学习要点：**
- 🗄️ 为什么使用 splay tree？（自适应，热点数据快速访问）
- 🗄️ 内存对象的完整生命周期跟踪
- 🗄️ 如何高效处理数百万个对象？

---

#### 2️⃣ `stack_frames_db.cpp` - 堆栈数据库

**核心作用：堆栈去重**

```cpp
// 堆栈帧
struct stack_frame {
    uintptr_t address;      // 帧地址
};

// 堆栈（多个帧）
struct stack_frames {
    uint32_t count;         // 帧数量
    stack_frame frames[64]; // 帧数组
};

// 堆栈 → ID 映射（相同堆栈共用一个 ID）
hash_map<stack_frames, uint32_t> stack_to_id;
```

**为什么要去重？**

假设 100 万次分配，如果每个都保存完整堆栈（每个堆栈 20 帧 × 8 字节）：
- **不去重**：100万 × 20 × 8 = 152 MB
- **去重后**：假设只有 1000 个不同堆栈 = 156 KB（节省 1000 倍！）

---

#### 3️⃣ `dyld_image_info_db.cpp` - 动态库信息

**作用：符号化时需要**

```cpp
struct dyld_image_info {
    uintptr_t load_address;  // 加载地址
    intptr_t slide;          // ASLR 偏移
    char name[256];          // 库名称
};
```

**为什么需要 slide？**

```
堆栈中的地址（运行时）: 0x100abcd00
slide: 0x100000000
符号表中的地址: 0x100abcd00 - 0x100000000 = 0xabcd00

atos -o MyApp.dSYM -l 0x100000000 -arch arm64 0xabcd00
→ -[ViewController viewDidLoad] + 123
```

---

#### 4️⃣ `memory_report_generator.cpp` - 报告生成

**核心函数：**

```cpp
bool memory_dump(void (*callback)(const char *, size_t), 
                 summary_report_param param) {
    
    // 1. 收集所有存活对象
    vector<allocation_event> allocations = 
        s_allocation_event_writer->get_all_allocations();
    
    // 2. 按类型分组统计
    map<uint32_t, type_stat> type_stats;
    
    for (auto &alloc : allocations) {
        type_stat &stat = type_stats[alloc.type_id];
        stat.count++;
        stat.size += alloc.size;
        stat.stacks[alloc.stack_id].count++;
        stat.stacks[alloc.stack_id].size += alloc.size;
    }
    
    // 3. 生成 JSON
    json_object root;
    root["head"] = generate_head(param);
    
    json_array items;
    for (auto &kv : type_stats) {
        json_object item;
        item["name"] = get_type_name(kv.first);
        item["count"] = kv.second.count;
        item["size"] = kv.second.size;
        item["stacks"] = generate_stacks(kv.second.stacks);
        items.push_back(item);
    }
    root["items"] = items;
    
    // 4. 回调返回
    string json_str = root.to_string();
    callback(json_str.c_str(), json_str.size());
    
    return true;
}
```

**学习要点：**
- 📊 如何从底层数据生成用户可读的报告
- 📊 统计聚合的实现（按类型、按堆栈）
- 📊 JSON 生成的优化（避免内存拷贝）

---

## 4. 核心技术原理

### 4.1 malloc_logger 的工作原理

#### 系统层面的实现（推测）

```c
// libsystem_malloc.dylib 中的实现（简化）

// 全局函数指针
malloc_logger_t *malloc_logger = NULL;

void *malloc(size_t size) {
    // 1. 实际分配
    void *ptr = zone_malloc(default_zone, size);
    
    // 2. 如果有监控器，通知它
    if (malloc_logger != NULL) {
        malloc_logger(
            memory_logging_type_alloc,  // 类型
            (uintptr_t)default_zone,     // zone
            size,                        // 大小
            0,                           // 保留
            (uintptr_t)ptr,              // 返回的地址
            0                            // 跳过帧数
        );
    }
    
    return ptr;
}

void free(void *ptr) {
    // 1. 通知监控器
    if (malloc_logger != NULL) {
        malloc_logger(
            memory_logging_type_dealloc,
            (uintptr_t)default_zone,
            (uintptr_t)ptr,              // 要释放的地址
            0,
            0,
            0
        );
    }
    
    // 2. 实际释放
    zone_free(default_zone, ptr);
}
```

**关键点：**
- ✅ 系统在每次分配/释放时都会检查 `malloc_logger`
- ✅ 这是一个**同步调用**，会阻塞 malloc/free
- ✅ 所以回调函数必须**极快**（Matrix 用 TLS 无锁缓冲区）

---

### 4.2 堆栈捕获的实现

#### backtrace() 的原理

```cpp
// 简化实现
int backtrace(void **buffer, int size) {
    int frame_count = 0;
    
    // 1. 获取当前帧指针（FP, Frame Pointer）
    void **fp = (void **)__builtin_frame_address(0);
    
    // 2. 沿着帧链往上走
    while (frame_count < size && fp != NULL) {
        // 返回地址在 FP+1 位置
        void *return_address = *(fp + 1);
        buffer[frame_count++] = return_address;
        
        // 移动到上一帧
        fp = (void **)*fp;
    }
    
    return frame_count;
}
```

**ARM64 栈帧结构：**

```
高地址
    ↑
    │ 局部变量
    ├─────────────
    │ 返回地址 (LR)  ← FP+8
    ├─────────────
    │ 上一帧 FP     ← FP (当前帧指针)
    ├─────────────
    │ 参数/寄存器保存
    ↓
低地址
```

---

### 4.3 符号化原理

#### 从地址到符号的转换

```bash
# 1. 获取运行时地址
address_runtime = 0x100abcd00

# 2. 获取 ASLR slide
slide = 0x100000000

# 3. 计算符号表地址
address_symbol = address_runtime - slide = 0xabcd00

# 4. 使用 atos 或 dwarfdump 查询
atos -o MyApp.dSYM -l 0x100000000 -arch arm64 0xabcd00

# 输出：
-[ViewController viewDidLoad] (in MyApp) (ViewController.m:42)
```

**dSYM 文件结构：**

```
MyApp.dSYM/
└── Contents/
    └── Resources/
        └── DWARF/
            └── MyApp  ← 包含调试符号的二进制文件
```

**DWARF 调试信息：**
- 函数名 → 地址范围映射
- 地址 → 源文件行号映射
- 变量类型信息

---

### 4.4 FOOM 检测原理

#### 排除法实现

```objc
// MatrixAppRebootAnalyzer.m（推测实现）

typedef NS_ENUM(NSUInteger, MatrixAppRebootType) {
    MatrixAppRebootTypeUnknown = 0,
    MatrixAppRebootTypeNormal,              // 正常退出
    MatrixAppRebootTypeCrash,               // 崩溃
    MatrixAppRebootTypeAppForegroundOOM,    // 前台 OOM ⭐
    MatrixAppRebootTypeBackgroundOOM,       // 后台 OOM
    MatrixAppRebootTypeSystemReboot,        // 系统重启
};

+ (MatrixAppRebootType)lastRebootType {
    // 1. App 启动时立即调用，记录当前状态
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self recordAppLaunched];
    });
    
    // 2. 读取上次运行的状态文件
    NSDictionary *lastState = [self readLastRunState];
    
    if (lastState == nil) {
        return MatrixAppRebootTypeUnknown;
    }
    
    // 3. 检查上次是否正常退出
    if ([lastState[@"clean_exit"] boolValue]) {
        return MatrixAppRebootTypeNormal;
    }
    
    // 4. 检查是否有崩溃日志
    if ([self hasCrashLogForLastRun]) {
        return MatrixAppRebootTypeCrash;
    }
    
    // 5. 检查是否是系统重启
    if ([self isSystemRebooted]) {
        return MatrixAppRebootTypeSystemReboot;
    }
    
    // 6. 检查上次是否在前台
    if ([lastState[@"in_foreground"] boolValue]) {
        // 前台、非崩溃、非正常退出 → FOOM！
        return MatrixAppRebootTypeAppForegroundOOM;
    } else {
        return MatrixAppRebootTypeBackgroundOOM;
    }
}

+ (void)recordAppLaunched {
    // 记录启动状态
    [@{
        @"launch_time": @([[NSDate date] timeIntervalSince1970]),
        @"clean_exit": @NO,  // 默认非正常退出
        @"in_foreground": @([UIApplication sharedApplication].applicationState == UIApplicationStateActive)
    } writeToFile:STATE_FILE_PATH atomically:YES];
}

+ (void)recordAppWillTerminate {
    // App 正常退出前调用
    NSMutableDictionary *state = [self readLastRunState].mutableCopy;
    state[@"clean_exit"] = @YES;
    [state writeToFile:STATE_FILE_PATH atomically:YES];
}
```

**关键逻辑：**

```
启动时检查上次状态：
  ├─ 有 clean_exit 标记？
  │    └─ YES → 正常退出
  │    └─ NO → 异常退出，继续判断
  │
  ├─ 有崩溃日志？
  │    └─ YES → 崩溃
  │    └─ NO → 非崩溃，继续判断
  │
  ├─ 系统重启？
  │    └─ YES → 系统重启
  │    └─ NO → 非系统原因，继续判断
  │
  └─ 上次在前台？
       └─ YES → FOOM！⚠️
       └─ NO → 后台被杀（正常现象）
```

---

## 5. 实战调试技巧

### 5.1 添加日志观察数据流

在关键位置添加 NSLog：

```objc
// WCMemoryStatPlugin.mm
- (BOOL)start {
    NSLog(@"🚀 [MemStat] 启动内存监控");
    NSLog(@"   - skipMinMallocSize: %d", self.pluginConfig.skipMinMallocSize);
    NSLog(@"   - skipMaxStackDepth: %d", self.pluginConfig.skipMaxStackDepth);
    NSLog(@"   - dumpCallStacks: %d", self.pluginConfig.dumpCallStacks);
    
    int ret = enable_memory_logging(rootPath.UTF8String, dataPath.UTF8String);
    
    if (ret == MS_ERRC_SUCCESS) {
        NSLog(@"✅ [MemStat] 监控启动成功");
    } else {
        NSLog(@"❌ [MemStat] 监控启动失败: %d", ret);
    }
    
    return ret == MS_ERRC_SUCCESS;
}
```

```cpp
// memory_logging.cpp
void __memory_event_callback(...) {
    static int alloc_count = 0;
    static int dealloc_count = 0;
    
    if (is_alloc) {
        alloc_count++;
        if (alloc_count % 1000 == 0) {
            printf("📊 [MemLog] 已记录 %d 次分配\n", alloc_count);
        }
    } else {
        dealloc_count++;
    }
}
```

### 5.2 使用 lldb 调试

```bash
# 1. 设置断点
(lldb) b enable_memory_logging
(lldb) b __memory_event_callback

# 2. 运行到断点
(lldb) c

# 3. 查看变量
(lldb) p s_logging_is_enable
(lldb) p malloc_logger
(lldb) p *s_allocation_event_writer

# 4. 查看堆栈
(lldb) bt

# 5. 单步执行
(lldb) n  # next
(lldb) s  # step into
```

### 5.3 查看数据库文件

```bash
# 1. 找到数据目录
cd ~/Library/Developer/CoreSimulator/Devices/<UUID>/data/Containers/Data/Application/<UUID>/Library/Caches/Matrix/MemoryStat/Data/<timestamp>/

# 2. 查看文件大小
ls -lh
# allocation_events.dat
# stack_frames.dat
# dyld_images.dat
# object_types.dat

# 3. 使用 hexdump 查看二进制内容
hexdump -C allocation_events.dat | head -n 20
```

### 5.4 手动触发内存 dump

```objc
// 在任意位置添加
WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];

[plugin memoryDumpAndGenerateReportData:@"manual_test" 
                             customInfo:@{@"scene": @"test"}
                               callback:^(NSData *reportData) {
    NSLog(@"📊 生成报告成功，大小: %lu 字节", reportData.length);
    
    // 保存到文件
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"memory_test.json"];
    [reportData writeToFile:path atomically:YES];
    NSLog(@"💾 已保存到: %@", path);
}];
```

### 5.5 性能分析

使用 Instruments 的 Time Profiler：

```bash
# 1. 在 Xcode 中
Product → Profile → Time Profiler

# 2. 运行 App 并触发内存分配

# 3. 查看耗时函数
- __memory_event_callback
- backtrace
- memory_logging_event_buffer_write_allocation
```

**优化方向：**
- 减少 `skipMinMallocSize`（更多过滤）
- 增加 `skipMaxStackDepth`（减少堆栈检查）
- 设置 `dumpCallStacks = 2`（只记录 OC 对象）

---

## 6. 进阶阅读

### 6.1 相关源码

#### Apple 开源项目
- [libmalloc](https://opensource.apple.com/source/libmalloc/) - malloc 实现
- [dyld](https://opensource.apple.com/source/dyld/) - 动态链接器
- [objc4](https://opensource.apple.com/source/objc4/) - Objective-C Runtime

#### 类似项目
- [FBAllocationTracker](https://github.com/facebook/FBAllocationTracker) - Facebook 的内存跟踪工具
- [FBRetainCycleDetector](https://github.com/facebook/FBRetainCycleDetector) - 循环引用检测
- [MLeaksFinder](https://github.com/Tencent/MLeaksFinder) - 腾讯的内存泄漏检测

### 6.2 技术文章

#### 必读
1. [iOS微信内存监控](https://wetest.qq.com/labs/367) ⭐⭐⭐⭐⭐
2. [Reducing FOOMs in the Facebook iOS app](https://code.facebook.com/posts/1146930688654547/)
3. [深入理解iOS内存管理](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/)

#### 推荐
4. [iOS App 性能检测](https://tech.meituan.com/2017/04/21/mtdiag-system-performance.html) - 美团技术团队
5. [Malloc 实现原理](http://www.newosxbook.com/articles/MemoryPressure.html)
6. [DWARF 调试信息格式](http://www.dwarfstd.org/)

### 6.3 调试技巧进阶

#### LLDB Python 脚本

创建 `~/.lldbinit`：

```python
# 打印 allocation_event_db 的内容
command script import ~/matrix_lldb.py
command alias memstat memstat_dump
```

创建 `~/matrix_lldb.py`：

```python
import lldb

def memstat_dump(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    
    # 读取全局变量
    s_allocation_event_writer = target.FindFirstGlobalVariable("s_allocation_event_writer")
    
    if s_allocation_event_writer:
        print("✅ 找到 allocation_event_db")
        # ... 读取和打印数据
    else:
        print("❌ 未找到数据库实例")

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add -f matrix_lldb.memstat_dump memstat_dump')
```

#### 条件断点

```bash
# 只在特定大小的分配时断点
(lldb) b __memory_event_callback
(lldb) breakpoint modify -c 'size > 1000000' 1

# 只在特定线程断点
(lldb) breakpoint modify -T "main thread" 1
```

---

## 7. 学习建议

### 7.1 循序渐进

**不要一次看完所有代码！** 建议分阶段学习：

#### 第一周：理解架构
- [ ] 阅读 `iOS内存监控技术实现.md`
- [ ] 浏览所有头文件（.h）
- [ ] 画出自己的架构图

#### 第二周：ObjC 层
- [ ] 调试 `WCMemoryStatPlugin` 的启动流程
- [ ] 理解配置参数的作用
- [ ] 尝试修改配置并观察效果

#### 第三周：C++ 核心层
- [ ] 重点阅读 `memory_logging.cpp`
- [ ] 理解 `malloc_logger` 机制
- [ ] 调试 `__memory_event_callback()`

#### 第四周：数据层
- [ ] 阅读数据库实现
- [ ] 理解堆栈去重算法
- [ ] 查看实际生成的数据库文件

#### 第五周：实战
- [ ] 真机测试 OOM 检测
- [ ] 分析一个真实的内存泄漏
- [ ] 优化配置以适应自己的 App

### 7.2 边学边实践

每学完一个模块，写一个小测试：

```objc
// 测试 1: 验证过滤规则
- (void)testSkipMinMallocSize {
    // 分配小内存，验证是否被过滤
    for (int i = 0; i < 1000; i++) {
        void *ptr = malloc(100);  // 小于 PAGE_SIZE
        free(ptr);
    }
    
    // 检查数据库中的记录数量
    size_t count = [[self getMemoryPlugin] pluginMemoryUsed];
    NSLog(@"数据库大小: %zu", count);
}

// 测试 2: 验证堆栈捕获
- (void)testStackCapture {
    // 分配大内存，应该捕获堆栈
    void *ptr = malloc(1024 * 1024);  // 1MB
    
    // 手动 dump 并查看堆栈
    [self triggerMemoryDump];
    
    free(ptr);
}
```

### 7.3 记录笔记

建议使用 Markdown 记录：

```markdown
## 2024-01-07 学习笔记

### 今日学习：malloc_logger 机制

#### 发现：
- malloc_logger 是系统级的 hook 点
- 调试模式下无法使用（Instruments 占用）
- 回调必须极快（否则严重影响性能）

#### 疑问：
- [ ] __syscall_logger 和 malloc_logger 有什么区别？
- [ ] 为什么用 splay tree 而不是 hash map？

#### 下次计划：
- 研究 vm_allocate 的监控
- 理解 pthread_introspection 的作用
```

---

## 8. 常见问题

### Q1: 为什么调试模式下无法启动？

**A:** Xcode 的 Instruments 也使用 `malloc_logger`，同时只能有一个监控器。

**解决方案：**
- 使用 Archive 打包测试
- 或者 Detach debugger 后运行

### Q2: 内存监控会影响性能吗？

**A:** 会有一定影响：

| 场景 | CPU | 内存 | 磁盘 I/O |
|------|-----|------|----------|
| 不监控 | 0% | 0 MB | 0 |
| 开发配置 | +10-15% | +30-50 MB | 中 |
| 生产配置 | +5-8% | +10-20 MB | 低 |

**优化建议：**
- 提高 `skipMinMallocSize` (16KB → 32KB)
- 降低 `skipMaxStackDepth` (15 → 8)
- 设置 `dumpCallStacks = 2`（仅 OC）

### Q3: 如何判断内存泄漏？

**A:** 对比多次 dump 的结果：

```objc
// 时间点 1
[self dumpMemory:@"point1"];

// 执行操作（如打开再关闭页面）
[self openAndCloseViewController];

// 时间点 2
[self dumpMemory:@"point2"];

// 对比两次 dump，理论上对象数量应该相同
// 如果 point2 比 point1 多，说明有泄漏
```

### Q4: OOM 报告的堆栈为什么是地址？

**A:** 需要符号化：

1. 确保上传了对应的 dSYM 文件
2. 在服务端点击"符号化"按钮
3. 查看符号化后的报告

---

## 9. 总结

### 核心要点回顾

#### 💡 关键技术

1. **malloc_logger / __syscall_logger**
   - 系统级内存分配监控的 hook 点
   - 同步回调，必须极快

2. **线程本地缓冲区（TLS）**
   - 避免锁竞争
   - 生产者-消费者模式

3. **堆栈去重**
   - 节省存储空间（1000 倍压缩）
   - 加速查询和分析

4. **FOOM 检测**
   - 排除法判断
   - 需要持久化状态文件

5. **符号化**
   - 地址 → 符号转换
   - 需要 dSYM + slide

#### 🎯 学习路径

```
ObjC 插件层（简单）
    ↓
C++ 监控引擎（核心，重点）
    ↓
数据存储层（优化）
    ↓
报告生成和分析（应用）
```

#### 📚 推荐资源

1. **必读**：iOS内存监控技术实现.md
2. **必读**：[微信技术文章](https://wetest.qq.com/labs/367)
3. **可选**：Apple 开源代码（libmalloc, objc4）

---

**祝学习顺利！如有问题，欢迎交流。**

*最后更新：2026-01-07*

