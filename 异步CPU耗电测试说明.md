# 异步CPU耗电测试案例说明

## 📋 文件清单

已创建以下测试文件：

1. **TestAsyncCPUViewController.h** - 头文件
2. **TestAsyncCPUViewController.mm** - 实现文件

## 🔧 集成步骤

### 1. 将文件添加到Xcode项目

```bash
# 方法1：手动添加
1. 在Xcode中右键点击 MatrixTestApp 文件夹
2. 选择 "Add Files to MatrixTestApp..."
3. 选择以下文件：
   - TestAsyncCPUViewController.h
   - TestAsyncCPUViewController.mm
4. 确保勾选 "Copy items if needed"
5. Target选择 "MatrixTestApp"

# 方法2：使用命令行（已自动修改ViewController.mm）
# 只需在Xcode中添加文件引用即可
```

### 2. 验证集成

打开 `ViewController.mm`，应该已经包含：
```objc
#import "TestAsyncCPUViewController.h"

// 在setupView中添加了按钮
_asyncCPUViewBtn = [Utility genBigGreenButtonWithFrame:...];
[_asyncCPUViewBtn setTitle:@"Async CPU Test" forState:UIControlStateNormal];

// 添加了跳转方法
- (void)enterAsyncCPUView {
    TestAsyncCPUViewController *vc = [[TestAsyncCPUViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}
```

## 🎯 测试场景说明

### 场景1：单层异步CPU密集任务

**调用链：**
```
[ViewController testScenario1]  ← 发起者（希望在堆栈中看到）
  └─> dispatch_async(global_queue)
      └─> performHeavyImageProcessing  ← 执行者（当前只能看到这里）
          └─> vImageConvolve_ARGB8888 (Accelerate框架)
```

**预期行为：**
- 持续90秒执行图像卷积操作
- CPU使用率：80-95%
- 60秒后触发Matrix耗电监控上报

**当前堆栈（无异步追溯）：**
```
Thread #5 (CPU 85%)
#0  0x1a2b3c4d5  vImageConvolve_ARGB8888
#1  0x100123456  -[TestAsyncCPUViewController performHeavyImageProcessingWithDuration:taskName:]
#2  0x100234567  __31-[TestAsyncCPUViewController testScenario1]_block_invoke
#3  0x1a3b4c5d6  _dispatch_call_block_and_release
#4  0x1a3b4c5e7  _dispatch_client_callout
```

**理想堆栈（有异步追溯）：**
```
Thread #5 (CPU 85%)
#0  0x1a2b3c4d5  vImageConvolve_ARGB8888
#1  0x100123456  -[TestAsyncCPUViewController performHeavyImageProcessingWithDuration:taskName:]
#2  0x100234567  __31-[TestAsyncCPUViewController testScenario1]_block_invoke
--- 异步分界线 ---
#3  0x100345678  -[TestAsyncCPUViewController testScenario1]  ← 发起者
#4  0x100456789  -[UIButton sendAction:to:forEvent:]
#5  0x100567890  -[UIControl _sendActionsForEvents:withEvent:]
```

### 场景2：多层嵌套异步任务

**调用链：**
```
[ViewController testScenario2]
  └─> dispatch_async (第一层)
      └─> processDataInBackground
          └─> dispatch_async (第二层)
              └─> performHeavyCalculation
```

**预期行为：**
- 第一层异步：延迟2秒
- 第二层异步：持续90秒执行数学计算
- CPU使用率：85-95%

**当前堆栈（只能看到最内层）：**
```
Thread #6 (CPU 90%)
#0  0x1a2b3c4d5  _platform_memmove
#1  0x100123456  -[TestAsyncCPUViewController performHeavyCalculationWithDuration:taskName:]
#2  0x100234567  __54-[TestAsyncCPUViewController processDataInBackground]_block_invoke
```

**理想堆栈（能看到完整调用链）：**
```
Thread #6 (CPU 90%)
#0  0x1a2b3c4d5  _platform_memmove
#1  0x100123456  -[TestAsyncCPUViewController performHeavyCalculationWithDuration:taskName:]
#2  0x100234567  __54-[TestAsyncCPUViewController processDataInBackground]_block_invoke
--- 异步分界线 ---
#3  0x100345678  -[TestAsyncCPUViewController processDataInBackground]
#4  0x100456789  __31-[TestAsyncCPUViewController testScenario2]_block_invoke
--- 异步分界线 ---
#5  0x100567890  -[TestAsyncCPUViewController testScenario2]
```

### 场景3：多个并发异步任务

**调用链：**
```
[ViewController testScenario3]
  ├─> dispatch_async -> simulateNetworkServiceSyncData (CPU 30%)
  ├─> dispatch_async -> simulateImageServiceProcessing (CPU 35%)
  └─> dispatch_async -> simulateDataServiceAnalysis (CPU 40%)
```

**预期行为：**
- 3个线程同时执行
- 总CPU使用率：105%（多核累加）
- 模拟真实业务场景：多个服务并发

**当前堆栈（3个独立线程，看不到共同发起者）：**
```
Thread #7 (CPU 30%)
#0  performHeavyCalculation
#1  simulateNetworkServiceSyncData

Thread #8 (CPU 35%)
#0  vImageConvolve_ARGB8888
#1  simulateImageServiceProcessing

Thread #9 (CPU 40%)
#0  cblas_sgemm
#1  simulateDataServiceAnalysis
```

**理想堆栈（能追溯到共同发起者）：**
```
Thread #7 (CPU 30%)
#0  performHeavyCalculation
#1  simulateNetworkServiceSyncData
--- 异步分界线 ---
#2  testScenario3  ← 共同发起者

Thread #8 (CPU 35%)
#0  vImageConvolve_ARGB8888
#1  simulateImageServiceProcessing
--- 异步分界线 ---
#2  testScenario3  ← 共同发起者

Thread #9 (CPU 40%)
#0  cblas_sgemm
#1  simulateDataServiceAnalysis
--- 异步分界线 ---
#2  testScenario3  ← 共同发起者
```

## 🧪 使用方法

### 1. 启动App

```bash
# 确保Matrix已启动
# 在AppDelegate中已配置耗电监控
```

### 2. 进入测试页面

```
主页 -> 点击 "Async CPU Test" 按钮
```

### 3. 执行测试

```
1. 点击 "场景1: 单层异步CPU密集任务"
2. 等待60秒
3. 查看Xcode控制台日志
4. 查看Matrix上报的耗电堆栈
```

### 4. 查看结果

**控制台日志：**
```
[AsyncCPU] 场景1开始: 主线程=<_NSMainThread: 0x...>
[AsyncCPU] 场景1异步线程开始: <NSThread: 0x...>{number = 5}
[AsyncCPU] 场景1-图像处理 开始 (预计运行90秒)
[AsyncCPU] 场景1-图像处理 已执行1000次卷积 (1.2秒)
...
[Matrix] CPU过高检测: 85.3%
[Matrix] 开始采集堆栈...
```

**Matrix上报（当前实现）：**
```json
{
  "issue_type": "power_consume",
  "cpu_usage": 85.3,
  "duration": 60,
  "stack_tree": [
    {
      "address": "0x1a2b3c4d5",
      "symbol": "vImageConvolve_ARGB8888",
      "repeat_count": 45,
      "children": [
        {
          "address": "0x100123456",
          "symbol": "-[TestAsyncCPUViewController performHeavyImageProcessingWithDuration:taskName:]",
          "repeat_count": 45
        }
      ]
    }
  ]
}
```

## 📊 对比分析

### 当前实现的限制

| 问题 | 描述 | 影响 |
|------|------|------|
| **无法定位发起者** | 只能看到异步线程内部的堆栈 | 无法知道是哪个ViewController或Service发起的 |
| **多层异步丢失** | 嵌套异步调用只能看到最内层 | 无法理解完整的调用链 |
| **并发场景混乱** | 多个异步任务看起来毫无关联 | 无法发现是同一个操作触发的 |

### Wiki理想实现的优势

| 优势 | 描述 | 价值 |
|------|------|------|
| **完整调用链** | 能追溯到最初的发起者 | 快速定位问题代码位置 |
| **异步分界线** | 清晰标记异步边界 | 理解代码执行流程 |
| **关联分析** | 发现多个异步任务的共同发起者 | 优化整体架构 |

## 🔍 验证要点

### 1. 确认CPU过高

```bash
# 使用Xcode Instruments - CPU Profiler
# 或者查看Activity Monitor
# 应该看到MatrixTestApp的CPU在80%以上
```

### 2. 确认Matrix触发

```bash
# 查看控制台日志
grep "Matrix" ~/Library/Logs/...
# 或者查看上报服务器
```

### 3. 分析堆栈差异

```
当前堆栈：只有2-3层，都是异步线程内部
理想堆栈：5-7层，包含发起者信息
```

## 💡 实现建议

如果要实现Wiki中的异步堆栈追溯，需要：

### 1. 使用fishhook

```objc
#import <fishhook/fishhook.h>

// Hook dispatch_async
static void (*orig_dispatch_async)(dispatch_queue_t queue, dispatch_block_t block);

void my_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    // 1. 获取当前线程堆栈
    uintptr_t stack[50];
    int count = backtrace((void**)stack, 50);
    
    // 2. 包装block
    dispatch_block_t wrapped_block = ^{
        // 保存堆栈到asyncOriginThreadDict
        [asyncDict setObject:stackArray forKey:@(pthread_mach_thread_np(pthread_self()))];
        
        // 执行原始block
        block();
    };
    
    // 3. 调用原始函数
    orig_dispatch_async(queue, wrapped_block);
}

// 在初始化时hook
rebind_symbols((struct rebinding[1]){{"dispatch_async", my_dispatch_async, (void*)&orig_dispatch_async}}, 1);
```

### 2. 存储异步堆栈

```objc
// 全局字典
static NSMutableDictionary *asyncOriginThreadDict;

// 存储格式
// Key: 异步线程ID (NSNumber)
// Value: 发起线程的堆栈 (NSArray<NSNumber*>)
```

### 3. 合并堆栈

```objc
// 在采集堆栈时
- (NSArray*)getCompleteStack:(thread_t)thread {
    // 1. 获取当前线程堆栈
    uintptr_t currentStack[100];
    int currentCount = backtrace_thread(thread, currentStack, 100);
    
    // 2. 查找发起者堆栈
    NSArray *originStack = asyncOriginThreadDict[@(thread)];
    
    // 3. 合并
    if (originStack) {
        return [currentStack + @"--- async ---" + originStack];
    }
    return currentStack;
}
```

## 📝 注意事项

1. **iOS 13+ 兼容性**
   - 需要处理 `__DATA_CONST` 段的只读问题
   - fishhook需要使用最新版本

2. **性能影响**
   - Hook dispatch会有轻微性能开销
   - 建议只在Debug模式或特定场景开启

3. **内存管理**
   - asyncOriginThreadDict需要定期清理
   - 避免内存泄漏

4. **线程安全**
   - 使用pthread_mutex保护全局字典
   - 注意死锁风险

## 🎓 学习价值

通过这个测试案例，您可以：

1. **理解异步堆栈的重要性** - 看到当前实现的局限性
2. **对比两种实现方式** - 直接backtrace vs 异步追溯
3. **学习fishhook技术** - 如何hook系统函数
4. **优化性能监控** - 提升问题定位效率

## 📚 参考资料

- [Matrix Wiki - 异步堆栈回溯](https://github.com/Tencent/matrix/wiki/Matrix-for-iOS-macOS-%E5%BC%82%E6%AD%A5%E5%A0%86%E6%A0%88%E5%9B%9E%E6%BA%AF)
- [fishhook GitHub](https://github.com/facebook/fishhook)
- [Apple - Queue Debugging](https://developer.apple.com/documentation/xcode/queue-debugging)

---

**创建时间**: 2026-01-02
**作者**: AI Assistant
**版本**: 1.0

