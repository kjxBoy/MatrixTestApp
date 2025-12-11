# Matrix 卡顿检测与堆栈收集源码阅读指南

## 📖 目录

1. [概述](#概述)
2. [核心架构](#核心架构)
3. [工作原理](#工作原理)
4. [源码阅读路径](#源码阅读路径)
5. [关键代码解析](#关键代码解析)
6. [调试建议](#调试建议)

---

## 概述

Matrix 的卡顿检测机制基于 **Runloop 监听** + **子线程定期检查** 的双重保障方案。通过监控主线程的 Runloop 状态，结合定期收集主线程堆栈，实现对主线程卡顿的精准捕获。

### 核心思路

- **Runloop 监听**: 监听 `kCFRunLoopBeforeSources` 和 `kCFRunLoopBeforeWaiting`，记录时间戳
- **子线程定时检查**: 独立线程定期检查主线程是否超时
- **堆栈收集**: 定期收集主线程堆栈，找出最耗时的调用栈
- **崩溃报告集成**: 使用 KSCrash 框架生成完整的崩溃/卡顿报告

---

## 核心架构

### 目录结构

```
matrix-iOS/Matrix/WCCrashBlockMonitor/
├── CrashBlockPlugin/
│   ├── Main/
│   │   ├── WCCrashBlockMonitor.mm        # 插件主类
│   │   └── BlockMonitor/
│   │       ├── WCBlockMonitorMgr.mm      # 卡顿监控管理器 ⭐️
│   │       ├── Handler/
│   │       │   ├── WCMainThreadHandler.mm     # 主线程堆栈处理 ⭐️
│   │       │   ├── WCGetMainThreadUtil.mm     # 获取主线程堆栈工具 ⭐️
│   │       │   ├── WCCPUHandler.mm            # CPU 监控
│   │       │   └── WCFilterStackHandler.mm    # 堆栈过滤去重
│   │       └── Report/
│   │           └── WCDumpInterface.mm         # 堆栈 Dump 接口 ⭐️
│   └── WCCrashBlockMonitorConfig.mm      # 配置类
└── KSCrash/                              # 崩溃报告框架
    └── Recording/
        └── KSCrashC.c                    # 堆栈收集核心 ⭐️
```

### 类关系图

```
                    Matrix
                      ↓
          WCCrashBlockMonitorPlugin
                      ↓
            WCBlockMonitorMgr (核心)
                      ↓
        ┌─────────────┼─────────────┐
        ↓             ↓             ↓
WCMainThreadHandler  WCCPUHandler  WCDumpInterface
        ↓                           ↓
WCGetMainThreadUtil              KSCrash
```

---

## 工作原理

### 1. Runloop 监听原理

**核心代码**: `WCBlockMonitorMgr.mm` 行 987-1042

```objc
// Runloop 开始回调
void myRunLoopBeginCallback(CFRunLoopObserverRef observer, 
                           CFRunLoopActivity activity, 
                           void *info) {
    g_runLoopActivity = activity;
    switch (activity) {
        case kCFRunLoopAfterWaiting:    // 从休眠中唤醒
        case kCFRunLoopBeforeSources:   // 即将处理 Source
        case kCFRunLoopBeforeTimers:    // 即将处理 Timer
            gettimeofday(&g_tvRun, NULL);  // ⭐️ 记录开始时间
            g_bRun = YES;                  // ⭐️ 标记为运行中
            break;
    }
}

// Runloop 结束回调
void myRunLoopEndCallback(CFRunLoopObserverRef observer, 
                         CFRunLoopActivity activity, 
                         void *info) {
    g_runLoopActivity = activity;
    switch (activity) {
        case kCFRunLoopBeforeWaiting:   // 即将休眠
            gettimeofday(&g_tvRun, NULL);
            g_bRun = NO;                   // ⭐️ 标记为非运行中
            break;
    }
}
```

**监听的时间段**:
```
BeforeSources/BeforeTimers/AfterWaiting → BeforeWaiting
                ↑                              ↑
            标记开始时间                    标记结束时间
```

如果这个时间段超过阈值（默认 3 秒），就认为发生了卡顿。

### 2. 定时检查机制

**核心代码**: `WCBlockMonitorMgr.mm` 行 568-692

```objc
- (void)threadProc {
    while (!m_bStop) {
        // 1. 定期收集主线程堆栈 (每 50ms 一次)
        [self recordStackForTid];
        
        // 2. 检查是否发生卡顿
        EDumpType dumpType = [self check];
        
        // 3. 如果检测到卡顿，生成报告
        if (dumpType != EDumpType_Unlag) {
            [self handleBlockWithDumpType:dumpType];
        }
    }
}
```

**检查逻辑** (`check` 方法, 行 694-744):

```objc
- (EDumpType)check {
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);
    
    // 计算从 g_tvRun 到现在的时间差
    unsigned long long diff = [WCBlockMonitorMgr diffTime:&tmp_g_tvRun 
                                                  endTime:&tvCur];
    
    // 如果 Runloop 还在运行，且时间差超过阈值
    if (tmp_g_bRun && diff > g_RunLoopTimeOut) {
        return EDumpType_MainThreadBlock;  // ⭐️ 主线程卡顿
    }
    
    return EDumpType_Unlag;
}
```

### 3. 堆栈收集机制

**收集频率**: 每 50ms 收集一次主线程堆栈

**核心代码**: `WCBlockMonitorMgr.mm` 行 648-692

```objc
- (void)recordStackForTid {
    // 每个检查周期内多次采样主线程堆栈
    int intervalCount = g_CheckPeriodTime / g_PerStackInterval;  // 1s / 50ms = 20次
    
    for (int index = 0; index < intervalCount; index++) {
        usleep(g_PerStackInterval);  // 休眠 50ms
        
        // 分配堆栈缓冲区
        uintptr_t *stackArray = (uintptr_t *)malloc(sizeof(uintptr_t) * 100);
        
        // ⭐️ 获取主线程当前堆栈
        [WCGetMainThreadUtil getCurrentMainThreadStack:^(NSUInteger pc) {
            stackArray[nSum++] = (uintptr_t)pc;  // 记录每个栈帧的 PC
        } withMaxEntries:100 withThreadCount:g_CurrentThreadCount];
        
        // ⭐️ 添加到堆栈处理器，进行统计和去重
        [m_pointMainThreadHandler addThreadStack:stackArray 
                                   andStackCount:nSum];
    }
}
```

### 4. 堆栈统计与去重

**核心代码**: `WCMainThreadHandler.mm`

```objc
- (void)addThreadStack:(uintptr_t *)stackArray 
        andStackCount:(size_t)stackCount {
    // 1. 计算堆栈的哈希值
    NSString *stackHash = [self hashForStack:stackArray count:stackCount];
    
    // 2. 如果是重复的堆栈，增加计数
    if ([m_pointStackArray containsObject:stackHash]) {
        NSInteger index = [m_pointStackArray indexOfObject:stackHash];
        m_stackRepeatCountArray[index]++;  // ⭐️ 记录重复次数
    } else {
        // 3. 如果是新堆栈，添加到数组
        [m_pointStackArray addObject:stackHash];
        m_stackRepeatCountArray[index] = 1;
    }
}

- (KSStackCursor *)getPointMainThreadCursor {
    // 找出重复次数最多的堆栈（最耗时的）
    NSInteger maxIndex = [self findMaxRepeatCountIndex];
    return m_pointCursorArray[maxIndex];  // ⭐️ 返回最耗时的堆栈
}
```

**原理**: 
- 相同的堆栈会被采样多次
- 重复次数越多，说明在该位置停留的时间越长
- 最终选择重复次数最多的堆栈作为卡顿原因

### 5. 生成崩溃报告

**核心代码**: `WCDumpInterface.mm` 行 26-61

```objc
+ (NSString *)dumpReportWithReportType:(EDumpType)dumpType
                  suspendAllThreads:(BOOL)suspendAllThreads
                     enableSnapshot:(BOOL)enableSnapshot {
    // 1. 获取最耗时的主线程堆栈
    KSStackCursor *pointCursor = kscrash_pointThreadCallback();
    
    // 2. 通过 KSCrash 生成完整报告
    [KSCrash reportUserException:@"BlockMonitor"
                          reason:@"Main Thread Block"
                        language:@"objc"
                     lineOfCode:nil
                      stackTrace:pointCursor  // ⭐️ 传入主线程堆栈
                  logAllThreads:YES
                  enableSnapshot:enableSnapshot
                terminateProgram:NO
                  writeCpuUsage:YES
                    dumpFilePath:path
                        dumpType:dumpType];
    
    return path;  // 返回报告文件路径
}
```

---

## 源码阅读路径

### 🎯 推荐阅读顺序

#### 第 1 步: 从入口开始 (10分钟)

1. **`MatrixTestApp/main.mm`** (28 行)
   - 看 Matrix 如何初始化
   - 找到插件安装入口

2. **`MatrixTestApp/Matrix/MatrixHandler.mm`** (52-91 行)
   - 看配置项的含义
   - 理解插件的启动流程

```objc
// 关键配置
crashBlockConfig.enableBlockMonitor = YES;           // 启用卡顿监控
blockMonitorConfig.bMainThreadHandle = YES;          // 收集主线程堆栈
blockMonitorConfig.bFilterSameStack = YES;           // 过滤重复堆栈
blockMonitorConfig.triggerToBeFilteredCount = 10;    // 过滤阈值
```

#### 第 2 步: 核心监控流程 (30分钟)

3. **`WCBlockMonitorMgr.mm`** - 按以下顺序阅读:

   **a. 初始化部分** (行 200-300)
   ```objc
   - (void)start              // 启动监控
   - (void)addRunLoopObserver // 添加 Runloop 观察者
   ```

   **b. Runloop 回调** (行 987-1076) ⭐️ **最重要**
   ```objc
   void myRunLoopBeginCallback()  // Runloop 开始
   void myRunLoopEndCallback()    // Runloop 结束
   ```
   
   💡 **阅读建议**: 在纸上画出 Runloop 各个阶段，标注什么时候记录时间

   **c. 检测线程循环** (行 568-692) ⭐️ **最重要**
   ```objc
   - (void)threadProc          // 检测线程主循环
   - (void)recordStackForTid   // 收集主线程堆栈
   - (EDumpType)check          // 检查是否卡顿
   ```
   
   💡 **阅读建议**: 
   - 关注 `g_bRun` 和 `g_tvRun` 这两个全局变量
   - 理解为什么要用子线程定期检查

#### 第 3 步: 堆栈收集 (20分钟)

4. **`Handler/WCGetMainThreadUtil.mm`**
   ```objc
   + (void)getCurrentMainThreadStack:withMaxEntries:withThreadCount:
   ```
   - 如何获取主线程堆栈
   - 看 `thread_get_state` 系统调用

5. **`Handler/WCMainThreadHandler.mm`**
   ```objc
   - (void)addThreadStack:andStackCount:        // 添加堆栈
   - (KSStackCursor *)getPointMainThreadCursor  // 获取最耗时堆栈
   ```
   - 如何统计堆栈重复次数
   - 如何找出最耗时的堆栈

#### 第 4 步: 报告生成 (15分钟)

6. **`Report/WCDumpInterface.mm`**
   ```objc
   + (NSString *)dumpReportWithReportType:...
   ```
   - 如何生成卡顿报告
   - 看调用 KSCrash 的过程

7. **`KSCrash/Recording/KSCrashC.c`**
   ```c
   void kscrash_reportUserException(...)  // 生成报告入口
   ```
   - 看报告的 JSON 格式
   - 理解如何收集所有线程堆栈

---

## 关键代码解析

### 🔍 代码片段 1: Runloop 监听的精妙之处

**文件**: `WCBlockMonitorMgr.mm` 行 987-1042

```objc
// 为什么要监听这几个时刻？

// kCFRunLoopBeforeSources: 即将处理 Source0（触摸、滚动等事件）
// kCFRunLoopBeforeTimers:  即将处理 Timer
// kCFRunLoopAfterWaiting:  从休眠中唤醒，即将处理事件

// 这三个时刻标志着"主线程开始工作"
void myRunLoopBeginCallback(...) {
    gettimeofday(&g_tvRun, NULL);  // 记录开始工作的时间
    g_bRun = YES;
}

// kCFRunLoopBeforeWaiting: 即将休眠
// 这个时刻标志着"主线程工作完成"
void myRunLoopEndCallback(...) {
    g_bRun = NO;  // 标记为非运行状态
}
```

**关键理解**:
- `g_bRun = YES` 期间就是主线程在处理任务的时间
- 如果这个时间过长（超过 3 秒），说明某个任务执行太慢，导致卡顿

### 🔍 代码片段 2: 为什么用子线程定时检查？

**文件**: `WCBlockMonitorMgr.mm` 行 694-744

```objc
- (EDumpType)check {
    // 读取全局变量（注意：这在子线程中执行）
    BOOL tmp_g_bRun = g_bRun;
    struct timeval tmp_g_tvRun = g_tvRun;
    
    // 计算时间差
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);
    unsigned long long diff = [WCBlockMonitorMgr diffTime:&tmp_g_tvRun 
                                                  endTime:&tvCur];
    
    // 如果主线程还在运行，且超时了
    if (tmp_g_bRun && diff > g_RunLoopTimeOut) {
        return EDumpType_MainThreadBlock;
    }
    
    return EDumpType_Unlag;
}
```

**为什么不直接在 Runloop 回调中检查？**
- 因为如果主线程卡死了，Runloop 回调也不会被调用！
- 必须用独立的子线程来检查主线程是否超时
- 这是一种"看门狗"（Watchdog）设计模式

### 🔍 代码片段 3: 堆栈采样的巧妙统计

**文件**: `WCMainThreadHandler.mm`

```objc
// 假设卡顿 3 秒，每 50ms 采样一次，共采样 60 次

// 场景：方法 A 执行了 2 秒，方法 B 执行了 1 秒
//
// 采样结果:
//   方法 A 的堆栈: 重复 40 次  (2000ms / 50ms)
//   方法 B 的堆栈: 重复 20 次  (1000ms / 50ms)
//
// 结论：方法 A 是卡顿的主要原因（重复次数最多）

- (KSStackCursor *)getPointMainThreadCursor {
    // 找出重复次数最多的堆栈
    NSInteger maxRepeatCount = 0;
    NSInteger maxIndex = 0;
    
    for (int i = 0; i < m_stackCount; i++) {
        if (m_stackRepeatCountArray[i] > maxRepeatCount) {
            maxRepeatCount = m_stackRepeatCountArray[i];
            maxIndex = i;  // ⭐️ 记录最耗时堆栈的索引
        }
    }
    
    return m_pointCursorArray[maxIndex];  // 返回最耗时的堆栈
}
```

**原理总结**:
- **采样频率**: 50ms 一次
- **统计方法**: 相同堆栈计数
- **选择策略**: 重复次数最多 = 最耗时

---

## 调试建议

### 🐛 添加调试日志

在关键位置添加日志，理解执行流程：

```objc
// WCBlockMonitorMgr.mm - Runloop 回调
void myRunLoopBeginCallback(...) {
    gettimeofday(&g_tvRun, NULL);
    g_bRun = YES;
    NSLog(@"🟢 Runloop 开始工作: %lu", activity);  // ⭐️ 添加这行
}

void myRunLoopEndCallback(...) {
    g_bRun = NO;
    NSLog(@"🔴 Runloop 休眠: %lu", activity);  // ⭐️ 添加这行
}

// WCBlockMonitorMgr.mm - 检查方法
- (EDumpType)check {
    // ...
    if (tmp_g_bRun && diff > g_RunLoopTimeOut) {
        NSLog(@"⚠️ 检测到卡顿! 时长: %llu ms", diff / 1000);  // ⭐️ 添加这行
        return EDumpType_MainThreadBlock;
    }
}
```

### 🔬 断点调试建议

**推荐断点位置**:

1. `WCBlockMonitorMgr.mm:720` - check 方法中检测到卡顿的地方
   ```objc
   if (tmp_g_bRun && diff > g_RunLoopTimeOut) {
       m_blockDiffTime = diff;  // ⬅️ 在这里打断点
   ```

2. `WCMainThreadHandler.mm` - 获取最耗时堆栈
   ```objc
   - (KSStackCursor *)getPointMainThreadCursor {
       // ... 计算最大重复次数的逻辑
       return m_pointCursorArray[maxIndex];  // ⬅️ 在这里打断点
   }
   ```

3. `WCDumpInterface.mm:48` - 生成报告
   ```objc
   [KSCrash reportUserException:...];  // ⬅️ 在这里打断点
   ```

### 🧪 测试卡顿的方法

在你的测试代码中:

```objc
// MatrixTestApp/Matrix/MatrixTester.mm
- (void)generateMainThreadLagLog {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 模拟 5 秒卡顿
        sleep(5);  // ⬅️ 观察 Matrix 如何捕获这个卡顿
    });
}
```

**观察点**:
1. Console 中的 Matrix 日志
2. 断点是否触发
3. 生成的报告文件位置

---

## 核心配置参数

**文件**: `WCBlockMonitorConfiguration.h`

```objc
// 主要配置项
@property (nonatomic, assign) useconds_t runloopTimeOut;       // 默认 3000000 (3秒)
@property (nonatomic, assign) useconds_t checkPeriodTime;      // 默认 1000000 (1秒)
@property (nonatomic, assign) useconds_t perStackInterval;     // 默认 50000   (50ms)
@property (nonatomic, assign) size_t limitStackCount;          // 默认 100
@property (nonatomic, assign) BOOL bMainThreadHandle;          // 是否收集主线程堆栈
@property (nonatomic, assign) BOOL bFilterSameStack;           // 是否过滤相同堆栈
```

**参数解释**:

| 参数 | 默认值 | 说明 |
|------|--------|------|
| runloopTimeOut | 3s | 主线程卡顿阈值，超过此时间认为卡顿 |
| checkPeriodTime | 1s | 检测线程每隔多久检查一次 |
| perStackInterval | 50ms | 采样主线程堆栈的频率 |
| limitStackCount | 100 | 每个堆栈最多记录多少个栈帧 |
| bMainThreadHandle | YES | 是否收集主线程堆栈（必须开启） |
| bFilterSameStack | YES | 是否过滤重复堆栈（建议开启） |

---

## 常见问题解答

### Q1: 为什么采样频率是 50ms？

**答**: 
- 50ms 是一个平衡点
- 太快: CPU 开销大，影响性能
- 太慢: 可能错过短暂的卡顿
- 50ms × 60 次 = 3 秒，刚好是默认的卡顿阈值

### Q2: 如果主线程卡顿超过 10 秒会怎样？

**答**:
- 系统的 Watchdog 可能会杀掉进程（iOS 有自己的看门狗）
- Matrix 会在卡顿发生时（超过 3 秒）立即生成报告
- 不会等到 10 秒后才报告

### Q3: 为什么不用 CADisplayLink 检测卡顿？

**答**:
- CADisplayLink 依赖屏幕刷新（60fps）
- 如果主线程卡死，CADisplayLink 也不会触发
- Runloop 监听 + 独立线程更可靠

### Q4: 堆栈采样会影响性能吗？

**答**:
- 有一定影响，但很小（< 1% CPU）
- 只在怀疑卡顿时才密集采样
- 正常情况下不采样，不影响性能

---

## 总结

### 🎯 核心要点

1. **双重保障**: Runloop 监听 + 子线程检查
2. **采样统计**: 通过重复次数找出最耗时的代码
3. **完整报告**: 使用 KSCrash 生成详细的崩溃/卡顿报告

### 📚 学习建议

1. **先理解原理** (30分钟)
   - 画出 Runloop 的各个阶段
   - 理解为什么要用子线程检查

2. **再读核心代码** (1小时)
   - `WCBlockMonitorMgr.mm` 的 threadProc、check、Runloop 回调
   - `WCMainThreadHandler.mm` 的堆栈统计逻辑

3. **最后实践调试** (30分钟)
   - 添加日志
   - 打断点
   - 模拟卡顿并观察

### 🚀 下一步

- 阅读 KSCrash 的堆栈收集实现
- 了解 CPU 监控的实现 (`WCCPUHandler.mm`)
- 研究内存监控的实现 (`WCMemoryStatPlugin`)

---

**文档作者**: Cursor AI Assistant  
**最后更新**: 2025-01-10  
**适用版本**: Matrix iOS (微信开源版本)

