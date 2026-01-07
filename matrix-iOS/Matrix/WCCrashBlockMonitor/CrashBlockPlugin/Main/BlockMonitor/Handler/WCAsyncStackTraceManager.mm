//
//  WCAsyncStackTraceManager.mm
//  Matrix
//
//  异步堆栈回溯管理器实现
//

#import "WCAsyncStackTraceManager.h"
#import <pthread.h>
#import <execinfo.h>
#import <dlfcn.h>

// 🆕 引入完整的 fishhook
#import "fishhook.h"

// ============================================================================
#pragma mark - 全局变量
// ============================================================================

/**
 * 异步堆栈存储池
 * Key: 异步线程 ID (NSNumber)
 * Value: 发起线程的堆栈 (NSArray<NSNumber *>)
 */
static NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *g_asyncOriginThreadDict = nil;

/**
 * 线程锁，保护 g_asyncOriginThreadDict 的并发访问
 */
static pthread_mutex_t g_asyncStackMutex = PTHREAD_MUTEX_INITIALIZER;

/**
 * 是否已启用异步堆栈追溯
 */
static BOOL g_asyncStackTraceEnabled = NO;

/**
 * 最大堆栈深度
 */
static const int kMaxAsyncStackDepth = 50;

// ============================================================================
#pragma mark - 原始函数指针
// ============================================================================

/**
 * 保存原始的 dispatch 函数指针
 * hook 后需要调用这些原始函数
 */
static void (*orig_dispatch_async)(dispatch_queue_t queue, dispatch_block_t block);
static void (*orig_dispatch_after)(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);
static void (*orig_dispatch_barrier_async)(dispatch_queue_t queue, dispatch_block_t block);

// dispatch_*_f 函数（function 类型）
static void (*orig_dispatch_async_f)(dispatch_queue_t queue, void *context, dispatch_function_t work);
static void (*orig_dispatch_after_f)(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work);
static void (*orig_dispatch_barrier_async_f)(dispatch_queue_t queue, void *context, dispatch_function_t work);

// ============================================================================
#pragma mark - 辅助函数
// ============================================================================

/**
 * 获取当前线程的堆栈
 * 
 * 技术说明：
 * - 使用 POSIX 标准的 backtrace() 函数
 * - backtrace() 专门用于获取**当前线程**的堆栈，无需挂起线程
 * - 与 kssc_backtraceCurrentThread() 的区别：
 *   · backtrace():                获取当前线程堆栈，用户态调用，~0.1ms
 *   · kssc_backtraceCurrentThread(): 获取其他线程堆栈，需要挂起线程，~1-2ms
 * - 在 hook 函数中，我们获取的是**发起线程自己的堆栈**，backtrace() 是最优选择
 * 
 * @param stackBuffer 堆栈地址缓冲区
 * @param maxDepth 最大堆栈深度
 * @return 实际获取的堆栈帧数量
 */
static int getCurrentThreadStack(uintptr_t *stackBuffer, int maxDepth) {
    void **buffer = (void **)malloc(maxDepth * sizeof(void *));
    int count = backtrace(buffer, maxDepth);
    
    for (int i = 0; i < count; i++) {
        stackBuffer[i] = (uintptr_t)buffer[i];
    }
    
    free(buffer);
    return count;
}

/**
 * 将堆栈地址数组转换为 NSArray
 * 
 * @param stack 堆栈地址数组
 * @param count 堆栈帧数量
 * @return NSArray<NSNumber *> 包装后的堆栈数组
 */
static NSArray<NSNumber *> *stackToArray(uintptr_t *stack, int count) {
    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:count];
    for (int i = 0; i < count; i++) {
        [array addObject:@(stack[i])];
    }
    return [array copy];
}

/**
 * 保存异步堆栈到全局字典
 * 
 * @param threadID 异步线程 ID
 * @param stack 发起线程的堆栈
 */
static void saveAsyncStack(thread_t threadID, NSArray<NSNumber *> *stack) {
    pthread_mutex_lock(&g_asyncStackMutex);
    if (g_asyncOriginThreadDict && stack) {
        [g_asyncOriginThreadDict setObject:stack forKey:@(threadID)];
    }
    pthread_mutex_unlock(&g_asyncStackMutex);
}

/**
 * 获取当前 mach thread ID
 */
static thread_t getCurrentThreadID(void) {
    return pthread_mach_thread_np(pthread_self());
}

// ============================================================================
#pragma mark - Hook 包装函数
// ============================================================================

/**
 * 创建带异步堆栈记录的 block
 * 
 * @param originalBlock 原始 block
 * @return 包装后的 block（会在执行前记录堆栈关联）
 */
static dispatch_block_t wrapBlockWithAsyncTrace(dispatch_block_t originalBlock) {
    if (!g_asyncStackTraceEnabled || !originalBlock) {
        return originalBlock;
    }
    
    // 1. 获取发起线程的堆栈（当前线程）
    uintptr_t stackBuffer[kMaxAsyncStackDepth];
    int stackCount = getCurrentThreadStack(stackBuffer, kMaxAsyncStackDepth);
    NSArray<NSNumber *> *originStack = stackToArray(stackBuffer, stackCount);
    
    // 2. 创建包装 block
    dispatch_block_t wrappedBlock = ^{
        // 3. 在异步线程中，关联发起堆栈
        thread_t currentThread = getCurrentThreadID();
        saveAsyncStack(currentThread, originStack);
        
        // 4. 执行原始 block
        originalBlock();
    };
    
    return wrappedBlock;
}

/**
 * Hook 后的 dispatch_async
 */
void hooked_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_block_t wrappedBlock = wrapBlockWithAsyncTrace(block);
    orig_dispatch_async(queue, wrappedBlock);
}

/**
 * Hook 后的 dispatch_after
 */
void hooked_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_block_t wrappedBlock = wrapBlockWithAsyncTrace(block);
    orig_dispatch_after(when, queue, wrappedBlock);
}

/**
 * Hook 后的 dispatch_barrier_async
 */
void hooked_dispatch_barrier_async(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_block_t wrappedBlock = wrapBlockWithAsyncTrace(block);
    orig_dispatch_barrier_async(queue, wrappedBlock);
}

// ============================================================================
#pragma mark - dispatch_*_f 函数的 Hook（function 类型）
// ============================================================================

/**
 * 包装上下文结构体
 * 用于 dispatch_*_f 函数传递原始上下文和堆栈
 */
typedef struct {
    void *originalContext;              // 原始上下文
    dispatch_function_t originalWork;   // 原始工作函数
    void *originStack;                  // 发起堆栈（用 CFBridgingRetain 持有，实际是 CFTypeRef）
} AsyncFunctionContext;

/**
 * 包装后的工作函数
 */
static void wrappedWorkFunction(void *context) {
    AsyncFunctionContext *wrapperContext = (AsyncFunctionContext *)context;
    
    // 1. 关联异步堆栈
    thread_t currentThread = getCurrentThreadID();
    NSArray *originStack = (__bridge_transfer NSArray *)wrapperContext->originStack;
    saveAsyncStack(currentThread, originStack);
    
    // 2. 执行原始工作函数
    if (wrapperContext->originalWork) {
        wrapperContext->originalWork(wrapperContext->originalContext);
    }
    
    // 3. 释放包装上下文
    free(wrapperContext);
}

/**
 * Hook 后的 dispatch_async_f
 */
void hooked_dispatch_async_f(dispatch_queue_t queue, void *context, dispatch_function_t work) {
    if (!g_asyncStackTraceEnabled || !work) {
        orig_dispatch_async_f(queue, context, work);
        return;
    }
    
    // 获取发起堆栈
    uintptr_t stackBuffer[kMaxAsyncStackDepth];
    int stackCount = getCurrentThreadStack(stackBuffer, kMaxAsyncStackDepth);
    NSArray<NSNumber *> *originStack = stackToArray(stackBuffer, stackCount);
    
    // 创建包装上下文
    AsyncFunctionContext *wrapperContext = (AsyncFunctionContext *)malloc(sizeof(AsyncFunctionContext));
    wrapperContext->originalContext = context;
    wrapperContext->originalWork = work;
    wrapperContext->originStack = (void *)CFBridgingRetain(originStack);
    
    // 调用原始函数，传入包装后的函数和上下文
    orig_dispatch_async_f(queue, wrapperContext, wrappedWorkFunction);
}

/**
 * Hook 后的 dispatch_after_f
 */
void hooked_dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work) {
    if (!g_asyncStackTraceEnabled || !work) {
        orig_dispatch_after_f(when, queue, context, work);
        return;
    }
    
    uintptr_t stackBuffer[kMaxAsyncStackDepth];
    int stackCount = getCurrentThreadStack(stackBuffer, kMaxAsyncStackDepth);
    NSArray<NSNumber *> *originStack = stackToArray(stackBuffer, stackCount);
    
    AsyncFunctionContext *wrapperContext = (AsyncFunctionContext *)malloc(sizeof(AsyncFunctionContext));
    wrapperContext->originalContext = context;
    wrapperContext->originalWork = work;
    wrapperContext->originStack = (void *)CFBridgingRetain(originStack);
    
    orig_dispatch_after_f(when, queue, wrapperContext, wrappedWorkFunction);
}

/**
 * Hook 后的 dispatch_barrier_async_f
 */
void hooked_dispatch_barrier_async_f(dispatch_queue_t queue, void *context, dispatch_function_t work) {
    if (!g_asyncStackTraceEnabled || !work) {
        orig_dispatch_barrier_async_f(queue, context, work);
        return;
    }
    
    uintptr_t stackBuffer[kMaxAsyncStackDepth];
    int stackCount = getCurrentThreadStack(stackBuffer, kMaxAsyncStackDepth);
    NSArray<NSNumber *> *originStack = stackToArray(stackBuffer, stackCount);
    
    AsyncFunctionContext *wrapperContext = (AsyncFunctionContext *)malloc(sizeof(AsyncFunctionContext));
    wrapperContext->originalContext = context;
    wrapperContext->originalWork = work;
    wrapperContext->originStack = (void *)CFBridgingRetain(originStack);
    
    orig_dispatch_barrier_async_f(queue, wrapperContext, wrappedWorkFunction);
}

// ============================================================================
#pragma mark - WCAsyncStackTraceManager 实现
// ============================================================================

@implementation WCAsyncStackTraceManager

+ (instancetype)sharedInstance {
    static WCAsyncStackTraceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WCAsyncStackTraceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化全局字典
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            g_asyncOriginThreadDict = [[NSMutableDictionary alloc] init];
        });
    }
    return self;
}

- (BOOL)enableAsyncStackTrace {
    if (g_asyncStackTraceEnabled) {
        NSLog(@"[AsyncTrace] 异步堆栈追溯已启用");
        return NO;
    }
    
    NSLog(@"[AsyncTrace] 开始启用异步堆栈追溯...");
    
    // Hook dispatch 函数
    struct rebinding rebindings[] = {
        // Block 类型
        {"dispatch_async", (void *)hooked_dispatch_async, (void **)&orig_dispatch_async},
        {"dispatch_after", (void *)hooked_dispatch_after, (void **)&orig_dispatch_after},
        {"dispatch_barrier_async", (void *)hooked_dispatch_barrier_async, (void **)&orig_dispatch_barrier_async},
        
        // Function 类型
        {"dispatch_async_f", (void *)hooked_dispatch_async_f, (void **)&orig_dispatch_async_f},
        {"dispatch_after_f", (void *)hooked_dispatch_after_f, (void **)&orig_dispatch_after_f},
        {"dispatch_barrier_async_f", (void *)hooked_dispatch_barrier_async_f, (void **)&orig_dispatch_barrier_async_f},
    };
    
    int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding));
    
    if (result == 0) {
        g_asyncStackTraceEnabled = YES;
        NSLog(@"[AsyncTrace] ✅ 异步堆栈追溯启用成功");
        return YES;
    } else {
        NSLog(@"[AsyncTrace] ❌ 异步堆栈追溯启用失败: fishhook error %d", result);
        return NO;
    }
}

- (void)disableAsyncStackTrace {
    g_asyncStackTraceEnabled = NO;
    NSLog(@"[AsyncTrace] 异步堆栈追溯已禁用");
}

- (nullable NSArray<NSNumber *> *)getOriginStackForThread:(thread_t)thread {
    NSArray<NSNumber *> *stack = nil;
    pthread_mutex_lock(&g_asyncStackMutex);
    stack = [g_asyncOriginThreadDict objectForKey:@(thread)];
    pthread_mutex_unlock(&g_asyncStackMutex);
    return stack;
}

- (void)cleanupExpiredStacks {
    pthread_mutex_lock(&g_asyncStackMutex);
    
    NSMutableArray *expiredThreads = [[NSMutableArray alloc] init];
    
    // 遍历所有记录的线程
    for (NSNumber *threadID in g_asyncOriginThreadDict) {
        thread_t thread = (thread_t)[threadID unsignedIntValue];
        
        // 检查线程是否还存在
        kern_return_t kr;
        thread_basic_info_data_t info;
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        
        kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
        
        // 如果线程已不存在，标记为过期
        if (kr != KERN_SUCCESS) {
            [expiredThreads addObject:threadID];
        }
    }
    
    // 移除过期线程的堆栈记录
    for (NSNumber *threadID in expiredThreads) {
        [g_asyncOriginThreadDict removeObjectForKey:threadID];
    }
    
    pthread_mutex_unlock(&g_asyncStackMutex);
    
    if (expiredThreads.count > 0) {
        NSLog(@"[AsyncTrace] 清理了 %lu 个过期堆栈记录", (unsigned long)expiredThreads.count);
    }
}

- (NSUInteger)getStackRecordCount {
    pthread_mutex_lock(&g_asyncStackMutex);
    NSUInteger count = g_asyncOriginThreadDict.count;
    pthread_mutex_unlock(&g_asyncStackMutex);
    return count;
}

- (BOOL)isEnabled {
    return g_asyncStackTraceEnabled;
}

@end

