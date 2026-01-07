# iOS 内存监控技术实现文档

> 基于腾讯 Matrix 框架的内存监控完整实现方案

## 📚 目录

- [1. 背景](#1-背景)
- [2. 技术原理](#2-技术原理)
- [3. 实现架构](#3-实现架构)
- [4. 核心功能详解](#4-核心功能详解)
- [5. 配置说明](#5-配置说明)
- [6. 使用指南](#6-使用指南)
- [7. 注意事项](#7-注意事项)
- [8. 参考资料](#8-参考资料)

---

## 1. 背景

### 1.1 FOOM 问题

**FOOM (Foreground Out Of Memory)** 是指 App 在前台因消耗内存过多引起的系统强杀。对用户而言，表现与 crash 一样，但传统的崩溃监控工具无法捕获。

Facebook 在 2015 年提出了 FOOM 检测方法：排除各种已知情况后，剩余的异常退出情况即为 FOOM。

**微信的数据**：
- 早期 FOOM 率接近 3%（登录用户数比例）
- 同期 crash 率不到 1%
- FOOM 问题比 crash 更严重，但更难定位

### 1.2 为什么需要内存监控？

传统工具的局限性：
- **Instruments Allocations**：只能用于开发阶段，无法在线上发现问题
- **传统日志**：粒度粗、性能差、难以分析

需要一个**离线化的内存监控工具**，用于 App 上线后发现和定位内存问题。

---

## 2. 技术原理

### 2.1 核心监控机制

iOS 系统提供了两个关键的函数指针，用于监控内存分配：

#### 2.1.1 malloc_logger

```c
typedef void(malloc_logger_t)(uint32_t type, 
                              uintptr_t arg1, 
                              uintptr_t arg2, 
                              uintptr_t arg3, 
                              uintptr_t result, 
                              uint32_t num_hot_frames_to_skip);

extern malloc_logger_t *malloc_logger;
```

**作用**：监控堆内存分配
- `malloc/free`
- `calloc/realloc`
- `posix_memalign`

当这个函数指针不为空时，每次堆内存分配/释放都会通过它通知上层。

#### 2.1.2 __syscall_logger

```c
static malloc_logger_t **syscall_logger;
```

**作用**：监控虚拟内存分配
- `vm_allocate/vm_deallocate`
- `mmap/munmap`

通过 `dlsym` 获取：
```c
syscall_logger = (malloc_logger_t **)dlsym(RTLD_DEFAULT, "__syscall_logger");
if (syscall_logger != NULL) {
    *syscall_logger = __memory_event_callback;
}
```

#### 2.1.3 OC 对象监控

通过 Method Swizzling hook `+[NSObject alloc]`：

```objc
+ (id)event_logging_alloc {
    id object = [self event_logging_alloc];
    
    if (is_thread_ignoring_logging()) {
        return object;
    }
    nsobject_set_last_allocation_event_name(object, class_getName(self.class));
    return object;
}
```

**注意**：部分类（如 NSData）使用 `NSAllocateObject` 创建对象，需要 hook CoreFoundation 的 `__CFObjectAllocSetLastAllocEventNameFunction` 来捕获。

### 2.2 堆栈捕获

使用 `backtrace()` 函数捕获调用堆栈：

```c
void *frames[128];
int frame_count = backtrace(frames, 128);
```

**重要**：捕获到的是虚拟内存地址，需要减去 dyld slide 才能从符号表解析：

```
符号表地址 = 堆栈地址 - slide
```

每个 image（动态库）加载时都有一个 slide 偏移，需要记录：

```c
// 记录 dyld 加载信息
typedef struct {
    uintptr_t load_address;  // 加载地址
    intptr_t slide;          // 偏移量
    char image_name[256];    // 镜像名称
} dyld_image_info;
```

### 2.3 内存对象分类

为了更好地归类和分析，每个内存对象都有其 Category：

| 内存类型 | Category 命名规则 | 示例 |
|---------|------------------|------|
| 堆内存 | `Malloc` + 分配大小 | `Malloc 48.00KiB` |
| 虚拟内存 | 根据 `vm_statistics.h` 中的 flags | `VM_MEMORY_IOKIT`, `VM_MEMORY_GRAPHICS` |
| OC 对象 | OC 类名 | `NSString`, `UIView` |

---

## 3. 实现架构

### 3.1 整体架构图

```
┌─────────────────────────────────────────────────────────┐
│                    应用层 (App)                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │          MatrixHandler (协调层)                   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│                Matrix Plugin 层                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │      WCMemoryStatPlugin (内存统计插件)            │   │
│  │  • 插件生命周期管理                               │   │
│  │  • FOOM 检测                                      │   │
│  │  • 报告生成和上报                                 │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │      WCMemoryStatConfig (配置管理)                │   │
│  │  • skipMinMallocSize                              │   │
│  │  • skipMaxStackDepth                              │   │
│  │  • dumpCallStacks                                 │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │      WCMemoryRecordManager (记录管理)             │   │
│  │  • 记录持久化                                     │   │
│  │  • 历史记录查询                                   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│              Memory Logger 层 (C++)                      │
│  ┌──────────────────────────────────────────────────┐   │
│  │      memory_logging.cpp (核心日志)                │   │
│  │  • 设置 malloc_logger                             │   │
│  │  • 设置 __syscall_logger                          │   │
│  │  • 事件回调处理                                   │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │      object_event_handler (对象事件处理)          │   │
│  │  • OC 对象分配记录                                │   │
│  │  • 对象类型映射                                   │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │      nsobject_hook (OC 对象 Hook)                 │   │
│  │  • Hook +[NSObject alloc]                         │   │
│  │  • 记录对象类名                                   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│              数据存储层                                  │
│  ┌──────────────────────────────────────────────────┐   │
│  │   allocation_event_db (分配事件数据库)            │   │
│  │   • 存活对象信息                                  │   │
│  │   • 地址到堆栈映射                                │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │   stack_frames_db (堆栈帧数据库)                  │   │
│  │   • 堆栈信息去重                                  │   │
│  │   • 堆栈 ID 映射                                  │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │   dyld_image_info_db (镜像信息数据库)             │   │
│  │   • dyld 加载信息                                 │   │
│  │   • slide 偏移记录                                │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 3.2 数据流程

```
内存分配事件
    ↓
malloc_logger / __syscall_logger 回调
    ↓
__memory_event_callback()
    ↓
线程本地缓冲区 (TLS)
    ↓
写入线程 (高优先级)
    ↓
数据库 (allocation_event_db, stack_frames_db)
    ↓
FOOM 发生
    ↓
下次启动检测
    ↓
生成报告
    ↓
上报到服务器
    ↓
符号化和分析
```

---

## 4. 核心功能详解

### 4.1 插件初始化

在 `MatrixHandler.mm` 中初始化内存监控插件：

```objc
- (void)installMatrix
{
    // ... 其他插件初始化 ...
    
    // 创建内存统计插件
    WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];
    memoryStatPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
    [curBuilder addPlugin:memoryStatPlugin];
    
    [matrix addMatrixBuilder:curBuilder];
    
    // 启动插件
    [memoryStatPlugin start];
    
    m_msPlugin = memoryStatPlugin;
}
```

### 4.2 启动监控

`WCMemoryStatPlugin.mm` 中的 `start` 方法：

```objc
- (BOOL)start {
    // 1. 调试模式下不启动（会干扰调试）
    if ([MatrixDeviceInfo isBeingDebugged]) {
        MatrixDebug(@"app is being debugged, cannot start memstat");
        return NO;
    }

    // 2. 已经在运行
    if (m_currRecord != nil) {
        return NO;
    }

    // 3. 应用配置
    if (self.pluginConfig) {
        skip_max_stack_depth = self.pluginConfig.skipMaxStackDepth;
        skip_min_malloc_size = self.pluginConfig.skipMinMallocSize;
        dump_call_stacks = self.pluginConfig.dumpCallStacks;
    }

    // 4. 创建当前记录
    m_currRecord = [[MemoryRecordInfo alloc] init];
    m_currRecord.launchTime = [MatrixAppRebootAnalyzer appLaunchTime];
    m_currRecord.systemVersion = [MatrixDeviceInfo systemVersion];
    m_currRecord.appUUID = @(app_uuid());

    // 5. 准备数据目录
    NSString *dataPath = [m_currRecord recordDataPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:nil];

    // 6. 启动内存日志
    int ret = enable_memory_logging(rootPath.UTF8String, dataPath.UTF8String);
    if (ret == MS_ERRC_SUCCESS) {
        [m_recordManager insertNewRecord:m_currRecord];
        return YES;
    } else {
        // 启动失败，清理资源
        disable_memory_logging();
        m_currRecord = nil;
        return NO;
    }
}
```

### 4.3 内存分配监控

`memory_logging.cpp` 中的核心回调：

```cpp
void __memory_event_callback(uint32_t type_flags, 
                             uintptr_t zone_ptr, 
                             uintptr_t arg2, 
                             uintptr_t arg3, 
                             uintptr_t return_val, 
                             uint32_t num_hot_to_skip) 
{
    // 1. 检查是否启用
    if (!s_logging_is_enable) {
        return;
    }

    // 2. 过滤不需要的分配
    uint32_t alias = 0;
    VM_GET_FLAGS_ALIAS(type_flags, alias);
    if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
        return;  // 跳过 malloc_zone 的 VM 分配
    }

    // 3. 获取线程信息
    thread_info_for_logging_t thread_info;
    thread_info.value = current_thread_info_for_logging();
    
    if (thread_info.detail.is_ignore) {
        return;  // 防止死锁
    }

    // 4. 解析分配类型
    bool is_alloc = false;
    uintptr_t size = 0;
    uintptr_t ptr_arg = 0;
    
    // ... 解析 type_flags，确定是分配还是释放 ...

    // 5. 捕获堆栈
    vm_address_t frames[128];
    uint32_t frames_count = 0;
    if (should_capture_stack) {
        frames_count = backtrace((void **)frames, 128);
    }

    // 6. 获取线程本地缓冲区
    memory_logging_event_buffer *event_buffer = 
        __curr_event_buffer_and_lock(thread_info.detail.thread_id);

    // 7. 记录事件
    if (is_alloc) {
        memory_logging_event_buffer_write_allocation(
            event_buffer, ptr_arg, size, frames, frames_count);
    } else {
        memory_logging_event_buffer_write_deallocation(
            event_buffer, ptr_arg);
    }

    // 8. 解锁缓冲区
    memory_logging_event_buffer_unlock(event_buffer);
}
```

### 4.4 FOOM 检测

启动时自动检测上次是否 FOOM：

```objc
- (void)deplayTryReportOOMInfo {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        // 检查是否需要自动上报
        if (self.pluginConfig.reportStrategy == EWCMemStatReportStrategy_Manual) {
            return;
        }
        
        // 获取自定义信息
        NSDictionary *customInfo = nil;
        if (self.delegate != nil) {
            customInfo = [self.delegate onMemoryStatPluginGetCustomInfo:self];
        }
        
        dispatch_async(self.pluginReportQueue, ^{
            // 判断上次退出是否是 FOOM
            if ([MatrixAppRebootAnalyzer lastRebootType] == 
                MatrixAppRebootTypeAppForegroundOOM) {
                
                // 获取上次运行的记录
                MemoryRecordInfo *lastInfo = [self recordOfLastRun];
                if (lastInfo != nil) {
                    // 生成报告
                    NSData *reportData = 
                        [lastInfo generateReportDataWithCustomInfo:customInfo];
                    
                    if (reportData != nil) {
                        // 创建 Issue
                        MatrixIssue *issue = [[MatrixIssue alloc] init];
                        issue.issueTag = [WCMemoryStatPlugin getTag];
                        issue.issueID = [lastInfo recordID];
                        issue.dataType = EMatrixIssueDataType_Data;
                        issue.issueData = reportData;
                        
                        // 上报
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self reportIssue:issue];
                        });
                    }
                }
            }
        });
    });
}
```

### 4.5 报告生成

内存记录包含的信息：

```objc
@interface MemoryRecordInfo : NSObject

@property (nonatomic, assign) uint64_t launchTime;     // 启动时间
@property (nonatomic, strong) NSString *recordID;      // 记录 ID
@property (nonatomic, strong) NSString *appUUID;       // 应用 UUID
@property (nonatomic, strong) NSString *systemVersion; // 系统版本
@property (nonatomic, assign) NSInteger userScene;     // 用户场景

// 生成报告数据
- (NSData *)generateReportDataWithCustomInfo:(NSDictionary *)customInfo;

@end
```

报告内容（JSON 格式）：

```json
{
    "phone": "iPhone 12",
    "os_ver": "14.5",
    "launch_time": 1704268800000,
    "report_time": 1704355200000,
    "app_uuid": "12345678",
    "foom_scene": "foreground",
    "memory_stats": {
        "total_allocated": 512000000,
        "top_allocations": [
            {
                "address": "0x123456789",
                "size": 10485760,
                "category": "Malloc 10.00MiB",
                "stack": [
                    "0x1000abcd",
                    "0x1000def0",
                    "0x1000ghij"
                ]
            }
        ]
    },
    "custom_info": {
        "user_id": "xxx",
        "scene": "chat"
    }
}
```

### 4.6 上报流程

在 `MatrixHandler.mm` 中处理上报：

```objc
- (void)onReportIssue:(MatrixIssue *)issue
{
    NSLog(@"获取问题: %@", issue);
    
    NSString *currentTitle = @"未知";
    
    // 判断问题类型
    if ([issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        if (issue.reportType == EMCrashBlockReportType_Lag) {
            currentTitle = @"卡顿";
        } else if (issue.reportType == EMCrashBlockReportType_Crash) {
            currentTitle = @"崩溃";
        }
    }
    
    if ([issue.issueTag isEqualToString:[WCMemoryStatPlugin getTag]]) {
        currentTitle = @"内存溢出信息";
    }
    
    // 🚀 自动上报到服务器
    [self uploadReportToServer:issue];
    
    // 显示到界面
    TextViewController *textVC = nil;
    if (issue.dataType == EMatrixIssueDataType_Data) {
        NSString *dataString = [[NSString alloc] initWithData:issue.issueData 
                                                     encoding:NSUTF8StringEncoding];
        textVC = [[TextViewController alloc] initWithString:dataString 
                                                  withTitle:currentTitle];
    } else {
        textVC = [[TextViewController alloc] initWithFilePath:issue.filePath 
                                                    withTitle:currentTitle];
    }
    
    [appDelegate.navigationController pushViewController:textVC animated:YES];
    
    [[Matrix sharedInstance] reportIssueComplete:issue success:YES];
}
```

**注意**：当前实现中，内存报告在 `uploadReportToServer:` 方法中被过滤掉了，需要修改以支持内存报告上传。

---

## 5. 配置说明

### 5.1 WCMemoryStatConfig

```objc
@interface WCMemoryStatConfig : MatrixPluginConfig

// 获取默认配置
+ (WCMemoryStatConfig *)defaultConfiguration;

/**
 * 堆栈过滤策略
 */

// 如果分配大小超过这个值，保存堆栈。默认为 PAGE_SIZE (16KB)
@property (nonatomic, assign) int skipMinMallocSize;

// 否则，如果堆栈在最后 N 层包含 App 的符号，也保存堆栈。默认为 8
@property (nonatomic, assign) int skipMaxStackDepth;

/**
 * 堆栈 dump 策略
 * 0 = 不 dump
 * 1 = dump 所有对象的调用堆栈
 * 2 = 只 dump OC 对象的调用堆栈
 */
@property (nonatomic, assign) int dumpCallStacks;

/**
 * 上报策略
 * EWCMemStatReportStrategy_Auto = 0    自动上报 FOOM
 * EWCMemStatReportStrategy_Manual = 1  手动上报
 */
@property (nonatomic, assign) EWCMemStatReportStrategy reportStrategy;

@end
```

### 5.2 配置示例

**默认配置**：

```objc
WCMemoryStatConfig *config = [WCMemoryStatConfig defaultConfiguration];
// skipMinMallocSize = 16384 (16KB)
// skipMaxStackDepth = 8
// dumpCallStacks = 1 (dump all)
// reportStrategy = EWCMemStatReportStrategy_Auto
```

**自定义配置**：

```objc
WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];

WCMemoryStatConfig *config = [WCMemoryStatConfig defaultConfiguration];
config.skipMinMallocSize = 32768;  // 32KB
config.skipMaxStackDepth = 10;     // 10 层
config.dumpCallStacks = 2;         // 只 dump OC 对象
config.reportStrategy = EWCMemStatReportStrategy_Manual;  // 手动上报

memoryStatPlugin.pluginConfig = config;
```

### 5.3 配置建议

| 场景 | skipMinMallocSize | skipMaxStackDepth | dumpCallStacks | 说明 |
|------|------------------|------------------|----------------|------|
| **开发测试** | 4096 (4KB) | 15 | 1 (全部) | 捕获更多信息 |
| **灰度测试** | 16384 (16KB) | 10 | 1 (全部) | 平衡性能和信息 |
| **线上环境** | 32768 (32KB) | 8 | 2 (仅 OC) | 减少性能影响 |

---

## 6. 使用指南

### 6.1 基本使用

#### 1. 启动内存监控

```objc
// 在 AppDelegate.m 中
- (BOOL)application:(UIApplication *)application 
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions 
{
    // 初始化 Matrix
    [[MatrixHandler sharedInstance] installMatrix];
    
    return YES;
}
```

#### 2. 停止内存监控

```objc
- (void)stopMemStat
{
    [[[MatrixHandler sharedInstance] getMemoryStatPlugin] stop];
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"MemStatPlugin stop" 
        message:@"" 
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" 
                                              style:UIAlertActionStyleDefault 
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
```

#### 3. 手动生成报告

```objc
WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];

[plugin memoryDumpAndGenerateReportData:@"manual_dump" 
                             customInfo:@{@"scene": @"profile_page"}
                               callback:^(NSData *reportData) {
    // 获取到报告数据
    NSLog(@"报告大小: %lu bytes", (unsigned long)reportData.length);
    
    // 可以保存或上传
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"memory_report.json"];
    [reportData writeToFile:path atomically:YES];
}];
```

### 6.2 测试 OOM

项目中提供了 `TestOOMViewController` 用于测试：

```objc
- (void)testOOM
{
    NSLog(@"制造内存溢出");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *array = [NSMutableArray array];
        while (1) {
            TestContact *contact = [[TestContact alloc] init];
            [array addObject:contact];
        }
    });
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"Warning" 
        message:@"will out of memory" 
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
}
```

### 6.3 查看历史记录

```objc
WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];

// 获取所有记录
NSArray<MemoryRecordInfo *> *records = [plugin recordList];
for (MemoryRecordInfo *record in records) {
    NSLog(@"记录 ID: %@", record.recordID);
    NSLog(@"启动时间: %llu", record.launchTime);
    NSLog(@"系统版本: %@", record.systemVersion);
}

// 获取上次运行的记录
MemoryRecordInfo *lastRecord = [plugin recordOfLastRun];
if (lastRecord) {
    NSData *reportData = [lastRecord generateReportDataWithCustomInfo:nil];
    // 处理报告数据...
}

// 删除记录
[plugin deleteRecord:lastRecord];

// 删除所有记录
[plugin deleteAllRecords];
```

### 6.4 自定义信息

实现 `WCMemoryStatPluginDelegate` 协议：

```objc
@interface MatrixHandler () <WCMemoryStatPluginDelegate>
@end

@implementation MatrixHandler

- (void)installMatrix
{
    WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];
    memoryStatPlugin.delegate = self;  // 设置代理
    // ...
}

// 提供自定义信息
- (NSDictionary *)onMemoryStatPluginGetCustomInfo:(WCMemoryStatPlugin *)plugin
{
    return @{
        @"user_id": @"12345",
        @"scene": @"chat",
        @"network": @"wifi",
        @"battery": @(80)
    };
}

// 错误处理
- (void)onMemoryStatPlugin:(WCMemoryStatPlugin *)plugin hasError:(int)errCode
{
    NSLog(@"内存监控错误: %d", errCode);
    
    // 根据错误码处理
    switch (errCode) {
        case MS_ERRC_WORKING_THREAD_CREATE_FAIL:
            NSLog(@"创建工作线程失败");
            break;
        case MS_ERRC_OPEN_FILE_FAILED:
            NSLog(@"打开文件失败");
            break;
        // ... 其他错误码
    }
}

@end
```

### 6.5 查看插件内存占用

```objc
WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];
size_t memoryUsed = [plugin pluginMemoryUsed];

NSLog(@"插件内存占用: %.2f MB", memoryUsed / 1024.0 / 1024.0);
```

---

## 7. 注意事项

### 7.1 性能影响

内存监控会带来一定的性能开销：

| 项目 | 影响 | 优化建议 |
|------|------|---------|
| **CPU** | +5-10% | 调整 `skipMinMallocSize` 和 `skipMaxStackDepth` |
| **内存** | +10-30MB | 设置 `dumpCallStacks = 2`（仅 OC 对象）|
| **磁盘 I/O** | 增加写入 | 使用独立线程异步写入 |
| **电量** | 轻微增加 | 线上环境使用保守配置 |

### 7.2 使用限制

#### 1. 不能在调试模式下使用

```objc
if ([MatrixDeviceInfo isBeingDebugged]) {
    MatrixDebug(@"app is being debugged, cannot start memstat");
    return NO;
}
```

**原因**：调试器也会使用 `malloc_logger`，会产生冲突。

#### 2. 私有 API 风险

代码中使用了 `__syscall_logger` 等私有 API：

```cpp
#ifdef USE_PRIVATE_API
static malloc_logger_t **syscall_logger;
#endif
```

**建议**：
- 开发和测试环境可以使用
- 线上环境需要评估风险
- 可以通过条件编译控制

#### 3. 符号化需要 dSYM

堆栈地址需要通过 dSYM 文件才能还原成可读的符号：

```
原始地址: 0x100abcd
符号化后: -[ViewController viewDidLoad] + 123
```

确保每次打包都保存对应的 dSYM 文件。

### 7.3 已知问题

#### 问题 1：内存报告未上报到服务器

**现象**：FOOM 检测到，但服务器没有收到内存报告。

**原因**：`MatrixHandler.mm` 中的上报逻辑过滤了内存报告：

```objc
- (void)uploadReportToServer:(MatrixIssue *)issue
{
    // 只上报卡顿和崩溃日志
    if (![issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        return;  // ⚠️ 这里会过滤掉内存报告
    }
    // ...
}
```

**解决方案**：修改上报逻辑，添加对内存报告的支持。

#### 问题 2：真机测试服务器连接失败

**现象**：模拟器可以上报，真机无法连接服务器。

**原因**：服务器地址配置为 `localhost`，真机无法访问。

**解决方案**：

1. 在 `Info.plist` 中配置服务器地址：
```xml
<key>MatrixServerURL</key>
<string>http://192.168.1.100:8080</string>
```

2. 或使用环境变量：
```objc
#if TARGET_OS_SIMULATOR
    serverHost = @"http://localhost:8080";
#else
    serverHost = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MatrixServerURL"];
    if (!serverHost) {
        serverHost = @"http://192.168.1.100:8080";  // 修改为 Mac 的 IP
    }
#endif
```

### 7.4 最佳实践

#### 1. 分阶段启用

```objc
// 根据环境调整配置
WCMemoryStatConfig *config = [WCMemoryStatConfig defaultConfiguration];

#if DEBUG
    // 开发环境：捕获更多信息
    config.skipMinMallocSize = 4096;
    config.skipMaxStackDepth = 15;
    config.dumpCallStacks = 1;
#else
    // 生产环境：平衡性能
    config.skipMinMallocSize = 32768;
    config.skipMaxStackDepth = 8;
    config.dumpCallStacks = 2;
#endif
```

#### 2. 灰度上报

不是所有用户都需要监控：

```objc
// 只对 10% 的用户启用
if (arc4random_uniform(100) < 10) {
    [[[MatrixHandler sharedInstance] getMemoryStatPlugin] start];
}
```

#### 3. 定期清理

```objc
// 定期清理历史记录，避免占用过多空间
WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];
NSArray *records = [plugin recordList];

// 只保留最近 5 条记录
if (records.count > 5) {
    for (NSInteger i = 5; i < records.count; i++) {
        [plugin deleteRecord:records[i]];
    }
}
```

#### 4. 监控插件本身

```objc
// 定期检查插件内存占用
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    WCMemoryStatPlugin *plugin = [[MatrixHandler sharedInstance] getMemoryStatPlugin];
    size_t memoryUsed = [plugin pluginMemoryUsed];
    
    // 如果超过 50MB，考虑停止监控
    if (memoryUsed > 50 * 1024 * 1024) {
        NSLog(@"⚠️  插件内存占用过高: %.2f MB", memoryUsed / 1024.0 / 1024.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [plugin stop];
        });
    }
});
```

---

## 8. 参考资料

### 8.1 官方文档

- [Memory Usage Performance Guidelines](https://developer.apple.com/library/content/documentation/Performance/Conceptual/ManagingMemory/ManagingMemory.html)
- [Understanding and Analyzing Application Crash Reports](https://developer.apple.com/library/archive/technotes/tn2151/_index.html)

### 8.2 技术文章

- [iOS微信内存监控 - WeTest](https://wetest.qq.com/labs/367)
- [Reducing FOOMs in the Facebook iOS app](https://code.facebook.com/posts/1146930688654547/reducing-fooms-in-the-facebook-ios-app/)
- [No pressure, Mon!](http://www.newosxbook.com/articles/MemoryPressure.html)

### 8.3 开源项目

- [Matrix-iOS](https://github.com/Tencent/matrix)
- [FBAllocationTracker](https://github.com/facebook/FBAllocationTracker)
- [fishhook](https://github.com/facebook/fishhook)

### 8.4 相关工具

- **Instruments Allocations**：开发阶段内存分析
- **Xcode Memory Debugger**：实时内存调试
- **Leaks**：内存泄漏检测
- **vmmap**：虚拟内存映射分析

---

## 9. 附录

### 9.1 错误码说明

在 `memory_stat_err_code.h` 中定义：

```c
#define MS_ERRC_SUCCESS                         0
#define MS_ERRC_WORKING_THREAD_CREATE_FAIL      1
#define MS_ERRC_OPEN_FILE_FAILED                2
#define MS_ERRC_WRITE_FILE_FAILED               3
#define MS_ERRC_MMAP_FAILED                     4
#define MS_ERRC_ALREADY_RUNNING                 5
```

### 9.2 目录结构

```
MatrixTestApp/
├── matrix-iOS/                          # Matrix 框架源码
│   └── Matrix/
│       └── WCMemoryStat/                # 内存监控模块
│           ├── MemoryLogger/            # 核心日志层 (C++)
│           │   ├── memory_logging.cpp   # 主要实现
│           │   ├── logger_internal.cpp  # 内部日志
│           │   ├── ObjectEvent/         # 对象事件
│           │   │   ├── allocation_event_db.cpp
│           │   │   ├── nsobject_hook.mm
│           │   │   └── ...
│           │   ├── StackFrames/         # 堆栈处理
│           │   │   ├── stack_frames_db.cpp
│           │   │   ├── dyld_image_info.cpp
│           │   │   └── ...
│           │   └── Tree/                # 数据结构
│           └── MemoryStatPlugin/        # 插件层 (ObjC)
│               ├── WCMemoryStatPlugin.mm
│               ├── WCMemoryStatConfig.mm
│               └── Record/
│                   ├── WCMemoryRecordManager.mm
│                   └── WCMemoryStatModel.mm
│
├── MatrixTestApp/                       # 测试应用
│   ├── Matrix/
│   │   ├── MatrixHandler.h              # Matrix 协调器
│   │   └── MatrixHandler.mm
│   └── TestOOMViewController.mm         # OOM 测试页面
│
└── matrix-symbolicate-server/           # 符号化服务器
    ├── main.go                          # Go 服务
    ├── symbolicate.go                   # 符号化逻辑
    └── reports/                         # 报告存储
```

### 9.3 数据文件格式

内存记录文件存储在：

```
Library/Caches/Matrix/MemoryStat/Data/{launchTime}/
├── allocation_events.dat        # 分配事件数据库
├── stack_frames.dat             # 堆栈帧数据库
├── dyld_images.dat              # dyld 镜像信息
└── object_types.dat             # 对象类型映射
```

### 9.4 关键宏定义

```c
// 虚拟内存标志
#define VM_MEMORY_MALLOC                1
#define VM_MEMORY_MALLOC_SMALL          2
#define VM_MEMORY_MALLOC_LARGE          3
#define VM_MEMORY_MALLOC_HUGE           4
#define VM_MEMORY_MALLOC_NANO           11

#define VM_MEMORY_IOKIT                 21
#define VM_MEMORY_GRAPHICS              22
#define VM_MEMORY_JAVASCRIPT_CORE       35

// 内存日志类型
#define memory_logging_type_alloc       0x00000002
#define memory_logging_type_dealloc     0x00000004
#define memory_logging_type_vm_allocate 0x00000010
#define memory_logging_type_vm_deallocate 0x00000020
#define memory_logging_type_mapped_file_or_shared_mem 0x00000080
```

---

## 总结

本文档详细介绍了基于腾讯 Matrix 框架的 iOS 内存监控技术实现：

1. **原理层**：利用 `malloc_logger` 和 `__syscall_logger` 监控内存分配
2. **实现层**：多线程异步处理、数据库存储、堆栈捕获
3. **应用层**：FOOM 检测、自动上报、符号化分析

通过合理的配置和使用，可以有效地在线上发现和定位内存问题，大幅降低 FOOM 率，提升用户体验。

---

**文档版本**：v1.0  
**更新时间**：2026-01-06  
**维护者**：Matrix 项目组

