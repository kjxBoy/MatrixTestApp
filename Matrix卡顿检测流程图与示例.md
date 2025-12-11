# Matrix 卡顿检测流程图与代码示例

## 📊 完整执行流程图

### 1. 整体架构流程

```
应用启动
   ↓
main.mm: installMatrix
   ↓
MatrixHandler: 配置并启动插件
   ↓
WCCrashBlockMonitorPlugin: start
   ↓
WCBlockMonitorMgr: start
   ↓
┌─────────────────────────────────────────┐
│  添加 Runloop 观察者 (主线程)            │
│  - kCFRunLoopBeforeSources              │
│  - kCFRunLoopBeforeTimers               │
│  - kCFRunLoopAfterWaiting               │
│  - kCFRunLoopBeforeWaiting              │
└─────────────────────────────────────────┘
   ↓
┌─────────────────────────────────────────┐
│  启动检测线程 (子线程)                   │
│  while (!m_bStop) {                     │
│      1. 定期采样主线程堆栈               │
│      2. 检查是否卡顿                     │
│      3. 如果卡顿，生成报告               │
│  }                                      │
└─────────────────────────────────────────┘
```

### 2. 卡顿检测详细流程

```
┌─────────────────────────────────────────────────────────┐
│                    主线程 Runloop                        │
└─────────────────────────────────────────────────────────┘
        │                                      │
        │ ① BeforeSources                     │ ④ BeforeWaiting
        │                                      │
        ↓                                      ↓
   记录开始时间                           标记运行结束
   g_tvRun = now()                        g_bRun = NO
   g_bRun = YES
        │
        │ ② 处理事件 (可能卡顿)
        │
        ↓
┌─────────────────────────────────────────────────────────┐
│                    检测线程循环                          │
│                                                          │
│  while (!m_bStop) {                                     │
│      ③ 每 50ms 采样一次主线程堆栈                       │
│         └─> 收集 PC 地址                                │
│         └─> 添加到 WCMainThreadHandler                  │
│         └─> 统计重复次数                                │
│                                                          │
│      ④ 每 1 秒检查一次是否超时                          │
│         if (g_bRun && now() - g_tvRun > 3s) {          │
│             ⚠️ 检测到卡顿!                              │
│             └─> 获取重复次数最多的堆栈                  │
│             └─> 调用 WCDumpInterface 生成报告           │
│         }                                               │
│  }                                                      │
└─────────────────────────────────────────────────────────┘
```

### 3. 堆栈采样与统计流程

```
时间轴 (假设卡顿 3 秒):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
0ms    方法 A 开始执行
       ↓
50ms   采样 #1: [main -> A]                    count: 1
       ↓
100ms  采样 #2: [main -> A]                    count: 2
       ↓
150ms  采样 #3: [main -> A]                    count: 3
       ↓
       ... (省略中间采样)
       ↓
2000ms 采样 #40: [main -> A]                   count: 40
       方法 A 执行完毕，开始执行方法 B
       ↓
2050ms 采样 #41: [main -> A -> B]              count: 1
       ↓
2100ms 采样 #42: [main -> A -> B]              count: 2
       ↓
       ... (省略中间采样)
       ↓
3000ms 采样 #60: [main -> A -> B]              count: 20
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

统计结果:
┌────────────────────────────────────┐
│ 堆栈类型      │ 重复次数  │ 占比  │
├────────────────────────────────────┤
│ [main -> A]   │   40     │ 67%   │  ⭐️ 最耗时
│ [main->A->B]  │   20     │ 33%   │
└────────────────────────────────────┘

选择: [main -> A] 作为卡顿堆栈上报
```

---

## 💻 关键代码执行示例

### 示例 1: 从点击按钮到检测卡顿

```objc
// ============================================================================
// 第 1 步: 用户点击按钮 (TestLagViewController.mm)
// ============================================================================
- (void)simulateLag {
    dispatch_async(dispatch_get_main_queue(), ^{
        sleep(5);  // 模拟 5 秒卡顿
    });
}

// ============================================================================
// 第 2 步: Runloop 回调被触发 (WCBlockMonitorMgr.mm)
// ============================================================================

// 时刻 T0: Runloop 即将处理事件
void myRunLoopBeginCallback(CFRunLoopObserverRef observer, 
                           CFRunLoopActivity activity, 
                           void *info) {
    // activity == kCFRunLoopBeforeSources
    gettimeofday(&g_tvRun, NULL);  // g_tvRun = T0
    g_bRun = YES;
    
    // 日志: "🟢 Runloop 开始工作: BeforeSources"
}

// ============================================================================
// 第 3 步: 检测线程采样堆栈 (WCBlockMonitorMgr.mm:648-692)
// ============================================================================

// 时刻 T0 + 50ms
[WCGetMainThreadUtil getCurrentMainThreadStack:^(NSUInteger pc) {
    // 收集到的堆栈 (第 1 次采样):
    // 0: main
    // 1: UIApplicationMain
    // 2: -[ViewController simulateLag]_block_invoke
    // 3: sleep
    stackArray[nSum++] = pc;
}];
[m_pointMainThreadHandler addThreadStack:stackArray andStackCount:nSum];
// 统计: [main->ViewController->sleep] count = 1

// 时刻 T0 + 100ms (第 2 次采样)
// 统计: [main->ViewController->sleep] count = 2

// ... 重复采样 ...

// 时刻 T0 + 3000ms (第 60 次采样)
// 统计: [main->ViewController->sleep] count = 60

// ============================================================================
// 第 4 步: 检测线程检查超时 (WCBlockMonitorMgr.mm:694-744)
// ============================================================================

// 时刻 T0 + 3000ms
- (EDumpType)check {
    BOOL tmp_g_bRun = g_bRun;              // = YES
    struct timeval tmp_g_tvRun = g_tvRun;  // = T0
    
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);            // = T0 + 3000ms
    
    unsigned long long diff = tvCur - tmp_g_tvRun;  // = 3000000 微秒
    
    if (tmp_g_bRun && diff > g_RunLoopTimeOut) {    // YES && 3000000 > 3000000
        // ⚠️ 检测到卡顿!
        MatrixInfo(@"检测到主线程卡顿，时长: %llu ms", diff / 1000);
        return EDumpType_MainThreadBlock;
    }
}

// ============================================================================
// 第 5 步: 获取最耗时堆栈 (WCMainThreadHandler.mm)
// ============================================================================
- (KSStackCursor *)getPointMainThreadCursor {
    // 遍历所有堆栈，找出重复次数最多的
    for (int i = 0; i < m_stackCount; i++) {
        if (m_stackRepeatCountArray[i] > maxRepeatCount) {
            maxRepeatCount = m_stackRepeatCountArray[i];  // = 60
            maxIndex = i;  // 堆栈: [main->ViewController->sleep]
        }
    }
    return m_pointCursorArray[maxIndex];
}

// ============================================================================
// 第 6 步: 生成卡顿报告 (WCDumpInterface.mm)
// ============================================================================
+ (NSString *)dumpReportWithReportType:(EDumpType)dumpType
                  suspendAllThreads:(BOOL)suspendAllThreads {
    // 获取最耗时的堆栈
    KSStackCursor *mainThreadCursor = kscrash_pointThreadCallback();
    
    // 调用 KSCrash 生成报告
    [KSCrash reportUserException:@"BlockMonitor"
                          reason:@"Main Thread Block"
                      stackTrace:mainThreadCursor  // ⭐️ 传入主线程堆栈
                  logAllThreads:YES
                  enableSnapshot:YES
                    dumpFilePath:@"lag_report.json"];
    
    // 日志: "生成卡顿报告: /path/to/lag_report.json"
}

// ============================================================================
// 第 7 步: 报告回调 (WCCrashBlockMonitor.mm)
// ============================================================================
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr 
           getDumpFile:(NSString *)dumpFile 
          withDumpType:(EDumpType)dumpType {
    // 获取到报告文件路径
    MatrixInfo(@"📄 卡顿报告已生成: %@", dumpFile);
    
    // 可以上传到服务器或者本地查看
}
```

---

## 🔍 关键数据结构

### 1. 全局状态变量

```objc
// WCBlockMonitorMgr.mm 顶部

// Runloop 状态
static BOOL g_bRun = NO;               // 主线程是否在运行
static struct timeval g_tvRun;          // 主线程开始运行的时间
static CFRunLoopActivity g_runLoopActivity;  // 当前 Runloop 活动

// 配置参数
static useconds_t g_RunLoopTimeOut = 3000000;      // 3 秒 (卡顿阈值)
static useconds_t g_CheckPeriodTime = 1000000;     // 1 秒 (检查周期)
static useconds_t g_PerStackInterval = 50000;      // 50 毫秒 (采样间隔)

// 堆栈数据
static KSStackCursor *g_PointMainThreadArray = NULL;          // 堆栈数组
static int *g_PointMainThreadRepeatCountArray = NULL;         // 重复次数数组
static int g_MainThreadCount = 0;                             // 堆栈总数
```

### 2. 堆栈数据结构

```c
// KSCrash 定义的堆栈游标
typedef struct KSStackCursor {
    void *context;                    // 上下文
    uintptr_t *stackArray;            // 堆栈地址数组
    int stackLength;                  // 堆栈深度
    // ...
} KSStackCursor;

// 示例数据:
KSStackCursor cursor = {
    .stackArray = [
        0x100204f10,   // main
        0x1804aabf8,   // UIApplicationMain
        0x10029381c,   // -[ViewController simulateLag]_block_invoke
        0x180f46280    // sleep
    ],
    .stackLength = 4
};
```

### 3. 报告 JSON 格式

```json
{
  "crash": {
    "threads": [
      {
        "index": 0,
        "name": "main",
        "backtrace": {
          "contents": [
            {
              "instruction_addr": 4295000848,
              "object_name": "MatrixTestApp",
              "symbol_name": "main"
            },
            {
              "instruction_addr": 6442844664,
              "object_name": "UIKitCore",
              "symbol_name": "UIApplicationMain"
            },
            {
              "instruction_addr": 4297696284,
              "object_name": "MatrixTestApp",
              "symbol_name": "-[MatrixTester generateMainThreadLagLog]_block_invoke"
            }
          ]
        },
        "lag_stack_repeat": 60  // ⭐️ 重复次数
      }
    ]
  },
  "system": {
    "app_start_time": "2025-01-10 10:30:00",
    "CFBundleVersion": "1.0",
    "cpu_arch": "arm64"
  },
  "binary_images": [
    {
      "image_addr": 4294967296,
      "image_size": 1048576,
      "name": "/path/to/MatrixTestApp",
      "uuid": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    }
  ]
}
```

---

## 🎯 实战调试步骤

### 步骤 1: 添加详细日志

在 `WCBlockMonitorMgr.mm` 中添加以下日志:

```objc
// ============================================================================
// 在 Runloop 回调中添加日志
// ============================================================================
void myRunLoopBeginCallback(CFRunLoopObserverRef observer, 
                           CFRunLoopActivity activity, 
                           void *info) {
    g_runLoopActivity = activity;
    
    // ⭐️ 添加详细日志
    const char *activityName = "";
    switch (activity) {
        case kCFRunLoopEntry:         activityName = "Entry"; break;
        case kCFRunLoopBeforeTimers:  activityName = "BeforeTimers"; break;
        case kCFRunLoopBeforeSources: activityName = "BeforeSources"; break;
        case kCFRunLoopAfterWaiting:  activityName = "AfterWaiting"; break;
    }
    
    gettimeofday(&g_tvRun, NULL);
    g_bRun = YES;
    
    NSLog(@"🟢 [Runloop] %s - 开始工作 (时间: %ld.%06d)", 
          activityName, 
          g_tvRun.tv_sec, 
          g_tvRun.tv_usec);
}

void myRunLoopEndCallback(CFRunLoopObserverRef observer, 
                         CFRunLoopActivity activity, 
                         void *info) {
    struct timeval tvEnd;
    gettimeofday(&tvEnd, NULL);
    
    unsigned long long duration = (tvEnd.tv_sec - g_tvRun.tv_sec) * 1000000 + 
                                  (tvEnd.tv_usec - g_tvRun.tv_usec);
    
    g_bRun = NO;
    
    NSLog(@"🔴 [Runloop] BeforeWaiting - 完成工作 (耗时: %llu ms)", 
          duration / 1000);
}

// ============================================================================
// 在检查方法中添加日志
// ============================================================================
- (EDumpType)check {
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);
    unsigned long long diff = [WCBlockMonitorMgr diffTime:&tmp_g_tvRun 
                                                  endTime:&tvCur];
    
    // ⭐️ 添加日志
    if (tmp_g_bRun) {
        if (diff > g_RunLoopTimeOut) {
            NSLog(@"⚠️  [检测] 发现卡顿! 时长: %llu ms (阈值: %u ms)", 
                  diff / 1000, 
                  g_RunLoopTimeOut / 1000);
            return EDumpType_MainThreadBlock;
        } else if (diff > g_RunLoopTimeOut * 0.8) {
            NSLog(@"⏱️  [检测] 接近卡顿阈值: %llu ms / %u ms", 
                  diff / 1000, 
                  g_RunLoopTimeOut / 1000);
        }
    }
    
    return EDumpType_Unlag;
}

// ============================================================================
// 在堆栈采样中添加日志
// ============================================================================
- (void)recordStackForTid {
    int sampleCount = 0;
    
    for (int index = 0; index < intervalCount; index++) {
        usleep(g_PerStackInterval);
        
        // 获取堆栈
        [WCGetMainThreadUtil getCurrentMainThreadStack:^(NSUInteger pc) {
            stackArray[nSum++] = pc;
        }];
        
        // 添加到处理器
        [m_pointMainThreadHandler addThreadStack:stackArray 
                                   andStackCount:nSum];
        
        sampleCount++;
    }
    
    // ⭐️ 每秒输出一次采样统计
    NSLog(@"📊 [采样] 本轮采样 %d 次，总堆栈类型: %d", 
          sampleCount, 
          m_pointMainThreadHandler.stackCount);
}
```

### 步骤 2: 运行并观察日志

触发卡顿后，你会看到类似的日志输出:

```
🟢 [Runloop] BeforeSources - 开始工作 (时间: 1704870000.123456)
📊 [采样] 本轮采样 20 次，总堆栈类型: 1
⏱️  [检测] 接近卡顿阈值: 2500 ms / 3000 ms
📊 [采样] 本轮采样 20 次，总堆栈类型: 1
⚠️  [检测] 发现卡顿! 时长: 3100 ms (阈值: 3000 ms)
🔧 [生成报告] 开始获取主线程堆栈
🔧 [堆栈统计] 最耗时堆栈重复次数: 62
📄 [报告生成] 完成: /path/to/lag_report.json
🔴 [Runloop] BeforeWaiting - 完成工作 (耗时: 5000 ms)
```

### 步骤 3: 添加断点

**推荐断点位置**:

1. **`WCBlockMonitorMgr.mm:720`** - 检测到卡顿时
   ```objc
   if (tmp_g_bRun && diff > g_RunLoopTimeOut) {
       m_blockDiffTime = diff;  // ⬅️ 断点 1
   ```
   
   **观察变量**:
   - `diff`: 卡顿时长（微秒）
   - `g_RunLoopTimeOut`: 阈值
   - `tmp_g_tvRun`: 开始时间

2. **`WCMainThreadHandler.mm`** - 获取最耗时堆栈
   ```objc
   return m_pointCursorArray[maxIndex];  // ⬅️ 断点 2
   ```
   
   **观察变量**:
   - `maxRepeatCount`: 最大重复次数
   - `maxIndex`: 最耗时堆栈的索引
   - `m_pointCursorArray[maxIndex]`: 完整堆栈

3. **`WCDumpInterface.mm:48`** - 生成报告
   ```objc
   [KSCrash reportUserException:...];  // ⬅️ 断点 3
   ```
   
   **观察变量**:
   - `pointCursor`: 主线程堆栈游标
   - `path`: 报告文件路径

---

## 🧪 测试用例

### 测试 1: 简单的 sleep 卡顿

```objc
// MatrixTester.mm
- (void)testSimpleLag {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"开始模拟 sleep 卡顿");
        sleep(5);
        NSLog(@"卡顿结束");
    });
}

// 预期结果:
// - 检测到卡顿
// - 堆栈中包含 "sleep" 函数
// - 重复次数约 100 次 (5000ms / 50ms)
```

### 测试 2: 复杂的计算卡顿

```objc
- (void)testCPUIntensiveLag {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"开始模拟 CPU 密集型卡顿");
        
        // 执行耗时计算
        double result = 0;
        for (int i = 0; i < 100000000; i++) {
            result += sin(i) * cos(i);
        }
        
        NSLog(@"计算结果: %f", result);
    });
}

// 预期结果:
// - 检测到卡顿
// - 堆栈中包含这个循环
// - 可以看到 CPU 使用率很高
```

### 测试 3: 死锁卡顿

```objc
- (void)testDeadlockLag {
    NSLock *lock1 = [[NSLock alloc] init];
    NSLock *lock2 = [[NSLock alloc] init];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [lock1 lock];
        sleep(1);
        [lock2 lock];  // 如果另一个线程持有 lock2，会死锁
        // ...
    });
}

// 预期结果:
// - 检测到卡顿
// - 堆栈中包含 lock 相关调用
```

---

## 📈 性能影响分析

### CPU 开销

```
正常情况（无卡顿）:
├── Runloop 回调: < 0.01% CPU
└── 检测线程: < 0.1% CPU
    └── 睡眠大部分时间

卡顿期间:
├── Runloop 回调: 0% (主线程卡死)
└── 检测线程: 1-2% CPU
    ├── 堆栈采样: 每次约 0.1ms
    └── 每秒采样 20 次 = 2ms/s
```

### 内存开销

```
每个堆栈:
├── 地址数组: 100 × 8 字节 = 800 字节
└── 元数据: ~200 字节
总计: ~1 KB

假设卡顿 5 秒:
├── 采样次数: 5000ms / 50ms = 100 次
├── 不同堆栈数: 通常 < 10 个
└── 内存占用: 10 × 1KB = 10 KB

结论: 内存开销可忽略不计
```

---

## 🔧 故障排查

### 问题 1: 没有检测到卡顿

**可能原因**:
1. 阈值设置太高 (`g_RunLoopTimeOut`)
2. 卡顿发生在非主线程
3. 监控未启动

**排查步骤**:
```objc
// 检查监控是否启动
NSLog(@"监控状态: %@", 
      [WCBlockMonitorMgr shareInstance].isRunning ? @"运行中" : @"已停止");

// 检查配置
NSLog(@"卡顿阈值: %u ms", g_RunLoopTimeOut / 1000);

// 检查 Runloop 观察者是否添加成功
CFRunLoopRef mainRunloop = CFRunLoopGetMain();
// ...
```

### 问题 2: 堆栈不准确

**可能原因**:
1. 采样频率太低
2. 堆栈过滤太激进
3. 二进制文件没有调试符号

**解决方法**:
```objc
// 增加采样频率
blockMonitorConfig.perStackInterval = 25000;  // 改为 25ms

// 关闭堆栈过滤（调试时）
blockMonitorConfig.bFilterSameStack = NO;

// 检查编译设置
// Build Settings → Debug Information Format = DWARF with dSYM File
```

### 问题 3: 报告文件找不到

**查找报告文件**:
```objc
// 报告文件路径
NSString *cachePath = NSSearchPathForDirectoriesInDomains(
    NSCachesDirectory, NSUserDomainMask, YES).firstObject;
NSString *reportPath = [cachePath stringByAppendingPathComponent:
    @"Matrix/CrashBlock"];

NSLog(@"报告目录: %@", reportPath);

// 列出所有报告
NSArray *reports = [[NSFileManager defaultManager] 
    contentsOfDirectoryAtPath:reportPath error:nil];
NSLog(@"报告文件: %@", reports);
```

---

## 📚 延伸阅读

### 推荐阅读顺序

1. **Runloop 基础**
   - Apple 官方文档: "Run Loops"
   - 理解 Runloop 的各个阶段

2. **线程与并发**
   - `pthread` 和 `thread_get_state` API
   - 如何获取线程堆栈

3. **符号化技术**
   - `dwarfdump` 工具
   - `atos` 符号化原理

4. **崩溃报告格式**
   - KSCrash 文档
   - Apple Crash Report 格式

---

## 🎓 练习题

### 练习 1: 修改采样频率

**任务**: 将采样频率改为 100ms，观察对检测精度的影响

**提示**: 修改 `WCBlockMonitorConfiguration.perStackInterval`

### 练习 2: 添加卡顿级别

**任务**: 区分轻度卡顿（1-3秒）和重度卡顿（>3秒）

**提示**: 在 `EDumpType` 中添加新类型

### 练习 3: 实现卡顿预警

**任务**: 当主线程耗时接近阈值时（如 80%），发出预警

**提示**: 在 `check` 方法中添加判断

---

**文档版本**: v1.0  
**适用项目**: MatrixTestApp  
**最后更新**: 2025-01-10

