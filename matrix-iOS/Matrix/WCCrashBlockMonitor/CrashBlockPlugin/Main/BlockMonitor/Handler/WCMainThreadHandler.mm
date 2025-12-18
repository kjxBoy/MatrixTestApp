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

/**
 * ============================================================================
 * WCMainThreadHandler - 主线程堆栈处理器
 * ============================================================================
 * 
 * 功能概述：
 * 管理主线程堆栈的循环数组，通过重复次数分析找出最有可能导致卡顿的堆栈。
 * 
 * ============================================================================
 * 核心原理：Point Stack算法
 * ============================================================================
 * 
 * 1. 堆栈循环数组：
 *    - 使用固定大小的循环数组保存周期性采集的主线程堆栈
 *    - 数组大小 = 检查周期 / 堆栈采集间隔
 *    - 例如：1000ms / 50ms = 20个堆栈
 *    - 当数组满时，覆盖最旧的数据（FIFO）
 * 
 * 2. 栈顶地址连续重复次数统计：
 *    - 每次添加新堆栈时，比较其栈顶地址与上一个堆栈的栈顶地址
 *    - 如果相同，重复次数 = 上一次重复次数 + 1
 *    - 如果不同，重复次数 = 0
 *    - 保存每个堆栈的连续重复次数
 * 
 * 3. Point Stack（最可能导致卡顿的堆栈）：
 *    - 遍历循环数组，找出连续重复次数最多的堆栈
 *    - 重复次数越多，说明主线程在这个函数上停留的时间越长
 *    - 这就是最有可能导致卡顿的堆栈
 * 
 * 4. 地址总重复次数统计：
 *    - 对于Point Stack中的每个地址，统计其在所有堆栈中的总出现次数
 *    - 出现次数越多，说明这个函数调用越频繁
 *    - 有助于在符号化后识别最耗时的函数
 * 
 * ============================================================================
 * 举例说明：
 * ============================================================================
 * 
 * 假设检查周期为1000ms，堆栈采集间隔为50ms，循环数组大小为20。
 * 
 * 时间轴：
 * T0    T50   T100  T150  T200  T250  T300  ...
 * |-----|-----|-----|-----|-----|-----|-----|
 * S0    S1    S2    S3    S4    S5    S6    ...
 * 
 * 采集的堆栈（简化为栈顶地址）：
 * Index:  0    1    2    3    4    5    6    7    8    9   10   11   12   ...
 * Top:    A    B    C    C    C    C    C    D    D    E    E    E    E    ...
 * Repeat: 0    0    0    1    2    3    4    0    1    0    1    2    3    ...
 * 
 * 分析：
 * - S4（Index=4）的栈顶地址C连续重复了4次（S2-S6）
 * - S12（Index=12）的栈顶地址E连续重复了3次（S9-S12）
 * - S4的重复次数最多，所以S4就是Point Stack
 * - 主线程在S4对应的函数上停留了约 5 * 50ms = 250ms
 * 
 * ============================================================================
 * 数据结构：
 * ============================================================================
 * 
 * m_mainThreadStackCycleArray (二维数组):
 *   [0] -> [addr0, addr1, addr2, ..., addrN]  // 第0个堆栈
 *   [1] -> [addr0, addr1, addr2, ..., addrM]  // 第1个堆栈
 *   ...
 *   [19] -> [addr0, addr1, addr2, ..., addrK] // 第19个堆栈
 * 
 * m_mainThreadStackCount:
 *   [0] -> N  // 第0个堆栈的深度
 *   [1] -> M  // 第1个堆栈的深度
 *   ...
 * 
 * m_topStackAddressRepeatArray:
 *   [0] -> 0  // 第0个堆栈的栈顶连续重复次数
 *   [1] -> 0
 *   [2] -> 0
 *   [3] -> 1
 *   [4] -> 2  // 第4个堆栈的栈顶连续重复了2次
 *   ...
 * 
 * m_tailPoint:
 *   指向下一个要写入的位置（循环数组的尾指针）
 * 
 * ============================================================================
 * 使用流程：
 * ============================================================================
 * 
 * 1. 初始化：
 *    handler = [[WCMainThreadHandler alloc] initWithCycleArrayCount:20];
 * 
 * 2. 周期性添加堆栈：
 *    for (int i = 0; i < 20; i++) {
 *        usleep(50000);  // 50ms
 *        uintptr_t *stack = getCurrentStack();
 *        [handler addThreadStack:stack andStackCount:count];
 *    }
 * 
 * 3. 检测到卡顿时，获取Point Stack：
 *    KSStackCursor *pointStack = [handler getPointStackCursor];
 *    // 这就是最有可能导致卡顿的堆栈
 * 
 * 4. 生成Profile报告：
 *    char *profile = [handler getStackProfile];
 *    // 包含所有堆栈的调用树，用于可视化分析
 * 
 * ============================================================================
 */

#import "WCMainThreadHandler.h"
#import <pthread.h>
#import "MatrixLogDef.h"
#import "WCLagStackTracePoolUtil.h"
#import "WCGetCallStackReportHandler.h"

#define STACK_PER_MAX_COUNT 100 // the max address count of one stack

/**
 * WCMainThreadHandler 类扩展
 * 
 * 主线程堆栈处理器，负责管理主线程堆栈的循环数组
 * 核心功能：
 * 1. 使用循环数组保存周期性采集的主线程堆栈
 * 2. 通过重复次数分析找出最有可能导致卡顿的堆栈
 * 3. 生成堆栈Profile报告
 */
@interface WCMainThreadHandler () {
    // ============================================================================
    // 线程安全
    // ============================================================================
    pthread_mutex_t m_threadLock;  // 线程锁，保护循环数组的并发访问
    
    // ============================================================================
    // 循环数组配置
    // ============================================================================
    int m_cycleArrayCount;  // 循环数组大小（堆栈个数）
    
    // ============================================================================
    // 主线程堆栈循环数组
    // ============================================================================
    /**
     * 循环数组结构：
     * m_mainThreadStackCycleArray: 二维数组，保存多个堆栈
     *   - 第一维：堆栈索引 [0, m_cycleArrayCount)
     *   - 第二维：堆栈地址数组 uintptr_t[]
     * 
     * m_mainThreadStackCount: 每个堆栈的深度（地址数量）
     * 
     * m_tailPoint: 循环数组的尾指针，指向下一个要写入的位置
     */
    uintptr_t **m_mainThreadStackCycleArray;  // 堆栈循环数组（二维数组）
    size_t *m_mainThreadStackCount;  // 每个堆栈的深度数组
    uint64_t m_tailPoint;  // 循环数组尾指针
    
    // ============================================================================
    // 堆栈分析数据
    // ============================================================================
    /**
     * ========================================================================
     * m_topStackAddressRepeatArray: 栈顶地址连续重复次数数组
     * ========================================================================
     * 
     * 作用：记录每个堆栈栈顶地址的连续重复次数
     * 
     * 原理：
     * - 如果连续多次采集到相同的栈顶地址，说明主线程一直卡在这个函数上
     * - 重复次数最多的堆栈，就是最有可能导致卡顿的堆栈（Point Stack）
     * 
     * 数据结构：
     * - 数组长度：m_cycleArrayCount（循环数组大小，例如20）
     * - 元素类型：size_t
     * - 索引含义：对应循环数组的索引
     * - 元素含义：该位置堆栈的栈顶地址连续重复次数
     * 
     * 示例：[0, 1, 2, 0, 1]
     * - 索引0：栈顶第一次出现，重复0次
     * - 索引1：栈顶与前一个相同，重复1次
     * - 索引2：栈顶与前一个相同，重复2次（连续3次出现）
     * - 索引3：栈顶改变，重复0次
     * - 索引4：栈顶与前一个相同，重复1次
     * 
     * ========================================================================
     * m_mainThreadStackRepeatCountArray: Point Stack 地址总重复次数数组
     * ========================================================================
     * 
     * 作用：记录 Point Stack 中每个地址在所有堆栈中的总出现次数
     * 
     * 原理：
     * - 统计 Point Stack 的每个地址在循环数组所有堆栈中出现的总次数
     * - 出现次数越多，说明这个函数调用越频繁，越可能是性能瓶颈
     * 
     * 数据结构：
     * - 数组长度：Point Stack 的深度（动态，通常 < 100）
     * - 元素类型：int
     * - 索引含义：对应 Point Stack 的第几个地址（0=栈底，n=栈顶）
     * - 元素含义：该地址在所有堆栈中的总出现次数
     * 
     * 示例：[20, 20, 15, 8]
     * - 索引0（栈底，如main）：在所有20个堆栈中都出现
     * - 索引1（如viewDidLoad）：在所有20个堆栈中都出现
     * - 索引2（如heavyWork）：在15个堆栈中出现 ← 可能的瓶颈
     * - 索引3（栈顶）：只在8个堆栈中出现
     * 
     * 生命周期：
     * - 在调用 getPointStackCursor 时动态分配和计算
     * - 每次调用时先释放旧数据，再分配新内存
     * - 在 dealloc 时释放
     * 
     * 用途：
     * - 生成卡顿报告时附加此数据
     * - 用于火焰图生成
     * - 帮助识别真正的性能热点
     */
    size_t *m_topStackAddressRepeatArray;  // 栈顶地址连续重复次数数组
    int *m_mainThreadStackRepeatCountArray;  // Point Stack中每个地址的总重复次数（动态数组的首地址）
}

@end

@implementation WCMainThreadHandler

/**
 * 初始化主线程堆栈处理器
 * 
 * @param cycleArrayCount 循环数组大小
 *        例如：如果检查周期为1000ms，堆栈采集间隔为50ms
 *        则 cycleArrayCount = 1000/50 = 20
 *        即：一个检查周期内会采集20个堆栈
 * 
 * @return 初始化后的实例
 */
- (id)initWithCycleArrayCount:(int)cycleArrayCount {
    self = [super init];
    if (self) {
        m_cycleArrayCount = cycleArrayCount;

        // ============================================================================
        // 1. 分配堆栈循环数组内存（二维数组的第一维）
        // ============================================================================
        size_t cycleArrayBytes = m_cycleArrayCount * sizeof(uintptr_t *);
        m_mainThreadStackCycleArray = (uintptr_t **)malloc(cycleArrayBytes);
        if (m_mainThreadStackCycleArray != NULL) {
            memset(m_mainThreadStackCycleArray, 0, cycleArrayBytes);  // 初始化为NULL
        }
        
        // ============================================================================
        // 2. 分配堆栈深度数组内存
        // ============================================================================
        size_t countArrayBytes = m_cycleArrayCount * sizeof(size_t);
        m_mainThreadStackCount = (size_t *)malloc(countArrayBytes);
        if (m_mainThreadStackCount != NULL) {
            memset(m_mainThreadStackCount, 0, countArrayBytes);
        }
        
        // ============================================================================
        // 3. 分配栈顶地址重复次数数组内存
        // ============================================================================
        size_t addressArrayBytes = m_cycleArrayCount * sizeof(size_t);
        m_topStackAddressRepeatArray = (size_t *)malloc(addressArrayBytes);
        if (m_topStackAddressRepeatArray != NULL) {
            memset(m_topStackAddressRepeatArray, 0, addressArrayBytes);
        }

        // ============================================================================
        // 4. 初始化循环数组尾指针
        // ============================================================================
        m_tailPoint = 0;

        // ============================================================================
        // 5. 初始化线程锁
        // ============================================================================
        pthread_mutex_init(&m_threadLock, NULL);

        MatrixInfo(@"WCMainThreadHandler (cycle count %d) is initialized.", m_cycleArrayCount);
    }
    return self;
}

- (id)init {
    return [self initWithCycleArrayCount:10];
}

- (void)dealloc {
    pthread_mutex_destroy(&m_threadLock);

    for (uint32_t i = 0; i < m_cycleArrayCount; i++) {
        if (m_mainThreadStackCycleArray[i] != NULL) {
            free(m_mainThreadStackCycleArray[i]);
            m_mainThreadStackCycleArray[i] = NULL;
        }
    }

    if (m_mainThreadStackCycleArray != NULL) {
        free(m_mainThreadStackCycleArray);
        m_mainThreadStackCycleArray = NULL;
    }

    if (m_mainThreadStackCount != NULL) {
        free(m_mainThreadStackCount);
        m_mainThreadStackCount = NULL;
    }

    if (m_topStackAddressRepeatArray != NULL) {
        free(m_topStackAddressRepeatArray);
        m_topStackAddressRepeatArray = NULL;
    }

    if (m_mainThreadStackRepeatCountArray != NULL) {
        free(m_mainThreadStackRepeatCountArray);
        m_mainThreadStackRepeatCountArray = NULL;
    }

    MatrixInfo(@"WCMainThreadHandler (cycle count %d) is deallocated.", m_cycleArrayCount);
}

/**
 * 添加主线程堆栈到循环数组
 * 
 * 循环数组原理：
 * - 数组大小固定为 m_cycleArrayCount
 * - 使用尾指针 m_tailPoint 指向下一个写入位置
 * - 当数组满时，覆盖最旧的数据（FIFO）
 * 
 * 栈顶重复次数统计：
 * - 比较当前堆栈和上一个堆栈的栈顶地址
 * - 如果相同，重复次数 = 上一次重复次数 + 1
 * - 如果不同，重复次数 = 0
 * - 这样可以找出连续重复次数最多的堆栈（最可能导致卡顿）
 * 
 * @param stackArray 堆栈地址数组（调用者分配的内存，此方法接管ownership）
 * @param stackCount 堆栈深度
 */
- (void)addThreadStack:(uintptr_t *)stackArray andStackCount:(size_t)stackCount {
    if (stackArray == NULL) {
        return;
    }

    if (m_mainThreadStackCycleArray == NULL || m_mainThreadStackCount == NULL) {
        return;
    }

    pthread_mutex_lock(&m_threadLock);

    // ============================================================================
    // 1. 将堆栈写入循环数组
    // ============================================================================
    
    // 如果当前位置已有堆栈，先释放旧的
    if (m_mainThreadStackCycleArray[m_tailPoint] != NULL) {
        free(m_mainThreadStackCycleArray[m_tailPoint]);
    }
    
    // 保存新堆栈
    m_mainThreadStackCycleArray[m_tailPoint] = stackArray;
    m_mainThreadStackCount[m_tailPoint] = stackCount;

    // ============================================================================
    // 2. 统计栈顶地址连续重复次数
    // ============================================================================
    
    // 计算上一个位置的索引（循环数组）
    uint64_t lastTailPoint = (m_tailPoint + m_cycleArrayCount - 1) % m_cycleArrayCount;
    
    // 获取上一个堆栈的栈顶地址
    uintptr_t lastTopStack = 0;
    if (m_mainThreadStackCycleArray[lastTailPoint] != NULL) {
        lastTopStack = m_mainThreadStackCycleArray[lastTailPoint][0];
    }
    
    // 获取当前堆栈的栈顶地址
    uintptr_t currentTopStackAddr = stackArray[0];
    
    // 比较栈顶地址
    if (lastTopStack == currentTopStackAddr) {
        // 栈顶地址相同，累加重复次数
        size_t lastRepeatCount = m_topStackAddressRepeatArray[lastTailPoint];
        m_topStackAddressRepeatArray[m_tailPoint] = lastRepeatCount + 1;
    } else {
        // 栈顶地址不同，重置重复次数
        m_topStackAddressRepeatArray[m_tailPoint] = 0;
    }

    // ============================================================================
    // 3. 移动尾指针
    // ============================================================================
    
    m_tailPoint = (m_tailPoint + 1) % m_cycleArrayCount;
    
    pthread_mutex_unlock(&m_threadLock);
}

/**
 * 获取最近一次采集的主线程堆栈深度
 * @return 堆栈深度（地址数量）
 */
- (size_t)getLastMainThreadStackCount {
    // 计算最后一个有效位置的索引（尾指针的前一个位置）
    uint64_t lastPoint = (m_tailPoint + m_cycleArrayCount - 1) % m_cycleArrayCount;
    return m_mainThreadStackCount[lastPoint];
}

/**
 * 获取最近一次采集的主线程堆栈
 * @return 堆栈地址数组指针
 */
- (uintptr_t *)getLastMainThreadStack {
    // 计算最后一个有效位置的索引（尾指针的前一个位置）
    uint64_t lastPoint = (m_tailPoint + m_cycleArrayCount - 1) % m_cycleArrayCount;
    return m_mainThreadStackCycleArray[lastPoint];
}

/**
 * 获取堆栈Profile（调用树）
 * 
 * Profile原理：
 * - 将循环数组中的所有堆栈合并成一棵调用树
 * - 统计每个函数调用在所有堆栈中出现的次数
 * - 生成类似火焰图的数据结构
 * 
 * 用途：
 * - 可视化展示主线程在各个函数上的耗时分布
 * - 找出最耗时的调用路径
 * 
 * @return JSON格式的Profile数据（char*），调用者需要负责释放
 */
- (char *)getStackProfile {
    // 1. 将堆栈循环数组构建成调用树
    NSArray<NSDictionary *>* callTree = [WCLagStackTracePoolUtil makeCallTreeWithStackCyclePool:m_mainThreadStackCycleArray 
                                                                                      stackCount:m_mainThreadStackCount 
                                                                               maxStackTraceCount:m_cycleArrayCount];
    
    // 2. 将调用树序列化为JSON
    NSData *callTreeData = [WCGetCallStackReportHandler getReportJsonDataWithLagProfileStack:callTree];
    
    // 3. 复制数据到C内存（供KSCrash使用）
    NSUInteger len = callTreeData.length;
    void *copyCallTreeData = malloc(len);
    if (copyCallTreeData != NULL) {
        [callTreeData getBytes:copyCallTreeData length:len];
    }
    return (char *)copyCallTreeData;
}

/**
 * 获取最有可能导致卡顿的堆栈（Point Stack）
 * 
 * ============================================================================
 * 算法原理：
 * ============================================================================
 * 1. 找出栈顶地址连续重复次数最多的堆栈
 *    - 重复次数越多，说明主线程在这个函数上停留的时间越长
 *    - 这就是最有可能导致卡顿的堆栈
 * 
 * 2. 计算该堆栈中每个地址在所有堆栈中的总出现次数
 *    - 出现次数越多，说明这个函数调用越频繁
 *    - 有助于在堆栈符号化后，识别最耗时的函数
 * 
 * ============================================================================
 * 简单示例：
 * ============================================================================
 * 假设循环数组中有5个堆栈，栈顶地址和重复次数如下：
 * 
 * 索引:    0    1    2    3    4
 * 栈顶:    A    A    A    B    B
 * 重复:    0    1    2    0    1
 * 
 * 分析：
 * - Index=2 的重复次数最大（=2）
 * - 说明栈顶地址A连续出现了3次（索引0,1,2）
 * - 所以Index=2就是Point Stack
 * 
 * ============================================================================
 * 核心要点总结：
 * ============================================================================
 * 
 * 1️⃣ 循环数组的结构：
 *    - m_tailPoint 指向下一个要写入的位置（空位）
 *    - 最新数据在 (m_tailPoint - 1) 的位置
 *    - 数组会回绕，需要用模运算处理索引
 * 
 * 2️⃣ 为什么要从最新往最旧找？
 *    - 如果有多个位置重复次数相同，优先返回最新的
 *    - 最新的数据更能反映当前的卡顿状态
 * 
 * 3️⃣ 索引计算公式：
 *    trueIndex = (m_tailPoint + m_cycleArrayCount - i - 1) % m_cycleArrayCount
 *    
 *    - i=0: 最新的堆栈
 *    - i=1: 次新的堆栈
 *    - i=2: 第三新的堆栈
 *    - ...
 * 
 * 4️⃣ 为什么加 m_cycleArrayCount？
 *    - 防止负数：当 m_tailPoint - i - 1 < 0 时会出现负数
 *    - C语言的 % 对负数处理不友好，加上数组大小确保结果为正
 *    - 例如：(-1 % 5) 可能是 -1，但 (4 % 5) = 4（正确）
 * 
 * @return Point Stack的KSStackCursor指针，失败返回NULL
 */
- (KSStackCursor *)getPointStackCursor {
    pthread_mutex_lock(&m_threadLock);
    
    // ============================================================================
    // 1. 查找栈顶地址连续重复次数的最大值
    // ============================================================================
    
    /**
     * 为什么要分两次遍历？
     * 
     * 问题：为什么不在这次遍历时直接记录索引？
     * 
     * 答案：因为这次遍历的顺序和我们需要的顺序不同！
     * 
     * ============================================================================
     * 关键原因：可能有多个位置的重复次数都等于最大值
     * ============================================================================
     * 
     * 举例说明（假设 cycleArrayCount = 5, m_tailPoint = 1）：
     * 
     * 索引:        0      1      2      3      4
     *            ┌──────┬──────┬──────┬──────┬──────┐
     * 重复次数:   │  3   │  0   │  1   │  3   │  2   │
     *            └──────┴───▲──┴──────┴──────┴──────┘
     *                       │
     *                  m_tailPoint
     * 
     * 时间顺序:   最新   空位   最旧  第三旧  次旧
     *            S9           S5    S6    S7
     * 
     * 第一次遍历（按数组索引 0→4）：
     * - i=0: currentValue=3, maxValue=3 ✓ 记录
     * - i=1: currentValue=0, 不更新
     * - i=2: currentValue=1, 不更新
     * - i=3: currentValue=3, maxValue=3 ✓ 记录（覆盖）
     * - i=4: currentValue=2, 不更新
     * - 结果：maxValue=3, 最后记录的索引=3
     * 
     * 问题出现了！
     * - 索引0（S9）是最新的堆栈，重复次数=3
     * - 索引3（S6）是第三旧的堆栈，重复次数=3
     * - 如果直接记录索引，会得到索引3（较旧）
     * - 但我们应该返回索引0（最新）✓
     * 
     * ============================================================================
     * 为什么要优先返回最新的？
     * ============================================================================
     * 
     * 1. 更准确：最新的数据更能反映当前的卡顿状态
     * 2. 时效性：旧的重复次数可能是之前的卡顿，已经恢复了
     * 3. 避免干扰：防止历史数据影响当前分析
     * 
     * ============================================================================
     * 解决方案：分两次遍历
     * ============================================================================
     * 
     * 第一次：按数组索引遍历，只找最大值（不记录索引）
     * 第二次：按时间顺序遍历（从新到旧），找第一个等于最大值的
     * 
     * 这样就能保证返回的是最新的、重复次数最多的堆栈！
     * 
     * ============================================================================
     * 性能考虑：
     * ============================================================================
     * 
     * - 虽然遍历了两次，但数组很小（通常20个元素）
     * - 总复杂度 O(2n) = O(n)，可以接受
     * - 相比直接记录索引多了一次遍历，但换来了正确的结果
     * 
     * ============================================================================
     * 为什么"遇到相等就更新索引"仍然不行？  **因为数组是循环的，时间顺序和遍历顺序不同**
     * ============================================================================
     * 
     * ❌ 错误写法1（只在 > 时更新）：
     * size_t maxValue = 0;
     * size_t maxIndex = 0;
     * for (int i = 0; i < m_cycleArrayCount; i++) {
     *     if (m_topStackAddressRepeatArray[i] > maxValue) {
     *         maxValue = m_topStackAddressRepeatArray[i];
     *         maxIndex = i;  // 只在严格大于时更新
     *     }
     * }
     * // 问题：如果有多个相等的最大值，只记录第一个（索引小的）
     * 
     * ❌ 错误写法2（在 >= 时更新）：
     * size_t maxValue = 0;
     * size_t maxIndex = 0;
     * for (int i = 0; i < m_cycleArrayCount; i++) {
     *     if (m_topStackAddressRepeatArray[i] >= maxValue) {
     *         maxValue = m_topStackAddressRepeatArray[i];
     *         maxIndex = i;  // 遇到相等也更新，记录最后一个
     *     }
     * }
     * 
     * 具体例子说明问题：
     * 
     * 索引:        0      1      2      3      4
     *            ┌──────┬──────┬──────┬──────┬──────┐
     * 重复次数:   │  3   │  0   │  1   │  3   │  2   │
     *            └──────┴───▲──┴──────┴──────┴──────┘
     *                       │
     *                  m_tailPoint = 1
     * 
     * 时间顺序:   S9(新)  空   S5(旧) S6     S7
     *            0            2      3      4
     * 
     * 按索引遍历（0→1→2→3→4）：
     * i=0: value=3, maxValue=3, maxIndex=0 ✓
     * i=1: value=0, 跳过
     * i=2: value=1, 跳过
     * i=3: value=3, maxValue=3, maxIndex=3 ✓ (遇到相等，更新！)
     * i=4: value=2, 跳过
     * 
     * 结果：maxIndex = 3（对应S6）
     * 
     * 问题：虽然你记录到了"数组索引最大"的那个（索引3）
     *      但索引3对应的是S6（第三旧的堆栈）❌
     *      而我们需要的是索引0对应的S9（最新的堆栈）✓
     * 
     * ============================================================================
     * 核心问题：数组的物理顺序 ≠ 时间的逻辑顺序
     * ============================================================================
     * 
     * 数组索引顺序:  0 → 1 → 2 → 3 → 4  (物理排列)
     * 时间逻辑顺序:  0 → 4 → 3 → 2 → 1  (从新到旧)
     *              新   次  第  旧  空
     *                      三
     *                      旧
     * 
     * 即使你在遇到相等时更新索引，你更新到的也是：
     * "数组索引顺序上最后一个最大值" （索引3）
     * 
     * 而不是：
     * "时间顺序上最新的最大值" （索引0）✓
     * 
     * ============================================================================
     * 再举一个更明显的例子：
     * ============================================================================
     * 
     * 索引:        0      1      2      3      4
     *            ┌──────┬──────┬──────┬──────┬──────┐
     * 重复次数:   │  5   │  0   │  5   │  5   │  5   │
     *            └──────┴───▲──┴──────┴──────┴──────┘
     *                       │
     *                  m_tailPoint = 1
     * 
     * 时间顺序:   S9(新)  空   S5(旧) S6     S7
     *            0            2      3      4
     * 
     * 按索引遍历并在 >= 时更新：
     * i=0: value=5, maxIndex=0
     * i=2: value=5, maxIndex=2 (更新)
     * i=3: value=5, maxIndex=3 (更新)
     * i=4: value=5, maxIndex=4 (更新)
     * 
     * 最终：maxIndex = 4（对应S7，次旧的）❌
     * 应该：maxIndex = 0（对应S9，最新的）✓
     * 
     * ============================================================================
     * ✓ 正确的解决方案：
     * ============================================================================
     * 
     * 第一次遍历：找最大值（不关心索引）
     * 第二次遍历：按时间顺序（从新到旧）找第一个等于最大值的索引
     * 
     * 这样才能保证找到的是"时间上最新的、重复次数最多的堆栈"
     * 
     * ============================================================================
     */
    
    size_t maxValue = 0;
    BOOL trueStack = NO;
    
    // 第一次遍历：只找最大重复次数（按数组索引顺序，不关心时间顺序）
    for (int i = 0; i < m_cycleArrayCount; i++) {
        size_t currentValue = m_topStackAddressRepeatArray[i];
        if (currentValue >= maxValue) {
            maxValue = currentValue;
            trueStack = YES;
        }
    }

    // 如果没有找到有效的堆栈，返回NULL
    if (!trueStack) {
        pthread_mutex_unlock(&m_threadLock);
        return NULL;
    }

    // ============================================================================
    // 2. 找出重复次数等于最大值的堆栈索引
    // ============================================================================
    
    /**
     * 循环数组索引计算详解：
     * 
     * 前提知识：
     * - m_tailPoint 指向下一个要写入的位置（尚未写入）
     * - 最新的堆栈在 m_tailPoint 的前一个位置
     * - 这是一个循环数组，索引会回绕
     * 
     * 举例说明（假设 cycleArrayCount = 5）：
     * 
     * 场景1：m_tailPoint = 3
     * ┌───┬───┬───┬───┬───┐
     * │ 0 │ 1 │ 2 │ 3 │ 4 │  ← 数组索引
     * ├───┼───┼───┼───┼───┤
     * │ S0│ S1│ S2│   │   │  ← 堆栈（S = Stack）
     * └───┴───┴───┴─▲─┴───┘
     *                │
     *           m_tailPoint (下一个要写入的位置)
     * 
     * 最新的堆栈：S2（索引=2）
     * 遍历顺序：2 -> 1 -> 0 -> 4 -> 3（从新到旧）
     * 
     * 场景2：m_tailPoint = 1（数组已回绕）
     * ┌───┬───┬───┬───┬───┐
     * │ 0 │ 1 │ 2 │ 3 │ 4 │  ← 数组索引
     * ├───┼───┼───┼───┼───┤
     * │ S5│   │ S1│ S2│ S3│  ← 堆栈
     * └───┴─▲─┴───┴───┴───┘
     *        │
     *   m_tailPoint
     * 
     * 最新的堆栈：S5（索引=0）= (1-1+5)%5 = 0
     * 遍历顺序：0 -> 4 -> 3 -> 2 -> 1（从新到旧）
     * 
     * 索引计算公式：
     * trueIndex = (m_tailPoint - i - 1 + m_cycleArrayCount) % m_cycleArrayCount
     * 
     * 为什么要加 m_cycleArrayCount？
     * - 防止出现负数（当 m_tailPoint - i - 1 < 0 时）
     * - C/C++ 的负数模运算结果可能是负数，需要保证结果为正
     * 
     * 逐步推导：
     * i=0: trueIndex = (m_tailPoint - 0 - 1 + cycleArrayCount) % cycleArrayCount
     *                = (m_tailPoint - 1 + cycleArrayCount) % cycleArrayCount
     *                → 最新堆栈的索引
     * 
     * i=1: trueIndex = (m_tailPoint - 1 - 1 + cycleArrayCount) % cycleArrayCount
     *                = (m_tailPoint - 2 + cycleArrayCount) % cycleArrayCount
     *                → 次新堆栈的索引
     * 
     * i=2: trueIndex = (m_tailPoint - 3 + cycleArrayCount) % cycleArrayCount
     *                → 第三新堆栈的索引
     * ...
     */
    
    /**
     * ============================================================================
     * 索引计算可视化（假设 cycleArrayCount = 5, m_tailPoint = 1）
     * ============================================================================
     * 
     *   实际索引:   0      1      2      3      4
     *             ┌──────┬──────┬──────┬──────┬──────┐
     *   数据:      │  S9  │      │  S5  │  S6  │  S7  │
     *             └──────┴───▲──┴──────┴──────┴──────┘
     *                        │
     *                   m_tailPoint
     * 
     *   时间顺序:   最新    空位    最旧   第三旧  次旧
     *              ←─────────────────────────────────
     *                    遍历方向（从新到旧）
     * 
     *   i=0: trueIndex = (1+5-0-1)%5 = 5%5 = 0  → 索引0（S9，最新）
     *   i=1: trueIndex = (1+5-1-1)%5 = 4%5 = 4  → 索引4（S7，次新）
     *   i=2: trueIndex = (1+5-2-1)%5 = 3%5 = 3  → 索引3（S6，第三新）
     *   i=3: trueIndex = (1+5-3-1)%5 = 2%5 = 2  → 索引2（S5，最旧）
     *   i=4: trueIndex = (1+5-4-1)%5 = 1%5 = 1  → 索引1（空位，跳过）
     * 
     * ============================================================================
     * 口诀：从尾指针往前数，遇到起点就回绕
     * ============================================================================
     */
    
    /**
     * 第二次遍历的关键作用：
     * - 按照时间顺序（从新到旧）查找
     * - 找第一个重复次数 = maxValue 的堆栈
     * - 这样保证返回的是最新的、重复次数最多的堆栈
     */
    
    // 初始化为最新堆栈的索引（这一行其实可以省略，因为循环会覆盖它）
    size_t currentIndex = (m_tailPoint + m_cycleArrayCount - 1) % m_cycleArrayCount;
    
    // 第二次遍历：按时间顺序（从新到旧）找出第一个重复次数等于 maxValue 的堆栈
    for (int i = 0; i < m_cycleArrayCount; i++) {
        // 计算真实索引：从 m_tailPoint 往前数第 (i+1) 个位置
        // 公式拆解：
        // 1. m_tailPoint - i - 1  ← 往前数第(i+1)个位置（可能为负）
        // 2. + m_cycleArrayCount  ← 加上数组大小，确保为正
        // 3. % m_cycleArrayCount  ← 取模，处理回绕
        int trueIndex = (m_tailPoint + m_cycleArrayCount - i - 1) % m_cycleArrayCount;
        
        // 如果找到重复次数等于最大值的堆栈
        if (m_topStackAddressRepeatArray[trueIndex] == maxValue) {
            currentIndex = trueIndex;
            break;  // 找到第一个（最新的）重复次数最多的堆栈，立即停止
        }
    }

    /**
     * ============================================================================
     * 完整示例：假设 cycleArrayCount = 5, m_tailPoint = 1
     * ============================================================================
     * 
     * 循环数组当前状态：
     * 
     * 索引:    0     1     2     3     4
     *        ┌─────┬─────┬─────┬─────┬─────┐
     * 堆栈:   │ S9  │     │ S5  │ S6  │ S7  │
     *        └─────┴──▲──┴─────┴─────┴─────┘
     *                 │
     *            m_tailPoint (下一个要写入S10的位置)
     * 
     * 栈顶地址:  C           A     A     B
     * 
     * 重复次数:  0           0     1     0
     *        └─────┴─────┴─────┴─────┴─────┘
     * 
     * 时间顺序: S5 -> S6 -> S7 -> S9 (S9是最新的)
     * 
     * 分析：
     * - 最大重复次数 maxValue = 1（索引3的位置）
     * - 我们要找到重复次数为1的堆栈
     * 
     * 遍历过程：
     * 
     * i=0: trueIndex = (1 + 5 - 0 - 1) % 5 = 5 % 5 = 0
     *      → 检查索引0（S9，最新）：重复次数=0，不匹配
     * 
     * i=1: trueIndex = (1 + 5 - 1 - 1) % 5 = 4 % 5 = 4
     *      → 检查索引4（S7，次新）：重复次数=0，不匹配
     * 
     * i=2: trueIndex = (1 + 5 - 2 - 1) % 5 = 3 % 5 = 3
     *      → 检查索引3（S6，第三新）：重复次数=1，匹配！✓
     *      → currentIndex = 3, break
     * 
     * 结果：找到 Point Stack 在索引3的位置，即 S6
     * 
     * 为什么S6是Point Stack？
     * - S6的栈顶地址是A，它和前一个堆栈（S5，索引2）的栈顶地址相同
     * - 说明主线程连续2次采样都在函数A上
     * - S6的重复次数=1（表示这是第2次重复，从0开始计数）
     * - 这是重复次数最多的堆栈，所以是最可能导致卡顿的堆栈
     * 
     * ============================================================================
     * 为什么要从最新往最旧找？
     * ============================================================================
     * 
     * 假设有两个位置的重复次数都是最大值：
     * - 索引2: 重复次数=3（较旧的数据）
     * - 索引4: 重复次数=3（较新的数据）
     * 
     * 我们优先返回较新的那个（索引4），因为：
     * 1. 更能反映当前的卡顿状态
     * 2. 避免被旧数据干扰
     * ============================================================================
     */
    
    // ============================================================================
    // 3. 复制Point Stack
    // ============================================================================
    
    size_t stackCount = m_mainThreadStackCount[currentIndex];
    size_t pointThreadSize = sizeof(uintptr_t) * stackCount;
    uintptr_t *pointThreadStack = (uintptr_t *)malloc(pointThreadSize);

    // ============================================================================
    // 4. 计算Point Stack中每个地址的总重复次数
    // ============================================================================
    
    
    
    // 先释放旧的重复次数数组（如果存在）
    if (m_mainThreadStackRepeatCountArray != NULL) {
        free(m_mainThreadStackRepeatCountArray);
        m_mainThreadStackRepeatCountArray = NULL;
    }
    
    // 分配新的重复次数数组
    // 数组长度 = Point Stack 的深度
    size_t repeatCountArrayBytes = stackCount * sizeof(int);
    m_mainThreadStackRepeatCountArray = (int *)malloc(repeatCountArrayBytes);
    if (m_mainThreadStackRepeatCountArray != NULL) {
        memset(m_mainThreadStackRepeatCountArray, 0, repeatCountArrayBytes);
    }

    // ============================================================================
    // 三层循环统计算法：
    // ============================================================================
    /**
     * 算法目标：统计 Point Stack 中每个地址在所有堆栈中的总出现次数
     * 
     * 时间复杂度：O(n * m * k)
     * - n = Point Stack 的深度（通常 < 100）
     * - m = 循环数组大小（通常 20）
     * - k = 平均堆栈深度（通常 < 50）
     * 
     * 虽然是三层循环，但实际数据量很小，性能可接受
     */
    
    // 外层循环：遍历Point Stack的每个地址
    for (size_t i = 0; i < stackCount; i++) {
        // 取出 Point Stack 的第 i 个地址
        uintptr_t targetAddress = m_mainThreadStackCycleArray[currentIndex][i];
        
        // 中层循环：遍历循环数组中的每个堆栈
        for (int innerIndex = 0; innerIndex < m_cycleArrayCount; innerIndex++) {
            size_t innerStackCount = m_mainThreadStackCount[innerIndex];
            
            // 内层循环：遍历当前堆栈的每个地址
            for (size_t idx = 0; idx < innerStackCount; idx++) {
                // 比较：Point Stack的第i个地址 是否等于 当前堆栈的第idx个地址
                if (targetAddress == m_mainThreadStackCycleArray[innerIndex][idx]) {
                    m_mainThreadStackRepeatCountArray[i] += 1;  // 找到匹配，累加计数
                    // 注意：不 break，因为同一个地址可能在同一个堆栈中出现多次（递归调用）
                }
            }
        }
    }

    // ============================================================================
    // 5. 创建KSStackCursor并返回
    // ============================================================================
    
    /**
     * KSStackCursor 是什么？
     * 
     * KSStackCursor 是 KSCrash 库中用于遍历堆栈的标准数据结构。
     * 它不仅包含堆栈数据，还提供了统一的遍历接口。
     * 
     * ============================================================================
     * 为什么需要 KSStackCursor？
     * ============================================================================
     * 
     * 问题：我们已经有了 pointThreadStack（uintptr_t数组），为什么还要转换？
     * 
     * 答案：因为 KSCrash 需要一个标准化的、带上下文的堆栈表示。
     * 
     * ============================================================================
     * KSStackCursor 的结构（简化）：
     * ============================================================================
     * 
     * typedef struct KSStackCursor {
     *     void *context;              // 上下文信息（包含堆栈数组）
     *     bool (*advanceCursor)(struct KSStackCursor*);  // 移动到下一帧的函数指针
     *     bool (*symbolicate)(struct KSStackCursor*);    // 符号化当前帧的函数指针
     *     uintptr_t instructionAddress;   // 当前帧的指令地址
     *     uintptr_t symbolAddress;        // 当前帧的符号地址
     *     const char* symbolName;         // 当前帧的符号名称
     *     // ... 更多字段
     * } KSStackCursor;
     * 
     * ============================================================================
     * 数据转换流程：
     * ============================================================================
     * 
     * 步骤1：原始堆栈地址数组（我们采集的）
     * ┌─────────────────────────────────┐
     * │ pointThreadStack (uintptr_t[])  │
     * │ [0] = 0x1000  ← 栈底            │
     * │ [1] = 0x2000                    │
     * │ [2] = 0x3000  ← 栈顶            │
     * └─────────────────────────────────┘
     * 
     * 步骤2：创建 KSStackCursor
     * ┌──────────────────────────────────┐
     * │ KSStackCursor *pointCursor       │
     * │ ├─ context → 指向 pointThreadStack│
     * │ ├─ advanceCursor → 遍历函数      │
     * │ ├─ symbolicate → 符号化函数      │
     * │ └─ 其他元数据                    │
     * └──────────────────────────────────┘
     * 
     * 步骤3：KSCrash 使用 KSStackCursor
     * ┌──────────────────────────────────┐
     * │ while (cursor->advanceCursor()) {│
     * │   cursor->symbolicate();         │
     * │   printf("%s\n", cursor->symbolName);│
     * │ }                                │
     * └──────────────────────────────────┘
     * 
     * ============================================================================
     * kssc_initWithBacktrace 做了什么？
     * ============================================================================
     * 
     * void kssc_initWithBacktrace(
     *     KSStackCursor *cursor,      // 输出：初始化后的游标
     *     uintptr_t *backtrace,       // 输入：堆栈地址数组
     *     int backtraceLength,        // 输入：堆栈深度
     *     int skipEntries             // 输入：跳过的栈帧数（我们用0）
     * )
     * 
     * 内部操作：
     * 1. 创建上下文结构体（KSStackCursor_Backtrace_Context）
     * 2. 将 backtrace 数组保存到上下文中
     * 3. 设置函数指针：
     *    - advanceCursor = advanceCursor_Backtrace（遍历函数）
     *    - symbolicate = symbolicate_Backtrace（符号化函数）
     * 4. 初始化索引为 skipEntries（0）
     * 5. 设置当前帧的 instructionAddress 为 backtrace[0]
     * 
     * ============================================================================
     * 实际使用示例（在 KSCrash 内部）：
     * ============================================================================
     * 
     * // Matrix 返回 Point Stack
     * KSStackCursor *cursor = kscrash_pointThreadCallback();
     * 
     * // KSCrash 遍历堆栈并符号化
     * int frameIndex = 0;
     * while (cursor->advanceCursor(cursor)) {
     *     // 符号化当前帧
     *     cursor->symbolicate(cursor);
     *     
     *     // 写入报告
     *     fprintf(report, "Frame %d: %s (0x%lx)\n", 
     *             frameIndex++, 
     *             cursor->symbolName ?: "???",
     *             cursor->instructionAddress);
     * }
     * 
     * 输出示例：
     * Frame 0: main (0x100001000)
     * Frame 1: -[AppDelegate application:didFinishLaunchingWithOptions:] (0x100002000)
     * Frame 2: -[ViewController viewDidLoad] (0x100003000)
     * Frame 3: -[ViewController heavyWork] (0x100004000)  ← 卡顿点
     * 
     * ============================================================================
     * 为什么不直接用数组？
     * ============================================================================
     * 
     * 对比：
     * 
     * ❌ 直接用数组：
     * uintptr_t *stack = getStack();
     * // KSCrash 需要：
     * // - 如何遍历？
     * // - 如何知道深度？
     * // - 如何符号化？
     * // - 如何处理不同平台的差异？
     * 
     * ✓ 用 KSStackCursor：
     * KSStackCursor *cursor = getStackCursor();
     * // KSCrash 可以：
     * // - 统一的遍历接口：advanceCursor()
     * // - 自带深度信息：在 context 中
     * // - 统一的符号化接口：symbolicate()
     * // - 封装了平台差异
     * 
     * ============================================================================
     * KSStackCursor 的优势：
     * ============================================================================
     * 
     * 1. 抽象层：
     *    - 隐藏不同平台的堆栈格式差异
     *    - 提供统一的访问接口
     * 
     * 2. 附加信息：
     *    - 不仅有地址，还有符号化后的函数名
     *    - 包含图像名称、偏移量等调试信息
     * 
     * 3. 惰性计算：
     *    - 符号化操作很耗时，通过函数指针可以按需执行
     *    - advanceCursor() 时才移动，不预先处理所有帧
     * 
     * 4. 可扩展性：
     *    - 通过函数指针，可以支持不同类型的堆栈
     *    - 例如：实时堆栈、保存的堆栈、崩溃时的堆栈等
     * 
     * ============================================================================
     * 内存管理注意事项：
     * ============================================================================
     * 
     * pointThreadStack:
     *   - 由本方法分配：malloc(sizeof(uintptr_t) * stackCount)
     *   - 所有权转移给 KSStackCursor
     *   - 调用者使用完后需要释放：
     *     KSStackCursor_Backtrace_Context *ctx = cursor->context;
     *     free(ctx->backtrace);  // 释放 pointThreadStack
     *     free(cursor);          // 释放 cursor 本身
     * 
     * pointCursor:
     *   - 由本方法分配：malloc(sizeof(KSStackCursor))
     *   - 返回给调用者
     *   - 调用者负责释放
     * 
     * ============================================================================
     */
    
    if (pointThreadStack != NULL) {
        memset(pointThreadStack, 0, pointThreadSize);
        
        // 复制 Point Stack 的地址
        for (size_t idx = 0; idx < stackCount; idx++) {
            pointThreadStack[idx] = m_mainThreadStackCycleArray[currentIndex][idx];
        }
        
        // ====================================================================
        // 创建 KSStackCursor（堆栈游标）
        // ====================================================================
        // 
        // 分配 KSStackCursor 结构体内存
        KSStackCursor *pointCursor = (KSStackCursor *)malloc(sizeof(KSStackCursor));
        
        // 初始化 KSStackCursor
        // 参数说明：
        // - pointCursor: 要初始化的游标
        // - pointThreadStack: 堆栈地址数组（将被保存到游标的上下文中）
        // - (int)stackCount: 堆栈深度
        // - 0: 跳过的栈帧数（不跳过任何帧）
        //
        // 这个函数会：
        // 1. 创建上下文结构体并保存 pointThreadStack
        // 2. 设置遍历函数指针（advanceCursor）
        // 3. 设置符号化函数指针（symbolicate）
        // 4. 初始化游标位置到第一帧
        kssc_initWithBacktrace(pointCursor, pointThreadStack, (int)stackCount, 0);
        
        pthread_mutex_unlock(&m_threadLock);
        
        // 返回 KSStackCursor，供 KSCrash 使用
        // KSCrash 会用这个游标遍历堆栈、符号化地址、生成报告
        return pointCursor;
    }
    
    pthread_mutex_unlock(&m_threadLock);
    return NULL;
    /* Old
     OSSpinLockLock(&m_threadLock);
     uint64_t lastPoint = (m_tailPoint + m_cycleArrayCount - 1) % m_cycleArrayCount;
     uintptr_t *lastStack = m_mainThreadStackCycleArray[lastPoint];
     uint64_t lastStackCount = m_mainThreadStackCount[lastPoint];
     if (lastStack == NULL || lastStackCount == 0) {
     return NULL;
     }
     
     uint32_t maxRepeatCount = 0;
     size_t maxIdx = 0;
     for (size_t idx = 0; idx < lastStackCount; idx++) {
     uintptr_t addr = lastStack[idx];
     uint32_t currentRepeat = [self p_findRepeatCountInArrayWithAddr:addr];
     if (currentRepeat > maxRepeatCount) {
     maxIdx = idx;
     maxRepeatCount = currentRepeat;
     }
     }
     
     size_t pointThreadCount = lastStackCount - maxIdx;
     uintptr_t *pointThreadStack = (uintptr_t *)malloc(sizeof(uintptr_t) * pointThreadCount);
     size_t filterCount = lastStackCount - pointThreadCount;
     if (pointThreadStack != NULL) {
     memset(pointThreadStack, 0, pointThreadCount);
     for (size_t idx = 0; idx < pointThreadCount; idx++) {
     pointThreadStack[idx] = lastStack[idx + filterCount];
     }
     KSStackCursor *pointCursor = (KSStackCursor *)malloc(sizeof(KSStackCursor));
     kssc_initWithBacktrace(pointCursor, pointThreadStack, (int)pointThreadCount, 0);
     OSSpinLockUnlock(&m_threadLock);
     return pointCursor;
     }
     OSSpinLockUnlock(&m_threadLock);
     return NULL;*/
}

/**
 * 获取 Point Stack 中每个地址的重复次数数组
 * 
 * 返回 m_mainThreadStackRepeatCountArray，这个数组记录了 Point Stack 中
 * 每个地址在所有堆栈中的总出现次数。
 * 
 * 使用场景：
 * - 在生成卡顿报告时，将此数据附加到报告中
 * - 供 KSCrash 使用，生成更详细的堆栈分析
 * 
 * 注意事项：
 * 1. 必须先调用 getPointStackCursor，该方法会计算并填充此数组
 * 2. 数组长度等于 Point Stack 的深度
 * 3. 返回的指针指向内部数组，不要手动释放
 * 4. 数组在下次调用 getPointStackCursor 时会被重新分配和计算
 * 
 * 数据示例：
 * Point Stack:
 *   [0] = 0x1000  → 重复次数: 4
 *   [1] = 0x2000  → 重复次数: 4
 *   [2] = 0x3000  → 重复次数: 3  ← 出现频率较低，可能是卡顿点
 * 
 * @return 重复次数数组指针（int*）
 *         如果尚未调用 getPointStackCursor，可能返回 NULL
 */
- (int *)getPointStackRepeatCount {
    return m_mainThreadStackRepeatCountArray;
}

- (KSStackCursor **)getStackCursorWithLimit:(int)limitCount withReturnSize:(NSUInteger &)stackSize {
    KSStackCursor **allStackCursor = (KSStackCursor **)malloc(sizeof(KSStackCursor *) * limitCount);
    if (allStackCursor == NULL) {
        //        BMDebug(@"allStackCursor == NULL");
        return NULL;
    }
    stackSize = 0;
    pthread_mutex_lock(&m_threadLock);
    for (int i = 0; i < limitCount; i++) {
        uint64_t trueIndex = (m_tailPoint + m_cycleArrayCount - i - 1) % m_cycleArrayCount;
        if (m_mainThreadStackCycleArray[trueIndex] == NULL) {
            MatrixDebug(@"m_mainThreadStackCycleArray == NULL");
            break;
        }
        size_t currentStackCount = m_mainThreadStackCount[trueIndex];
        uintptr_t *currentThreadStack = (uintptr_t *)malloc(sizeof(uintptr_t) * currentStackCount);
        if (currentThreadStack == NULL) {
            MatrixDebug(@"currentThreadStack == NULL");
            break;
        }
        stackSize++;
        for (int j = 0; j < currentStackCount; j++) {
            currentThreadStack[j] = m_mainThreadStackCycleArray[trueIndex][j];
        }
        KSStackCursor *currentStackCursor = (KSStackCursor *)malloc(sizeof(KSStackCursor));
        kssc_initWithBacktrace(currentStackCursor, currentThreadStack, (int)currentStackCount, 0);
        allStackCursor[i] = currentStackCursor;
    }
    pthread_mutex_unlock(&m_threadLock);
    return allStackCursor;
}

/**
 * 获取循环数组中的所有堆栈
 * 
 * 遍历顺序：从最新到最旧
 * - allStackCursor[0]: 最新的堆栈
 * - allStackCursor[1]: 次新的堆栈
 * - ...
 * - allStackCursor[n-1]: 最旧的堆栈
 * 
 * @param stackSize 输出参数，实际返回的堆栈数量
 * @return KSStackCursor数组指针，失败返回NULL
 *         调用者需要负责释放内存
 */
- (KSStackCursor **)getAllStackCursorWithReturnSize:(NSUInteger &)stackSize {
    // 分配KSStackCursor数组
    KSStackCursor **allStackCursor = (KSStackCursor **)malloc(sizeof(KSStackCursor *) * m_cycleArrayCount);
    if (allStackCursor == NULL) {
        return NULL;
    }
    stackSize = 0;

    pthread_mutex_lock(&m_threadLock);
    
    // 从最新到最旧遍历循环数组
    for (int i = 0; i < m_cycleArrayCount; i++) {
        // 计算真实索引（从尾指针往前）
        uint64_t trueIndex = (m_tailPoint + m_cycleArrayCount - i - 1) % m_cycleArrayCount;
        
        // 如果该位置没有堆栈，说明循环数组还没填满，停止遍历
        if (m_mainThreadStackCycleArray[trueIndex] == NULL) {
            MatrixDebug(@"m_mainThreadStackCycleArray == NULL");
            break;
        }
        
        // 复制堆栈
        size_t currentStackCount = m_mainThreadStackCount[trueIndex];
        uintptr_t *currentThreadStack = (uintptr_t *)malloc(sizeof(uintptr_t) * currentStackCount);
        if (currentThreadStack == NULL) {
            MatrixDebug(@"currentThreadStack == NULL");
            break;
        }
        
        stackSize++;  // 累加实际返回的堆栈数
        
        // 复制堆栈地址
        for (int j = 0; j < currentStackCount; j++) {
            currentThreadStack[j] = m_mainThreadStackCycleArray[trueIndex][j];
        }
        
        // 创建KSStackCursor
        KSStackCursor *currentStackCursor = (KSStackCursor *)malloc(sizeof(KSStackCursor));
        kssc_initWithBacktrace(currentStackCursor, currentThreadStack, (int)currentStackCount, 0);
        allStackCursor[i] = currentStackCursor;
    }
    
    pthread_mutex_unlock(&m_threadLock);
    return allStackCursor;
}

- (uint32_t)p_findRepeatCountInArrayWithAddr:(uintptr_t)addr {
    uint32_t repeatCount = 0;
    for (size_t idx = 0; idx < m_cycleArrayCount; idx++) {
        uintptr_t *stack = m_mainThreadStackCycleArray[idx];
        repeatCount += [WCMainThreadHandler p_findRepeatCountInStack:stack withAddr:addr];
    }
    return repeatCount;
}

+ (uint32_t)p_findRepeatCountInStack:(uintptr_t *)stack withAddr:(uintptr_t)addr {
    if (stack == NULL) {
        return 0;
    }
    uint32_t repeatCount = 0;
    size_t idx = 0;
    while (stack[idx] != 0 || idx < STACK_PER_MAX_COUNT) {
        if (stack[idx] == addr) {
            repeatCount++;
        }
        idx++;
    }
    return repeatCount;
}

// ============================================================================
#pragma mark - Setting
// ============================================================================

- (size_t)getStackMaxCount {
    return STACK_PER_MAX_COUNT;
}

@end
