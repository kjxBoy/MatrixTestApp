//
//  TestAsyncCPUViewController.h
//  MatrixTestApp
//
//  用于测试异步堆栈CPU过高的场景
//  演示Matrix耗电监控对异步任务的检测
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * TestAsyncCPUViewController - 异步CPU耗电测试
 * 
 * 测试场景：
 * 1. 主线程通过dispatch_async发起多个异步任务
 * 2. 异步任务中执行CPU密集型计算
 * 3. 触发Matrix耗电监控上报
 * 4. 对比堆栈中是否能追溯到发起者
 * 
 * 预期结果：
 * - 当前实现：只能看到异步线程的堆栈（看不到发起者）
 * - Wiki理想实现：应该能看到发起者的完整调用链
 */
@interface TestAsyncCPUViewController : UIViewController

@end

NS_ASSUME_NONNULL_END

