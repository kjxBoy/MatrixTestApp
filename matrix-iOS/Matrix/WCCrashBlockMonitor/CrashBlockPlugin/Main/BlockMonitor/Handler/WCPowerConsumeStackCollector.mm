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

#import "WCPowerConsumeStackCollector.h"
#import <mach/mach_types.h>
#import <mach/mach_init.h>
#import <mach/thread_act.h>
#import <mach/task.h>
#import <mach/mach_port.h>
#import <mach/vm_map.h>
#import "KSStackCursor_SelfThread.h"
#import "KSThread.h"
#import "MatrixLogDef.h"
#import "KSMachineContext.h"
#import <pthread.h>
#import <os/lock.h>
#import <execinfo.h>
#import "WCMatrixModel.h"
// 🆕 引入异步堆栈追溯管理器
#import "WCAsyncStackTraceManager.h"

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

/**
 * 堆栈信息结构体
 * 用于从getStackInfoWithThreadCount方法返回堆栈矩阵
 */
struct StackInfo {
    uintptr_t **stack_matrix;       // 堆栈地址矩阵（二维数组）
    int *trace_length_matrix;       // 每个堆栈的长度数组
};

// ============================================================================
#pragma mark - 常量定义
// ============================================================================

/**
 * 调用树中子节点的键名
 */
#define CHILE_FRAME "child"

/**
 * 堆栈池最大容量
 * 最多保存100个堆栈样本用于生成调用树
 */
#define MAX_STACK_TRACE_COUNT 100

/**
 * 浮点数比较阈值
 * 用于判断浮点数是否接近0或相等
 */
#define FLOAT_THRESHOLD 0.000001

/**
 * 日志中记录的最大堆栈深度
 * 限制为50层，避免堆栈过深导致处理缓慢
 */
#define MAX_STACK_TRACE_IN_LOG 50

// ============================================================================
#pragma mark - WCStackTracePool（堆栈追踪池）
// ============================================================================

/**
 * WCStackTracePool 类扩展
 * 
 * 内部数据结构：
 * - 使用循环数组存储堆栈
 * - 每个堆栈关联CPU使用率和前后台状态
 * - 达到最大容量时，新堆栈覆盖最旧的
 */
@interface WCStackTracePool () {
    /**
     * 堆栈地址循环数组
     * 每个元素是一个uintptr_t*（堆栈地址数组）
     */
    uintptr_t **m_stackCyclePool;
    
    /**
     * 堆栈深度数组
     * 记录每个堆栈包含多少个地址
     */
    size_t *m_stackCount;
    
    /**
     * CPU使用率数组
     * 记录采集该堆栈时线程的CPU使用率
     */
    float *m_stackCPU;
    
    /**
     * 前后台状态数组
     * 记录该堆栈是否在后台采集
     */
    BOOL *m_stackInBackground;
    
    /**
     * 循环数组尾指针
     * 指向下一个要写入的位置
     * 达到最大值时回绕到0
     */
    uint64_t m_poolTailPoint;
    
    /**
     * 堆栈池最大容量
     */
    size_t m_maxStackCount;
}

/**
 * 父级地址帧数组（用于生成调用树）
 * 存储调用树的根节点
 */
@property (nonatomic, strong) NSMutableArray<WCAddressFrame *> *parentAddressFrame;

@end

@implementation WCStackTracePool

// ============================================================================
#pragma mark - 初始化和清理
// ============================================================================

/**
 * 默认初始化
 * 使用默认容量10
 */
- (id)init {
    return [self initWithMaxStackTraceCount:10];
}

/**
 * 指定最大堆栈数量初始化
 * 
 * @param maxStackTraceCount 堆栈池最大容量
 * @return WCStackTracePool实例
 * 
 * 实现：
 * 1. 分配4个数组：堆栈地址、长度、CPU、前后台状态
 * 2. 使用malloc分配内存，初始化为0
 * 3. 循环数组实现，达到最大容量时覆盖最旧的
 */
- (id)initWithMaxStackTraceCount:(NSUInteger)maxStackTraceCount {
    self = [super init];
    if (self) {
        m_maxStackCount = (size_t)maxStackTraceCount;

        // 分配堆栈地址数组（指针数组）
        size_t cycleArrayBytes = m_maxStackCount * sizeof(uintptr_t *);
        m_stackCyclePool = (uintptr_t **)malloc(cycleArrayBytes);
        if (m_stackCyclePool != NULL) {
            memset(m_stackCyclePool, 0, cycleArrayBytes);
        }
        
        // 分配堆栈长度数组
        size_t countArrayBytes = m_maxStackCount * sizeof(size_t);
        m_stackCount = (size_t *)malloc(countArrayBytes);
        if (m_stackCount != NULL) {
            memset(m_stackCount, 0, countArrayBytes);
        }
        
        // 分配CPU使用率数组
        size_t cpuArrayBytes = m_maxStackCount * sizeof(float);
        m_stackCPU = (float *)malloc(cpuArrayBytes);
        if (m_stackCPU != NULL) {
            memset(m_stackCPU, 0, cpuArrayBytes);
        }
        
        // 分配前后台状态数组
        size_t backgroundArrayBytes = m_maxStackCount * sizeof(BOOL);
        m_stackInBackground = (BOOL *)malloc(backgroundArrayBytes);
        if (m_stackInBackground != NULL) {
            memset(m_stackInBackground, 0, backgroundArrayBytes);
        }
        
        // 初始化尾指针
        m_poolTailPoint = 0;
    }
    return self;
}

/**
 * 析构函数
 * 释放所有分配的内存
 * 
 * 注意：
 * - 需要先释放每个堆栈的内存（m_stackCyclePool[i]）
 * - 再释放数组本身的内存
 */
- (void)dealloc {
    // 释放每个堆栈的内存
    for (uint32_t i = 0; i < m_maxStackCount; i++) {
        if (m_stackCyclePool[i] != NULL) {
            free(m_stackCyclePool[i]);
            m_stackCyclePool[i] = NULL;
        }
    }
    
    // 释放数组本身的内存
    if (m_stackCyclePool != NULL) {
        free(m_stackCyclePool);
        m_stackCyclePool = NULL;
    }
    if (m_stackCount != NULL) {
        free(m_stackCount);
        m_stackCount = NULL;
    }
    if (m_stackCPU != NULL) {
        free(m_stackCPU);
        m_stackCPU = NULL;
    }
    if (m_stackInBackground != NULL) {
        free(m_stackInBackground);
        m_stackInBackground = NULL;
    }
}

// ============================================================================
#pragma mark - 堆栈管理
// ============================================================================

/**
 * 添加线程堆栈到池中
 * 
 * @param stackArray 堆栈地址数组（调用者已分配内存）
 * @param stackCount 堆栈深度（地址数量）
 * @param stackCPU 该线程的CPU使用率（百分比）
 * @param isInBackground 是否在后台采集
 * 
 * 实现：
 * 1. 参数校验
 * 2. 如果当前位置已有堆栈，先释放旧的
 * 3. 保存新堆栈的信息
 * 4. 尾指针前进（循环）
 * 
 * 注意：
 * - 堆栈数组的所有权转移给堆栈池
 * - 堆栈池负责释放堆栈数组的内存
 * - 使用循环数组，达到最大容量时自动覆盖最旧的
 * 
 * 示例：
 * - 容量100，已存满
 * - 添加第101个堆栈，覆盖第1个
 * - m_poolTailPoint = (100 + 1) % 100 = 1
 */
- (void)addThreadStack:(uintptr_t *)stackArray andLength:(size_t)stackCount andCPU:(float)stackCPU isInBackground:(BOOL)isInBackground {
    // 参数校验
    if (stackArray == NULL) {
        return;
    }
    if (m_stackCyclePool == NULL || m_stackCount == NULL) {
        return;
    }
    if (stackCount == 0) {
        return;
    }
    
    // 如果当前位置已有堆栈，释放旧的
    if (m_stackCyclePool[m_poolTailPoint] != NULL) {
        free(m_stackCyclePool[m_poolTailPoint]);
    }
    
    // 保存新堆栈信息
    m_stackCyclePool[m_poolTailPoint] = stackArray;
    m_stackCount[m_poolTailPoint] = stackCount;
    m_stackCPU[m_poolTailPoint] = stackCPU;
    m_stackInBackground[m_poolTailPoint] = isInBackground;

    // 尾指针前进（循环）
    m_poolTailPoint = (m_poolTailPoint + 1) % m_maxStackCount;
}

// ============================================================================
#pragma mark - 调用树生成
// ============================================================================

/**
 * 生成调用树（Call Tree）
 * 
 * @return 调用树数组，每个元素是一个字典，包含：
 *         - address：函数地址
 *         - symbol：函数符号（函数名）
 *         - repeat_count：出现次数
 *         - cpu_percent：CPU占比
 *         - children：子调用数组（递归结构）
 * 
 * 算法流程：
 * 1. 遍历堆栈池中的所有堆栈
 * 2. 将每个堆栈转换为地址帧（WCAddressFrame）
 * 3. 合并相同的调用路径，累加重复次数
 * 4. 按重复次数排序（高频调用在前）
 * 5. 符号化地址（地址 -> 函数名）
 * 6. 转换为字典数组
 * 
 * 使用场景：
 * - 生成火焰图（Flame Graph）
 * - 识别CPU热点函数
 * - 耗电分析报告
 * 
 * 性能考虑：
 * - 符号化比较耗时，在后台线程执行
 * - 最多处理100个堆栈样本
 */
- (NSArray<NSDictionary *> *)makeCallTree {
    // 重置父级地址帧数组
    _parentAddressFrame = nil;

    // 步骤1：遍历所有堆栈，构建地址帧树
    for (int i = 0; i < m_maxStackCount; i++) {
        uintptr_t *curStack = m_stackCyclePool[i];
        size_t curLength = m_stackCount[i];
        
        // 将堆栈转换为地址帧
        WCAddressFrame *curAddressFrame = [self p_getAddressFrameWithStackTraces:curStack 
                                                                           length:curLength 
                                                                              cpu:m_stackCPU[i] 
                                                                     isInBackground:m_stackInBackground[i]];
        
        // 添加到调用树中（合并相同路径）
        [self p_addAddressFrame:curAddressFrame];
    }

    NSMutableArray<NSDictionary *> *addressDictArray = [[NSMutableArray alloc] init];

    // 步骤2：按重复次数排序（高频调用在前）
    if ([self.parentAddressFrame count] > 1) {
        [self.parentAddressFrame sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
            WCAddressFrame *frame1 = (WCAddressFrame *)obj1;
            WCAddressFrame *frame2 = (WCAddressFrame *)obj2;
            if (frame1.repeatCount > frame2.repeatCount) {
                return NSOrderedAscending;  // 降序：高频在前
            }
            return NSOrderedDescending;
        }];
    }

    // 步骤3：符号化并转换为字典
    for (int i = 0; i < [self.parentAddressFrame count]; i++) {
        WCAddressFrame *addressFrame = self.parentAddressFrame[i];
        
        // 符号化：将地址转换为函数名
        [addressFrame symbolicate];
        
        // 转换为字典（递归处理子节点）
        NSDictionary *curDict = [self p_getInfoDictFromAddressFrame:addressFrame];
        [addressDictArray addObject:curDict];
    }

    return [addressDictArray copy];
}

/**
 * 从地址帧递归生成字典（私有方法）
 * 
 * @param addressFrame 地址帧对象
 * @return 包含地址帧信息和子节点的字典
 * 
 * 算法：
 * 1. 获取当前节点的信息字典
 * 2. 对子节点按重复次数排序
 * 3. 递归处理每个子节点
 * 4. 将子节点数组添加到"child"键下
 * 
 * 字典结构：
 * {
 *   "address": "0x100001234",
 *   "symbol": "-[MyClass method]",
 *   "repeat_count": 45,
 *   "child": [
 *     { 子节点1 },
 *     { 子节点2 }
 *   ]
 * }
 */
- (NSDictionary *)p_getInfoDictFromAddressFrame:(WCAddressFrame *)addressFrame {
    // 获取当前节点信息
    NSMutableDictionary *currentInfoDict = [[addressFrame getInfoDict] mutableCopy];
    NSMutableArray<NSDictionary *> *childInfoDict = [[NSMutableArray alloc] init];

    // 对子节点按重复次数排序
    if ([addressFrame.childAddressFrame count] > 1) {
        [addressFrame.childAddressFrame sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
            WCAddressFrame *frame1 = (WCAddressFrame *)obj1;
            WCAddressFrame *frame2 = (WCAddressFrame *)obj2;
            if (frame1.repeatCount > frame2.repeatCount) {
                return NSOrderedAscending;  // 降序排列
            }
            return NSOrderedDescending;
        }];
    }

    // 递归处理每个子节点
    for (WCAddressFrame *tmpCallFrame in addressFrame.childAddressFrame) {
        [childInfoDict addObject:[self p_getInfoDictFromAddressFrame:tmpCallFrame]];
    }

    // 将子节点数组添加到字典中
    if (childInfoDict != nil && [childInfoDict count] > 0) {
        [currentInfoDict setObject:[childInfoDict copy] forKey:@CHILE_FRAME];
    }
    
    return [currentInfoDict copy];
}

/**
 * 将堆栈地址数组转换为地址帧链表（私有方法）
 * 
 * @param stackTrace 堆栈地址数组
 * @param traceLength 堆栈深度
 * @param stackCPU 该线程的CPU使用率
 * @param isInBackground 是否在后台采集
 * @return 地址帧链表的头节点
 * 
 * 算法：
 * 1. 计算重复权重：CPU / 5（CPU越高，权重越大）
 * 2. 遍历堆栈地址，创建地址帧
 * 3. 将地址帧连接成链表（父->子）
 * 4. 限制最大深度为50层
 * 
 * 重复权重说明：
 * - CPU 10% -> 权重 2
 * - CPU 50% -> 权重 10
 * - CPU 100% -> 权重 20
 * - 权重用于调用树的重复次数累加
 * 
 * 示例：
 * 堆栈：[main, viewDidLoad, heavyMethod]
 * 转换为：main -> viewDidLoad -> heavyMethod
 */
- (WCAddressFrame *)p_getAddressFrameWithStackTraces:(uintptr_t *)stackTrace length:(size_t)traceLength cpu:(float)stackCPU isInBackground:(BOOL)isInBackground {
    if (stackTrace == NULL || traceLength == 0) {
        return nil;
    }
    
    WCAddressFrame *headAddressFrame = nil;
    WCAddressFrame *currentParentFrame = nil;

    // 计算重复权重：CPU使用率越高，权重越大
    // 例如：CPU 85% -> 权重 17
    uint32_t repeatWeight = (uint32_t)(stackCPU / 5.);
    
    // 遍历堆栈地址，创建地址帧链表
    // 限制最大深度为50层
    for (int i = 0; i < traceLength && i < MAX_STACK_TRACE_IN_LOG; i++) {
        uintptr_t address = stackTrace[i];
        WCAddressFrame *curFrame = [[WCAddressFrame alloc] initWithAddress:address 
                                                           withRepeatCount:repeatWeight 
                                                            isInBackground:isInBackground];
        
        if (currentParentFrame == nil) {
            // 第一个地址帧作为头节点
            headAddressFrame = curFrame;
            currentParentFrame = curFrame;
        } else {
            // 将新地址帧添加为当前节点的子节点
            [currentParentFrame addChildFrame:curFrame];
            currentParentFrame = curFrame;
        }
    }
    
    return headAddressFrame;
}

/**
 * 添加地址帧到调用树（私有方法）
 * 
 * @param addressFrame 要添加的地址帧
 * 
 * 算法：
 * 1. 如果是第一个地址帧，直接添加
 * 2. 否则，在现有的父级地址帧中查找相同地址的节点
 * 3. 如果找到，合并两个地址帧（累加重复次数）
 * 4. 如果未找到，添加为新的父级地址帧
 * 
 * 合并规则：
 * - 相同地址的节点合并
 * - 重复次数累加
 * - 递归合并子节点
 * 
 * 示例：
 * 现有树：main(10) -> viewDidLoad(10)
 * 新增：  main(5) -> heavyMethod(5)
 * 结果：  main(15) -> viewDidLoad(10)
 *                  -> heavyMethod(5)
 */
- (void)p_addAddressFrame:(WCAddressFrame *)addressFrame {
    if (addressFrame == nil) {
        return;
    }
    
    // 初始化父级地址帧数组
    if (_parentAddressFrame == nil) {
        _parentAddressFrame = [[NSMutableArray alloc] init];
    }
    
    // 如果是第一个地址帧，直接添加
    if ([_parentAddressFrame count] == 0) {
        [_parentAddressFrame addObject:addressFrame];
    } else {
        // 在现有的父级地址帧中查找相同地址的节点
        WCAddressFrame *foundAddressFrame = nil;
        for (WCAddressFrame *tmpFrame in _parentAddressFrame) {
            foundAddressFrame = [tmpFrame tryFoundAddressFrameWithAddress:addressFrame.address];
            if (foundAddressFrame != nil) {
                break;
            }
        }
        
        if (foundAddressFrame == nil) {
            // 未找到相同地址，添加为新的父级地址帧
            [_parentAddressFrame addObject:addressFrame];
        } else {
            // 找到相同地址，合并两个地址帧
            [self p_mergeAddressFrame:foundAddressFrame with:addressFrame];
        }
    }
}

/**
 * 合并两个地址帧（私有方法）
 * 
 * @param mainFrame 主地址帧（要保留的）
 * @param mergedFrame 要合并的地址帧
 * 
 * 算法：
 * 1. 断言两个地址帧的地址必须相同
 * 2. 累加重复次数
 * 3. 累加后台重复次数
 * 4. 如果主地址帧没有子节点，直接使用合并帧的子节点
 * 5. 否则，递归合并子节点数组
 * 
 * 示例：
 * mainFrame:   main(10) -> viewDidLoad(10)
 * mergedFrame: main(5) -> viewDidLoad(3) -> method(2)
 * 结果:        main(15) -> viewDidLoad(13) -> method(2)
 */
- (void)p_mergeAddressFrame:(WCAddressFrame *)mainFrame with:(WCAddressFrame *)mergedFrame {
    // 断言：两个地址帧的地址必须相同
    if (mainFrame.address != mergedFrame.address) {
        assert(0);
    }
    
    // 累加重复次数
    mainFrame.repeatCount += mergedFrame.repeatCount;
    mainFrame.repeatCountInBackground += mergedFrame.repeatCountInBackground;

    // 如果主地址帧没有子节点，直接使用合并帧的子节点
    if (mainFrame.childAddressFrame == nil || [mainFrame.childAddressFrame count] == 0) {
        mainFrame.childAddressFrame = mergedFrame.childAddressFrame;
        return; // 完全复制mergedFrame的子节点
    }

    // 递归合并子节点数组
    [self p_mergedAddressFrameArray:mainFrame.childAddressFrame with:mergedFrame.childAddressFrame];
}

/**
 * 合并两个地址帧数组（私有方法）
 * 
 * @param mainFrameArray 主地址帧数组
 * @param mergedFrameArray 要合并的地址帧数组
 * 
 * 算法：
 * 1. 遍历mergedFrameArray中的每个地址帧
 * 2. 在mainFrameArray中查找相同地址的帧
 * 3. 如果找到，递归合并
 * 4. 如果未找到，添加到notFoundFrame数组
 * 5. 将所有未找到的帧添加到mainFrameArray末尾
 * 
 * 示例：
 * mainFrameArray:   [frameA(10), frameB(20)]
 * mergedFrameArray: [frameA(5), frameC(15)]
 * 结果:             [frameA(15), frameB(20), frameC(15)]
 */
- (void)p_mergedAddressFrameArray:(NSMutableArray<WCAddressFrame *> *)mainFrameArray with:(NSMutableArray<WCAddressFrame *> *)mergedFrameArray {
    if (mergedFrameArray == nil || [mergedFrameArray count] == 0) {
        return;
    }
    
    // 存储未找到的帧
    NSMutableArray<WCAddressFrame *> *notFoundFrame = [NSMutableArray array];
    
    // 遍历要合并的数组
    for (WCAddressFrame *mergedFrame in mergedFrameArray) {
        BOOL bFound = NO;
        
        // 在主数组中查找相同地址的帧
        for (WCAddressFrame *mainFrame in mainFrameArray) {
            if (mergedFrame.address == mainFrame.address) {
                bFound = YES;
                // 找到相同地址，递归合并
                [self p_mergeAddressFrame:mainFrame with:mergedFrame];
                break;
            }
        }
        
        if (bFound == NO) {
            // 未找到，添加到未找到列表
            [notFoundFrame addObject:mergedFrame];
        }
    }
    
    // 将所有未找到的帧添加到主数组
    [mainFrameArray addObjectsFromArray:notFoundFrame];
}

/**
 * 调试描述
 * 
 * @return 调用树的文本描述
 */
- (NSString *)description {
    NSMutableString *retStr = [NSMutableString new];

    for (int i = 0; i < [self.parentAddressFrame count]; i++) {
        WCAddressFrame *frame = self.parentAddressFrame[i];
        [retStr appendString:[frame description]];
    }

    return retStr;
}

@end

// ============================================================================
#pragma mark - WCCpuStackFrame（CPU堆栈帧）
// ============================================================================

/**
 * WCCpuStackFrame - CPU堆栈帧
 * 
 * 用途：
 * - 存储线程ID和CPU使用率的关联
 * - 用于排序和筛选高CPU线程
 */
@interface WCCpuStackFrame : NSObject

@property (nonatomic, assign) thread_t cpu_thread;  // 线程ID
@property (nonatomic, assign) float cpu_value;      // CPU使用率（百分比）

- (id)initWithThread:(thread_t)cpu_thread andCpuValue:(float)cpu_value;

@end

@implementation WCCpuStackFrame

/**
 * 初始化CPU堆栈帧
 * 
 * @param cpu_thread 线程ID
 * @param cpu_value CPU使用率（百分比）
 */
- (id)initWithThread:(thread_t)cpu_thread andCpuValue:(float)cpu_value {
    self = [super init];
    if (self) {
        self.cpu_thread = cpu_thread;
        self.cpu_value = cpu_value;
    }
    return self;
}

@end

// ============================================================================
#pragma mark - WCPowerConsumeStackCollector（耗电堆栈收集器）
// ============================================================================

/**
 * 全局变量
 */

/**
 * 耗电堆栈采集的CPU阈值（默认80%）
 * 只有总CPU超过此值才会采集堆栈
 */
static float g_kGetPowerStackCPULimit = 80.;

/**
 * CPU高占用线程的堆栈游标数组
 * 用于KSCrash生成转储报告
 */
static KSStackCursor **g_cpuHighThreadArray = NULL;

/**
 * CPU高占用线程数量
 */
static int g_cpuHighThreadNumber = 0;

/**
 * CPU高占用线程的CPU使用率数组
 */
static float *g_cpuHighThreadValueArray = NULL;

/**
 * 当前是否在后台
 */
static BOOL g_isInBackground = NO;

/**
 * WCPowerConsumeStackCollector 类扩展
 */
@interface WCPowerConsumeStackCollector ()

/**
 * 堆栈追踪池
 * 存储最近100个高CPU线程的堆栈
 */
@property (nonatomic, strong) WCStackTracePool *stackTracePool;

@end

@implementation WCPowerConsumeStackCollector

// ============================================================================
#pragma mark - 初始化和生命周期
// ============================================================================

/**
 * 初始化耗电堆栈收集器
 * 
 * @param cpuLimit CPU阈值（百分比）
 * @return WCPowerConsumeStackCollector实例
 * 
 * 说明：
 * - 设置全局CPU阈值
 * - 创建堆栈池（容量100）
 * - 监听前后台切换通知
 */
- (id)initWithCPULimit:(float)cpuLimit {
    self = [super init];
    if (self) {
        // 设置CPU阈值
        g_kGetPowerStackCPULimit = cpuLimit;
        
        // 创建堆栈池
        _stackTracePool = [[WCStackTracePool alloc] initWithMaxStackTraceCount:MAX_STACK_TRACE_COUNT];

#if !TARGET_OS_OSX
        // 监听前后台切换
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(willEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }
    return self;
}

/**
 * 析构函数
 * 移除通知监听
 */
- (void)dealloc {
#if !TARGET_OS_OSX
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#endif
}

/**
 * App即将进入前台
 * 更新前后台状态
 */
- (void)willEnterForeground {
    g_isInBackground = NO;
}

/**
 * App已进入后台
 * 更新前后台状态
 */
- (void)didEnterBackground {
    g_isInBackground = YES;
}

// ============================================================================
#pragma mark - 耗电检测（长期CPU监控）
// ============================================================================

/**
 * 生成耗电堆栈结论（异步）
 * 
 * 工作流程：
 * 1. 冻结当前堆栈池
 * 2. 创建新的堆栈池供后续使用
 * 3. 在全局队列中异步生成调用树
 * 4. 通过代理回调返回结果
 * 
 * 说明：
 * - 此方法不会阻塞调用线程
 * - 调用树生成可能需要几百毫秒（需要符号化）
 * - 结果通过delegate的powerConsumeStackCollectorConclude:返回
 * 
 * 使用场景：
 * - 当WCCPUHandler检测到平均CPU过高时调用
 * - 生成完整的耗电分析报告
 * 
 * 性能考虑：
 * - 异步执行，不影响监控线程
 * - 符号化比较耗时，在后台队列执行
 */
- (void)makeConclusion {
    // 冻结当前堆栈池
    WCStackTracePool *handlePool = _stackTracePool;
    
    // 创建新的堆栈池供后续使用
    _stackTracePool = [[WCStackTracePool alloc] initWithMaxStackTraceCount:MAX_STACK_TRACE_COUNT];
    
    // 在全局队列中异步生成调用树
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 生成调用树（耗时操作）
        NSArray<NSDictionary *> *stackTree = [handlePool makeCallTree];
        
        // 通过代理回调返回结果
        if (self.delegate != nil && [self.delegate respondsToSelector:@selector(powerConsumeStackCollectorConclude:)]) {
            [self.delegate powerConsumeStackCollectorConclude:stackTree];
        }
    });
}

/**
 * 获取CPU使用率并采集耗电堆栈（核心方法）
 * 
 * @return App的CPU使用率（百分比），-1表示失败
 * 
 * 工作流程：
 * 1. 遍历App所有线程，获取每个线程的CPU使用率
 * 2. 累加得到App总CPU使用率
 * 3. 识别CPU占用高的线程（> 5%）
 * 4. 如果总CPU > cpuLimit：
 *    a. 对每个高CPU线程执行backtrace
 *    b. 将堆栈添加到堆栈池
 * 5. 返回总CPU使用率
 * 
 * 与appCpuUsage的区别：
 * - 此方法在获取CPU的同时采集堆栈
 * - 用于耗电分析，持续采集样本
 * - 只有当CPU > 阈值时才采集，避免不必要的开销
 * 
 * 技术细节：
 * - 使用task_threads获取所有线程
 * - 使用thread_info获取每个线程的CPU使用率
 * - 使用kssc_backtraceCurrentThread获取堆栈
 * - 自动过滤空闲线程和监控线程自身
 * 
 * 性能考虑：
 * - 只有当CPU超过阈值时才采集堆栈
 * - backtrace有一定性能开销
 * - 建议控制调用频率（每秒1次）
 * 
 * 使用场景：
 * - 在WCBlockMonitorMgr的check方法中替代appCpuUsage调用
 * - 持续60秒采集样本后，调用makeConclusion生成调用树
 */
- (float)getCPUUsageAndPowerConsumeStack {
    mach_msg_type_number_t thread_count;
    NSMutableArray<WCCpuStackFrame *> *cost_cpu_thread_array = [[NSMutableArray alloc] init];

    // 步骤1：获取总CPU使用率，同时收集高CPU线程
    // @selector(getTotCpuWithCostCpuThreadArray:andThreadCount:) 就是获取到的CPU的使用率，这个函数调用下面的代码实在生成堆栈，存储到堆栈池 _stackTracePool 中
    float result = [self getTotCpuWithCostCpuThreadArray:&cost_cpu_thread_array andThreadCount:&thread_count];

    // 如果获取失败，返回-1
    if (fabs(result + 1.0) < FLOAT_THRESHOLD) {
        return -1.0;
    }

    // 步骤2：准备线程列表和CPU值列表
    thread_t *cost_cpu_thread_list = (thread_t *)malloc(sizeof(thread_t) * thread_count);
    float *cost_cpu_value_list = (float *)malloc(sizeof(float) * thread_count);
    mach_msg_type_number_t cost_cpu_thread_count = 0;

    // 将NSArray转换为C数组
    for (int i = 0; i < [cost_cpu_thread_array count]; i++) {
        cost_cpu_thread_list[i] = cost_cpu_thread_array[i].cpu_thread;
        cost_cpu_value_list[i] = cost_cpu_thread_array[i].cpu_value;
        cost_cpu_thread_count++;
    }

    // 步骤3：如果总CPU超过阈值，采集高CPU线程的堆栈
    if (result > g_kGetPowerStackCPULimit && cost_cpu_thread_count > 0) {
        // 获取堆栈信息
        StackInfo stackInfo = [self getStackInfoWithThreadCount:cost_cpu_thread_count
                                              costCpuThreadList:cost_cpu_thread_list
                                               costCpuValueList:cost_cpu_value_list];

        uintptr_t **stack_matrix = stackInfo.stack_matrix;
        int *trace_length_matrix = stackInfo.trace_length_matrix;

        // 将堆栈添加到堆栈池
        if (stack_matrix != NULL && trace_length_matrix != NULL) {
            for (int i = 0; i < cost_cpu_thread_count; i++) {
                if (stack_matrix[i] != NULL) {
                    [_stackTracePool addThreadStack:stack_matrix[i] 
                                          andLength:(size_t)trace_length_matrix[i] 
                                             andCPU:cost_cpu_value_list[i] 
                                       isInBackground:g_isInBackground];
                }
            }
            // 释放堆栈矩阵（堆栈数组已转移给堆栈池）
            free(stack_matrix);
            free(trace_length_matrix);
        }
    }

    // 清理临时数组
    free(cost_cpu_thread_list);
    free(cost_cpu_value_list);
    
    return result;
}

// ============================================================================
#pragma mark - CPU卡顿检测（瞬时CPU监控）
// ============================================================================

/**
 * 判断是否为CPU高占用卡顿
 * 
 * @return YES表示是CPU高占用导致的卡顿，NO表示不是
 * 
 * 说明：
 * - 当瞬时CPU过高时，调用此方法判断是否需要生成CPU卡顿转储
 * - 内部会调用getCPUUsageAndCPUBlockStack采集堆栈
 * - 采集成功且CPU > 阈值，返回YES
 * 
 * 使用场景：
 * - 在check方法检测到瞬时CPU过高时调用
 * - 用于决定是否返回EDumpType_CPUBlock
 * 
 * 与getCPUUsageAndPowerConsumeStack的区别：
 * - isCPUHighBlock：用于瞬时检测，采集Top 3线程
 * - getCPUUsageAndPowerConsumeStack：用于长期监控，采集所有高CPU线程
 */
- (BOOL)isCPUHighBlock {
    // 尝试采集CPU卡顿堆栈
    // 如果返回-1（失败），返回NO
    if (fabs([self getCPUUsageAndCPUBlockStack] + 1) < FLOAT_THRESHOLD) {
        return NO;
    }
    return YES;
}

/**
 * 获取CPU使用率并采集CPU卡顿堆栈
 * 
 * @return App的CPU使用率（百分比），-1表示失败
 * 
 * 工作流程：
 * 1. 遍历App所有线程，获取每个线程的CPU使用率
 * 2. 按CPU使用率降序排序
 * 3. 只采集Top 3高CPU线程的堆栈（CPU卡顿专用）
 * 4. 将堆栈保存到全局变量，供KSCrash生成转储报告
 * 
 * 与getCPUUsageAndPowerConsumeStack的区别：
 * - 此方法用于瞬时CPU卡顿检测
 * - 只采集Top 3线程（减少转储报告大小）
 * - 保存到全局变量（供KSCrash使用）
 * - 生成崩溃式转储报告
 * 
 * 全局变量说明：
 * - g_cpuHighThreadArray：堆栈游标数组，供kscrash_pointCPUHighThreadCallback使用
 * - g_cpuHighThreadNumber：线程数量
 * - g_cpuHighThreadValueArray：每个线程的CPU使用率
 * 
 * 使用场景：
 * - isCPUHighBlock内部调用
 * - 用于生成EDumpType_CPUBlock类型的转储报告
 */
- (float)getCPUUsageAndCPUBlockStack {
    mach_msg_type_number_t thread_count;
    NSMutableArray<WCCpuStackFrame *> *cost_cpu_thread_array = [[NSMutableArray alloc] init];

    // 步骤1：获取总CPU使用率，同时收集高CPU线程
    float result = [self getTotCpuWithCostCpuThreadArray:&cost_cpu_thread_array andThreadCount:&thread_count];

    if (fabs(result + 1.0) < FLOAT_THRESHOLD) {
        return -1.0;
    }

    // 步骤2：按CPU使用率降序排序（CPU最高的在前）
    [cost_cpu_thread_array sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
        WCCpuStackFrame *frame1 = (WCCpuStackFrame *)obj1;
        WCCpuStackFrame *frame2 = (WCCpuStackFrame *)obj2;
        if (frame1.cpu_value > frame2.cpu_value) {
            return NSOrderedAscending;  // 降序：高CPU在前
        }
        return NSOrderedDescending;
    }];

    thread_t *cost_cpu_thread_list = (thread_t *)malloc(sizeof(thread_t) * thread_count);
    float *cost_cpu_value_list = (float *)malloc(sizeof(float) * thread_count);
    mach_msg_type_number_t cost_cpu_thread_count = 0;

    // 步骤3：只采集Top 3高CPU线程（CPU卡顿专用）
    // 限制为3个线程，避免转储报告过大
    for (int i = 0; i < [cost_cpu_thread_array count] && i < 3; i++) {
        cost_cpu_thread_list[i] = cost_cpu_thread_array[i].cpu_thread;
        cost_cpu_value_list[i] = cost_cpu_thread_array[i].cpu_value;
        cost_cpu_thread_count++;
    }

    // 步骤4：如果总CPU超过阈值，采集堆栈
    if (result > g_kGetPowerStackCPULimit && cost_cpu_thread_count > 0) {
        // 获取堆栈信息
        StackInfo stackInfo = [self getStackInfoWithThreadCount:cost_cpu_thread_count
                                              costCpuThreadList:cost_cpu_thread_list
                                               costCpuValueList:cost_cpu_value_list];

        uintptr_t **stack_matrix = stackInfo.stack_matrix;
        int *trace_length_matrix = stackInfo.trace_length_matrix;

        if (stack_matrix != NULL && trace_length_matrix != NULL) {
            // 统计实际成功采集的线程数量
            int real_cpu_thread_count = 0;
            for (int i = 0; i < cost_cpu_thread_count; i++) {
                if (stack_matrix[i] != NULL) {
                    real_cpu_thread_count++;
                }
            }

            // 分配全局变量（供KSCrash使用）
            g_cpuHighThreadArray = (KSStackCursor **)malloc(sizeof(KSStackCursor *) * (int)real_cpu_thread_count);
            g_cpuHighThreadNumber = (int)real_cpu_thread_count;
            g_cpuHighThreadValueArray = (float *)malloc(sizeof(float) * (int)real_cpu_thread_count);

            // 初始化KSStackCursor
            int index = 0;
            for (int i = 0; i < cost_cpu_thread_count; i++) {
                if (stack_matrix[i] != NULL) {
                    // 为每个线程分配KSStackCursor
                    g_cpuHighThreadArray[index] = (KSStackCursor *)malloc(sizeof(KSStackCursor));
                    
                    // 使用堆栈地址数组初始化游标
                    kssc_initWithBacktrace(g_cpuHighThreadArray[index], stack_matrix[i], trace_length_matrix[i], 0);
                    
                    // 记录CPU使用率
                    g_cpuHighThreadValueArray[index] = cost_cpu_value_list[i];
                    index++;
                }
            }

            // 释放堆栈矩阵
            free(stack_matrix);
            free(trace_length_matrix);
        }
    }

    // 清理临时数组
    free(cost_cpu_thread_list);
    free(cost_cpu_value_list);
    
    return result;
}

/**
 * 获取CPU高占用线程数量
 * 
 * @return CPU高占用线程的数量（0-3）
 * 
 * 说明：
 * - 返回最近一次getCPUUsageAndCPUBlockStack采集的线程数量
 * - 用于KSCrash生成转储报告时，决定需要写入多少个堆栈
 */
- (int)getCurrentCpuHighStackNumber {
    return g_cpuHighThreadNumber;
}

/**
 * 获取CPU高占用线程的堆栈游标数组
 * 
 * @return KSStackCursor指针数组
 * 
 * 说明：
 * - 返回的是指向堆栈游标数组的指针
 * - 数组长度由getCurrentCpuHighStackNumber确定
 * - KSCrash使用此接口在生成转储报告时写入CPU堆栈
 * 
 * 使用场景：
 * - KSCrash生成CPU卡顿转储报告时调用
 * - 通过全局回调函数kscrash_pointCPUHighThreadCallback访问
 */
- (KSStackCursor **)getCPUStackCursor {
    return g_cpuHighThreadArray;
}

/**
 * 获取CPU高占用线程的CPU使用率数组
 * 
 * @return float数组，每个元素对应一个高CPU线程的使用率
 * 
 * 说明：
 * - 数组长度等于getCurrentCpuHighStackNumber
 * - 每个值是该线程的CPU使用率（百分比）
 * - 用于在转储报告中记录每个线程的CPU占用情况
 * 
 * 使用场景：
 * - 生成CPU卡顿转储报告时，记录线程CPU信息
 * - 通过全局回调函数kscrash_pointCpuHighThreadArrayCallBack访问
 */
- (float *)getCpuHighThreadValueArray {
    return g_cpuHighThreadValueArray;
}

// ============================================================================
#pragma mark - 辅助方法
// ============================================================================

/**
 * 获取总CPU使用率，同时收集高CPU线程（私有方法）
 * 
 * @param cost_cpu_thread_array 输出参数：高CPU线程数组
 * @param thread_count 输出参数：总线程数
 * @return App的CPU使用率（百分比），-1表示失败
 * 
 * 工作流程：
 * 1. 使用task_threads获取App的所有线程
 * 2. 遍历每个线程，使用thread_info获取CPU使用率
 * 3. 累加总CPU使用率
 * 4. 将CPU > 5%的线程添加到cost_cpu_thread_array
 * 5. 过滤监控线程自身和空闲线程
 * 
 * 筛选条件：
 * - CPU使用率 > 5%
 * - 不是监控线程自身
 * - 不是空闲线程（TH_FLAGS_IDLE）
 * 
 * 性能考虑：
 * - 需要遍历所有线程，有一定开销
 * - 使用goto cleanup确保资源正确释放
 * 
 * 与MatrixDeviceInfo的appCpuUsage相似：
 * - 都使用task_threads和thread_info
 * - 此方法额外收集高CPU线程信息
 */
- (float)getTotCpuWithCostCpuThreadArray:(NSMutableArray<WCCpuStackFrame *> **)cost_cpu_thread_array
                          andThreadCount:(mach_msg_type_number_t *)thread_count {
    // 变量声明
    const task_t thisTask = mach_task_self();
    kern_return_t kr;
    thread_array_t thread_list;

    // 获取App的所有线程
    kr = task_threads(thisTask, &thread_list, thread_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    float tot_cpu = 0.0;
    const thread_t thisThread = (thread_t)ksthread_self();  // 监控线程自身

    // 遍历所有线程，获取CPU使用率并收集高CPU线程
    for (int j = 0; j < *thread_count; j++) {
        thread_t current_thread = thread_list[j];

        // 获取线程基本信息
        thread_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(current_thread, THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            tot_cpu = -1;
            goto cleanup;  // 出错时跳转到清理代码
        }

        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
        float cur_cpu = 0;

        // 只统计非空闲线程
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            // 转换CPU使用率：cpu_usage / TH_USAGE_SCALE * 100
            cur_cpu = basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
            tot_cpu = tot_cpu + cur_cpu;
        }

        // 将高CPU线程添加到数组
        // 条件：CPU > 5% && 不是监控线程自身 && 数组不为空
        if (cur_cpu > 5. && current_thread != thisThread && *cost_cpu_thread_array != NULL) {
            WCCpuStackFrame *cpu_stack_frame = [[WCCpuStackFrame alloc] initWithThread:current_thread 
                                                                            andCpuValue:cur_cpu];
            [*cost_cpu_thread_array addObject:cpu_stack_frame];
        }
    }

cleanup:
    // 清理资源：释放所有线程端口
    for (int i = 0; i < *thread_count; i++) {
        mach_port_deallocate(thisTask, thread_list[i]);
    }

    // 释放线程列表内存
    kr = vm_deallocate(thisTask, (vm_offset_t)thread_list, *thread_count * sizeof(thread_t));
    return tot_cpu;
}

/**
 * 获取指定线程的堆栈信息（私有方法）
 * 
 * @param cost_cpu_thread_count 线程数量
 * @param cost_cpu_thread_list 线程ID数组
 * @param cost_cpu_value_list CPU使用率数组（未使用，仅用于记录）
 * @return StackInfo结构体，包含堆栈矩阵和长度矩阵
 * 
 * 工作流程：
 * 1. 分配堆栈矩阵（二维数组）
 * 2. 为每个线程分配堆栈数组（最大200个地址）
 * 3. 挂起所有线程（确保堆栈稳定）
 * 4. 对每个线程执行backtrace
 * 5. 恢复所有线程
 * 6. 返回堆栈信息
 * 
 * 技术细节：
 * - 使用ksmc_suspendEnvironment挂起所有线程
 * - 使用kssc_backtraceCurrentThread获取堆栈
 * - 堆栈数组大小：maxEntries * 2 = 200（考虑异步线程）
 * - 使用do-while(0)模式方便错误处理
 * 
 * 内存管理：
 * - 调用者负责释放stack_matrix和trace_length_matrix
 * - 如果分配失败，返回空结构体
 * 
 * 注意事项：
 * - 挂起线程有一定风险，可能导致死锁
 * - 应该尽快恢复线程
 * - 堆栈数组的所有权转移给调用者
 */
- (StackInfo)getStackInfoWithThreadCount:(mach_msg_type_number_t)cost_cpu_thread_count
                       costCpuThreadList:(thread_t *)cost_cpu_thread_list
                        costCpuValueList:(float *)cost_cpu_value_list {
    struct StackInfo result;
    
    // 使用do-while(0)模式，方便错误处理（通过break跳出）
    do {
        size_t maxEntries = 100;  // 单个堆栈最大地址数
        
        // 步骤1：分配堆栈长度数组
        int *trace_length_matrix = (int *)malloc(sizeof(int) * cost_cpu_thread_count);
        if (trace_length_matrix == NULL) {
            break;  // 分配失败，退出
        }
        
        // 步骤2：分配堆栈矩阵（指针数组）
        uintptr_t **stack_matrix = (uintptr_t **)malloc(sizeof(uintptr_t *) * cost_cpu_thread_count);
        if (stack_matrix == NULL) {
            free(trace_length_matrix);
            break;
        }
        
        // 步骤3：为每个线程分配堆栈数组
        BOOL have_null = NO;
        for (int i = 0; i < cost_cpu_thread_count; i++) {
            // 分配大小应该考虑异步线程，所以是 maxEntries * 2
            stack_matrix[i] = (uintptr_t *)malloc(sizeof(uintptr_t) * maxEntries * 2);
            if (stack_matrix[i] == NULL) {
                have_null = YES;
            }
        }
        
        // 如果有分配失败，清理所有已分配的内存
        if (have_null) {
            for (int i = 0; i < cost_cpu_thread_count; i++) {
                if (stack_matrix[i] != NULL) {
                    free(stack_matrix[i]);
                }
            }
            free(stack_matrix);
            free(trace_length_matrix);
            break;
        }

        // 步骤4：挂起所有线程（确保堆栈稳定）
        ksmc_suspendEnvironment();
        
        // 步骤5：对每个线程执行backtrace
        for (int i = 0; i < cost_cpu_thread_count; i++) {
            thread_t current_thread = cost_cpu_thread_list[i];
            uintptr_t backtrace_buffer[maxEntries];

            // 获取线程堆栈
            trace_length_matrix[i] = kssc_backtraceCurrentThread(current_thread, backtrace_buffer, (int)maxEntries);

            // ============================================================================
            // 🆕 异步堆栈合并逻辑
            // ============================================================================
            WCAsyncStackTraceManager *asyncManager = [WCAsyncStackTraceManager sharedInstance];
            if ([asyncManager isEnabled]) {
                // 查询异步线程的发起堆栈
                NSArray<NSNumber *> *originStack = [asyncManager getOriginStackForThread:current_thread];
                
                if (originStack && originStack.count > 0) {
                    int currentLength = trace_length_matrix[i];
                    
                    // 添加异步分界线标记（特殊地址）
                    if (currentLength < maxEntries) {
                        backtrace_buffer[currentLength++] = (uintptr_t)0xDEADBEEF;
                    }
                    
                    // 追加发起堆栈
                    for (NSNumber *addr in originStack) {
                        if (currentLength < maxEntries) {
                            backtrace_buffer[currentLength++] = [addr unsignedLongValue];
                        } else {
                            break;
                        }
                    }
                    
                    // 更新堆栈长度
                    trace_length_matrix[i] = currentLength;
                    
                    MatrixInfo(@"[AsyncTrace] 线程 %u: 合并了 %lu 帧异步堆栈", 
                              current_thread, (unsigned long)originStack.count);
                }
            }

            // 复制堆栈地址到矩阵
            int j = 0;
            for (; j < trace_length_matrix[i]; j++) {
                stack_matrix[i][j] = backtrace_buffer[j];
            }
        }
        
        // 步骤6：恢复所有线程
        ksmc_resumeEnvironment();

        // 返回堆栈信息
        result = { stack_matrix, trace_length_matrix };
    } while (0);
    
    return result;
}

@end
