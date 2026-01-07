//
//  WCAsyncStackTraceManager.h
//  Matrix
//
//  异步堆栈回溯管理器
//  参考: https://github.com/Tencent/matrix/wiki/Matrix-for-iOS-macOS-异步堆栈回溯
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 异步堆栈追溯管理器
 * 
 * 核心功能：
 * 1. Hook dispatch 异步函数（dispatch_async、dispatch_after、dispatch_barrier_async）
 * 2. 记录发起异步任务时的线程堆栈
 * 3. 将堆栈与异步线程 ID 关联存储
 * 4. 提供查询接口，获取异步线程的发起堆栈
 * 
 * 使用场景：
 * - 解决多层嵌套异步调用链断裂问题
 * - 追溯异步任务的完整调用路径
 * 
 * 线程安全：
 * - 使用 pthread_mutex 保护全局字典访问
 * 
 * 内存管理：
 * - 定期清理过期的堆栈记录（避免内存泄漏）
 */
@interface WCAsyncStackTraceManager : NSObject

/**
 * 获取单例实例
 */
+ (instancetype)sharedInstance;

/**
 * 启用异步堆栈追溯
 * 
 * @discussion 调用此方法后，将 hook dispatch 异步函数并开始记录堆栈
 * @warning 建议在 App 启动早期调用，确保 hook 生效
 * @return YES: 启用成功, NO: 启用失败（可能已经启用或 fishhook 失败）
 */
- (BOOL)enableAsyncStackTrace;

/**
 * 禁用异步堆栈追溯
 * 
 * @discussion 停止记录新的异步堆栈，但不会清理已存储的堆栈
 */
- (void)disableAsyncStackTrace;

/**
 * 获取异步线程的发起堆栈
 * 
 * @param thread 异步线程的 mach thread ID
 * @return 发起该异步线程时的堆栈地址数组，如果没有记录则返回 nil
 * 
 * @discussion
 * 返回的数组包含发起异步任务时的堆栈帧地址（NSNumber 封装的 uintptr_t）
 * 可以与当前线程的堆栈组合，形成完整的调用链
 */
- (nullable NSArray<NSNumber *> *)getOriginStackForThread:(thread_t)thread;

/**
 * 清理过期的堆栈记录
 * 
 * @discussion 移除所有已不存在的线程的堆栈记录，释放内存
 */
- (void)cleanupExpiredStacks;

/**
 * 获取当前存储的堆栈记录数量（用于调试）
 */
- (NSUInteger)getStackRecordCount;

/**
 * 检查是否已启用
 */
- (BOOL)isEnabled;

@end

NS_ASSUME_NONNULL_END

