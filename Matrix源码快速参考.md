# Matrix 卡顿检测源码快速参考

> 快速查找关键代码位置和API用法

---

## 📑 核心文件速查表

| 文件路径 | 核心功能 | 关键方法 | 行数范围 |
|---------|---------|---------|---------|
| **WCBlockMonitorMgr.mm** | 卡顿监控主管理器 | `threadProc`, `check` | 568-744 |
| **WCBlockMonitorMgr.mm** | Runloop 监听 | `myRunLoopBeginCallback` | 987-1076 |
| **WCMainThreadHandler.mm** | 主线程堆栈处理 | `addThreadStack` | - |
| **WCGetMainThreadUtil.mm** | 获取主线程堆栈 | `getCurrentMainThreadStack` | - |
| **WCDumpInterface.mm** | 生成卡顿报告 | `dumpReportWithReportType` | 26-61 |
| **WCCrashBlockMonitor.mm** | 插件主类 | `enableBlockMonitor` | 99-109 |
| **MatrixHandler.mm** | 应用层集成 | `installMatrix` | 52-91 |

---

## 🎯 关键 API 速查

### 1. 初始化 Matrix

```objc
// MatrixHandler.mm
- (void)installMatrix {
    // 1. 创建配置
    WCCrashBlockMonitorConfig *config = [[WCCrashBlockMonitorConfig alloc] init];
    config.enableBlockMonitor = YES;
    
    WCBlockMonitorConfiguration *blockConfig = [WCBlockMonitorConfiguration defaultConfig];
    blockConfig.bMainThreadHandle = YES;        // 启用主线程监控
    blockConfig.runloopTimeOut = 3000000;       // 3秒阈值
    
    // 2. 创建插件
    WCCrashBlockMonitorPlugin *plugin = [[WCCrashBlockMonitorPlugin alloc] init];
    plugin.pluginConfig = config;
    
    // 3. 启动
    [plugin start];
}
```

### 2. 自定义卡顿阈值

```objc
// 动态修改阈值
[[WCBlockMonitorMgr shareInstance] setRunloopThreshold:5000000];  // 改为 5 秒

// 降低阈值（更敏感）
[[WCBlockMonitorMgr shareInstance] lowerRunloopThreshold];

// 恢复默认阈值
[[WCBlockMonitorMgr shareInstance] recoverRunloopThreshold];
```

### 3. 手动触发报告生成

```objc
// 生成实时报告
[[WCBlockMonitorMgr shareInstance] 
    generateLiveReportWithDumpType:EDumpType_LaunchBlock
                        withReason:@"手动触发"
                  selfDefinedPath:NO];
```

### 4. 获取报告回调

```objc
// 实现 WCBlockMonitorDelegate
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr 
           getDumpFile:(NSString *)dumpFile 
          withDumpType:(EDumpType)dumpType {
    NSLog(@"生成报告: %@", dumpFile);
    
    // 读取报告内容
    NSData *data = [NSData dataWithContentsOfFile:dumpFile];
    NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data 
                                                          options:0 
                                                            error:nil];
}
```

---

## 🔧 配置参数速查

### WCBlockMonitorConfiguration

```objc
@property (nonatomic, assign) useconds_t runloopTimeOut;       
// 默认: 3000000 (3秒)
// 说明: 主线程卡顿阈值

@property (nonatomic, assign) useconds_t checkPeriodTime;      
// 默认: 1000000 (1秒)
// 说明: 检测线程每隔多久检查一次

@property (nonatomic, assign) useconds_t perStackInterval;     
// 默认: 50000 (50ms)
// 说明: 采样主线程堆栈的频率

@property (nonatomic, assign) size_t limitStackCount;          
// 默认: 100
// 说明: 每个堆栈最多记录多少个栈帧

@property (nonatomic, assign) BOOL bMainThreadHandle;          
// 默认: YES
// 说明: 是否收集主线程堆栈（必须开启）

@property (nonatomic, assign) BOOL bFilterSameStack;           
// 默认: YES
// 说明: 是否过滤重复堆栈

@property (nonatomic, assign) NSUInteger triggerToBeFilteredCount;
// 默认: 10
// 说明: 重复多少次后才过滤

@property (nonatomic, assign) BOOL bGetCPUHighLog;             
// 默认: NO
// 说明: 是否获取 CPU 占用高的堆栈

@property (nonatomic, assign) BOOL bGetPowerConsumeStack;      
// 默认: NO
// 说明: 是否获取耗电堆栈

@property (nonatomic, assign) float cpuUsagePercent;           
// 默认: 80
// 说明: CPU 使用率阈值（百分比）
```

### 常用配置组合

**生产环境（性能优先）**:
```objc
config.runloopTimeOut = 3000000;        // 3秒
config.perStackInterval = 50000;        // 50ms
config.bFilterSameStack = YES;
config.triggerToBeFilteredCount = 10;
```

**调试环境（精度优先）**:
```objc
config.runloopTimeOut = 1000000;        // 1秒（更敏感）
config.perStackInterval = 25000;        // 25ms（更频繁）
config.bFilterSameStack = NO;           // 不过滤
config.bGetCPUHighLog = YES;            // 收集 CPU 信息
```

---

## 📊 EDumpType 枚举

```objc
typedef NS_ENUM(NSUInteger, EDumpType) {
    EDumpType_Unlag = 0,                    // 无卡顿
    EDumpType_MainThreadBlock,              // 主线程卡顿 ⭐️
    EDumpType_BackgroundMainThreadBlock,    // 后台主线程卡顿
    EDumpType_CPUBlock,                     // CPU 过高
    EDumpType_CPUIntervalHigh,              // CPU 间歇性高
    EDumpType_LaunchBlock,                  // 启动卡顿
    EDumpType_BlockThreadTooMuch,           // 线程过多
    EDumpType_BlockMemoryTooLarge           // 内存过大
};
```

---

## 🔍 常用调试命令

### LLDB 断点命令

```lldb
# 1. 在检测到卡顿时中断
b WCBlockMonitorMgr.mm:720
po diff / 1000  # 查看卡顿时长（毫秒）

# 2. 在生成报告时中断
b WCDumpInterface.mm:48
po dumpFile  # 查看报告文件路径

# 3. 在 Runloop 回调时中断
b myRunLoopBeginCallback
b myRunLoopEndCallback
```

### 查看全局变量

```lldb
# 查看 Runloop 状态
p g_bRun
p g_runLoopActivity
p g_tvRun

# 查看配置参数
p g_RunLoopTimeOut
p g_CheckPeriodTime
p g_PerStackInterval

# 查看堆栈信息
p g_MainThreadCount
p g_PointMainThreadArray
```

### 手动触发卡顿报告

```lldb
# 在 LLDB 中手动生成报告
expr (void)[[WCBlockMonitorMgr shareInstance] generateLiveReportWithDumpType:1 withReason:@"手动触发" selfDefinedPath:NO]
```

---

## 📝 日志关键字搜索

### Console 日志过滤

```bash
# 只看 Matrix 相关日志
log stream --predicate 'processImagePath CONTAINS "MatrixTestApp"' --level debug

# 搜索卡顿检测日志
grep -i "runloop\|block\|lag" 

# 搜索报告生成日志
grep -i "dump\|report"
```

### 关键日志格式

```
# 启动监控
"安装卡顿监控"
"开始监控主线程"

# Runloop 监听
"添加 Runloop 观察者成功"

# 卡顿检测
"检查 RunLoop 超时阈值 3000000，bRun 1，runloop 活动 X，阻塞时间差 XXXXX"

# 生成报告
"开始生成卡顿报告"
"保存报告到: /path/to/report.json"
```

---

## 🎨 Xcode 配置速查

### Build Settings

```
Debug Information Format
├── Debug:   DWARF with dSYM File ✅
└── Release: DWARF with dSYM File ✅

Strip Debug Symbols During Copy
├── Debug:   NO ✅
└── Release: YES

Optimization Level
├── Debug:   -O0 (None) ✅
└── Release: -Os (Fastest, Smallest)
```

### 启用符号化

```bash
# 生成 dSYM 文件
xcodebuild -project MatrixTestApp.xcodeproj \
           -scheme MatrixTestApp \
           -configuration Debug \
           -derivedDataPath ./build

# 查找 dSYM 文件
find ~/Library/Developer/Xcode/DerivedData -name "*.dSYM"

# 符号化报告
python3 symbolicate_matrix_report.py report.json -o output.txt
```

---

## 🧪 测试用例模板

### 1. 简单卡顿测试

```objc
// 测试目标: 验证基本卡顿检测功能
- (void)testBasicLag {
    // 触发 5 秒卡顿
    dispatch_async(dispatch_get_main_queue(), ^{
        sleep(5);
    });
    
    // 预期: 在 3 秒时检测到卡顿
    // 预期堆栈: main -> dispatch_async -> sleep
}
```

### 2. Runloop 嵌套测试

```objc
// 测试目标: 验证嵌套 Runloop 的处理
- (void)testNestedRunloop {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 运行嵌套 Runloop
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode 
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]];
    });
    
    // 预期: 能正确检测嵌套 Runloop 中的卡顿
}
```

### 3. 多次卡顿测试

```objc
// 测试目标: 验证多次卡顿的检测
- (void)testMultipleLags {
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 10 * NSEC_PER_SEC), 
                      dispatch_get_main_queue(), ^{
            sleep(4);  // 每次卡顿 4 秒
        });
    }
    
    // 预期: 检测到 3 次独立的卡顿
}
```

---

## 🔗 相关工具和命令

### atos 符号化

```bash
# 符号化单个地址
atos -arch arm64 \
     -o MatrixTestApp.app/MatrixTestApp \
     -l 0x100000000 \
     0x10029381c

# 输出: -[MatrixTester generateMainThreadLagLog]_block_invoke (MatrixTester.mm:156)
```

### dwarfdump 查看符号

```bash
# 查看 UUID
dwarfdump --uuid MatrixTestApp.app/MatrixTestApp

# 查看符号表
dwarfdump --debug-info MatrixTestApp.app/MatrixTestApp

# 查看特定地址的符号
dwarfdump --lookup 0x10029381c MatrixTestApp.app/MatrixTestApp
```

### nm 查看符号

```bash
# 列出所有符号
nm MatrixTestApp.app/MatrixTestApp

# 查找特定符号
nm MatrixTestApp.app/MatrixTestApp | grep MatrixTester

# 只显示外部符号
nm -g MatrixTestApp.app/MatrixTestApp
```

---

## 📋 常见问题检查清单

### ✅ 功能不工作检查

- [ ] Matrix 是否已初始化？（在 `main.mm` 中调用）
- [ ] 卡顿监控是否已启动？（`enableBlockMonitor = YES`）
- [ ] 阈值是否设置合理？（默认 3 秒）
- [ ] 是否在主线程触发卡顿？（子线程卡顿检测不到）
- [ ] DerivedData 是否有最新的二进制文件？

### ✅ 符号化失败检查

- [ ] Build Settings 是否启用了调试符号？
- [ ] dSYM 文件是否存在？
- [ ] UUID 是否匹配？（报告 vs 二进制）
- [ ] 二进制文件路径是否正确？
- [ ] 是否使用了正确的架构？（arm64 vs x86_64）

### ✅ 性能问题检查

- [ ] 采样频率是否太高？（建议 50ms）
- [ ] 是否收集了太多堆栈？（建议 100 个栈帧）
- [ ] 是否启用了不必要的功能？（CPU、内存监控等）

---

## 📚 延伸阅读链接

### Apple 官方文档
- [Threading Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/Introduction/Introduction.html)
- [Run Loops](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html)
- [Technical Note TN2151: Understanding and Analyzing Application Crash Reports](https://developer.apple.com/library/archive/technotes/tn2151/_index.html)

### 相关工具
- [KSCrash GitHub](https://github.com/kstenerud/KSCrash)
- [PLCrashReporter](https://github.com/microsoft/plcrashreporter)
- [fishhook](https://github.com/facebook/fishhook)

### 推荐博客
- 微信性能监控平台 Matrix
- iOS 性能优化实践
- Runloop 深入理解

---

## 🎓 学习路径建议

### 初级（1-2 小时）
1. ✅ 阅读 "源码阅读指南" 的概述部分
2. ✅ 理解 Runloop 监听原理
3. ✅ 运行测试用例，观察日志

### 中级（3-5 小时）
1. ✅ 详细阅读 WCBlockMonitorMgr.mm
2. ✅ 理解堆栈采样和统计
3. ✅ 添加调试日志和断点
4. ✅ 修改配置参数，观察效果

### 高级（5-10 小时）
1. ✅ 阅读 KSCrash 源码
2. ✅ 理解线程堆栈获取原理
3. ✅ 实现自定义的卡顿检测
4. ✅ 优化性能和准确性

---

**最后更新**: 2025-01-10  
**版本**: v1.0  
**维护者**: Cursor AI Assistant

