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

#import "WCCPUHandler.h"
#import <TargetConditionals.h>

#import <dlfcn.h>
#import <mach/port.h>
#import <mach/kern_return.h>
#import <mach/mach.h>

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import "MatrixLogDef.h"

// ============================================================================
#pragma mark - 常量定义
// ============================================================================

/**
 * CPU阈值（百分比）
 * 超过此值开始追踪CPU使用率，默认80%
 */
static float kOverCPULimit = 80.;

/**
 * CPU检测周期（秒）
 * 需要持续超过此时间才触发报警，默认60秒
 */
static float kOverCPULimitSecLimit = 60.;

/**
 * 退火冷却时间（秒）
 * 触发一次报警后的冷却期，防止频繁上报，默认60秒
 */
static float TICK_TOCK_COUNT = 60.; // 60 seconds

// ============================================================================
#pragma mark - WCCPUHandler 类扩展
// ============================================================================

@interface WCCPUHandler () {
    // ========================================================================
    // 前台CPU检测相关变量
    // ========================================================================
    
    /**
     * 冷却计时器（退火算法）
     * > 0 表示在冷却期，每次检查递减 periodSec
     * <= 0 表示冷却结束，可以重新检测
     */
    float m_tickTok;

    /**
     * 累积的CPU消耗
     * 计算公式：m_totalCPUCost += periodSec * cpuUsage
     * 例如：1秒内CPU 85% -> 累积 0.85
     */
    float m_totalCPUCost;
    
    /**
     * 累积的追踪时间（秒）
     * 记录从开始追踪到当前的总时间
     */
    float m_totalTrackingTime;
    
    /**
     * 是否正在追踪CPU
     * YES：正在追踪，累积CPU消耗
     * NO：未追踪，等待CPU超过阈值
     */
    BOOL m_bTracking;

    // ========================================================================
    // 后台CPU检测相关变量
    // ========================================================================
    
    /**
     * 后台累积的CPU消耗
     * 用于检测后台CPU是否异常低
     */
    float m_backgroundTotalCPU;
    
    /**
     * 后台累积的时间（秒）
     */
    float m_backgroundTotalSec;
    
    /**
     * 当前是否在后台
     * 通过监听UIApplicationDidEnterBackgroundNotification设置
     */
    BOOL m_background;
    
    /**
     * 后台CPU是否过低
     * YES：后台平均CPU < 6%（可能被系统限制）
     * NO：正常
     */
    volatile BOOL m_backgroundCPUTooSmall;
}

@end

@implementation WCCPUHandler

// ============================================================================
#pragma mark - 初始化
// ============================================================================

/**
 * 默认初始化
 * 使用默认CPU阈值80%
 */
- (id)init {
    return [self initWithCPULimit:80.];
}

/**
 * 指定CPU阈值初始化
 * 
 * @param cpuLimit CPU阈值（百分比）
 */
- (id)initWithCPULimit:(float)cpuLimit {
    self = [super init];
    if (self) {
        // 设置CPU阈值
        kOverCPULimit = cpuLimit;

        // 初始化前台CPU检测变量
        m_tickTok = 0;              // 冷却时间为0，可以立即开始检测
        m_bTracking = NO;           // 初始状态：未追踪

        m_totalTrackingTime = 0.;   // 追踪时间清零
        m_totalCPUCost = 0.;        // CPU消耗清零

        // 初始化后台CPU检测变量
        m_background = NO;          // 初始在前台
        m_backgroundTotalCPU = 0.;  // 后台CPU消耗清零
        m_backgroundTotalSec = 0.;  // 后台时间清零
        m_backgroundCPUTooSmall = NO;  // 后台CPU正常

#if !TARGET_OS_OSX
        // 监听前后台切换通知
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

// ============================================================================
#pragma mark - 前后台切换处理
// ============================================================================

/**
 * App即将进入前台
 * 重置后台CPU检测状态
 */
- (void)willEnterForeground {
    m_background = NO;
    m_backgroundCPUTooSmall = NO;
    m_backgroundTotalCPU = 0.;
    m_backgroundTotalSec = 0.;
}

/**
 * App已进入后台
 * 开始后台CPU检测
 */
- (void)didEnterBackground {
    m_background = YES;
    m_backgroundCPUTooSmall = NO;
    m_backgroundTotalCPU = 0.;
    m_backgroundTotalSec = 0.;
}

// ============================================================================
#pragma mark - CPU检测
// ============================================================================

/**
 * 返回后台CPU是否过低
 */
- (BOOL)isBackgroundCPUTooSmall {
    return m_backgroundCPUTooSmall;
}

/**
 * 培养CPU使用率（核心检测算法）
 * 
 * 此方法实现了一个智能的三阶段CPU检测算法：
 * 
 * 阶段1：退火检测（Annealing）
 * - 如果在冷却期（m_tickTok > 0），拒绝检测
 * - 防止短时间内重复上报同一问题
 * 
 * 阶段2：开始追踪（Start Tracking）
 * - 条件：CPU > 阈值 && 未在追踪中
 * - 动作：重置累积变量，进入追踪状态
 * 
 * 阶段3：半区间检测（Half CPU Zone）
 * - 条件：totalCPUCost < kOverCPULimit * totalTrackingTime / 2
 * - 含义：平均CPU < 40%
 * - 动作：停止追踪（过滤假阳性）
 * 
 * 阶段4：完整区间检测（Full CPU Zone）
 * - 条件：追踪时间 >= 60秒
 * - 判断：totalCPUCost > kOverCPULimit * totalTrackingTime
 * - 含义：60秒内平均CPU > 80%
 * - 动作：返回YES，进入60秒冷却期
 * 
 * 运行环境：监控线程（check child thread）
 * 
 * @param cpuUsage 当前CPU使用率（百分比）
 * @param periodSec 距离上次检查的时间间隔（秒）
 * @return YES：检测到持续高CPU，NO：正常
 */
- (BOOL)cultivateCpuUsage:(float)cpuUsage periodTime:(float)periodSec {
    // 同时检测后台CPU
    [self cultivateBackgroundCpu:cpuUsage periodTime:periodSec];

    // ========================================================================
    // 阶段0：参数校验
    // ========================================================================
    if (periodSec < 0 || periodSec > 5.) {
        MatrixDebug(@"abnormal period sec : %f", periodSec);
        return NO;
    }

    // ========================================================================
    // 阶段1：退火算法（Annealing Algorithm）
    // ========================================================================
    // 如果在冷却期，递减冷却时间，拒绝检测
    if (m_tickTok > 0) {
        m_tickTok -= periodSec;  // 冷却时间递减
        if (m_tickTok <= 0) {
            MatrixInfo(@"tick tok over");  // 冷却结束
        }
        return NO;  // 冷却期内不检测
    }

    // ========================================================================
    // 阶段2：开始追踪（Start Tracking）
    // ========================================================================
    // 如果CPU超过阈值且未在追踪，开始追踪
    if (cpuUsage > kOverCPULimit && m_bTracking == NO) {
        MatrixInfo(@"start track cpu usage");
        m_totalCPUCost = 0.;        // 重置累积CPU消耗
        m_totalTrackingTime = 0.;   // 重置累积时间
        m_bTracking = YES;          // 进入追踪状态
    }

    // 如果未在追踪，直接返回
    if (m_bTracking == NO) {
        return NO;
    }

    // ========================================================================
    // 阶段3：累积CPU消耗
    // ========================================================================
    m_totalTrackingTime += periodSec;           // 累加追踪时间
    m_totalCPUCost += periodSec * cpuUsage;     // 累加CPU消耗
    
    // 例如：periodSec=1秒，cpuUsage=85% -> totalCPUCost += 0.85

    // ========================================================================
    // 阶段4：半区间检测（Half CPU Zone）
    // ========================================================================
    // 计算半区间阈值：如果CPU持续在阈值，半区间应该达到的消耗
    // halfCPUZone = 80 * totalTrackingTime / 2 = 40 * totalTrackingTime
    float halfCPUZone = kOverCPULimit * m_totalTrackingTime / 2.;

    // 如果实际消耗 < 半区间阈值，说明平均CPU < 40%
    // 这意味着CPU已经显著下降，停止追踪
    if (m_totalCPUCost < halfCPUZone) {
        MatrixInfo(@"stop track cpu usage");
        m_totalCPUCost = 0.;        // 重置
        m_totalTrackingTime = 0.;   // 重置
        m_bTracking = NO;           // 退出追踪状态
        return NO;
    }

    // ========================================================================
    // 阶段5：完整区间检测（Full CPU Zone）
    // ========================================================================
    // 只有追踪时间 >= 60秒才进行最终判断
    if (m_totalTrackingTime >= kOverCPULimitSecLimit) {
        BOOL exceedLimit = NO;
        
        // 计算完整区间阈值：60秒内如果CPU持续在80%，应该达到的消耗
        // fullCPUZone = 80 * 60 = 4800
        float fullCPUZone = halfCPUZone + halfCPUZone;
        
        // 如果实际消耗 > 完整区间阈值，说明平均CPU > 80%
        if (m_totalCPUCost > fullCPUZone) {
            MatrixInfo(@"exceed cpu limit");
            exceedLimit = YES;
        }

        // 如果超标，触发报警并进入冷却期
        if (exceedLimit) {
            m_totalCPUCost = 0;         // 重置
            m_totalTrackingTime = 0.;   // 重置
            m_bTracking = NO;           // 退出追踪状态
            m_tickTok += TICK_TOCK_COUNT;  // 进入60秒冷却期
        }
        return exceedLimit;  // 返回是否超标
    }

    return NO;  // 追踪时间不足60秒，继续追踪
}

/**
 * 培养后台CPU（检测后台CPU是否过低）
 * 
 * 此方法检测App在后台时CPU是否异常低（< 6%）
 * 这可能表示App被系统严格限制后台执行
 * 
 * 检测逻辑：
 * 1. 累积后台CPU消耗超过5秒
 * 2. 计算平均CPU：cpuPerSec = totalCPU / totalSec
 * 3. 如果平均CPU < 6%，标记为异常
 * 
 * @param cpuUsage 当前CPU使用率（百分比）
 * @param periodSec 时间间隔（秒）
 */
- (void)cultivateBackgroundCpu:(float)cpuUsage periodTime:(float)periodSec {
    // 只在后台时检测
    if (m_background == NO) {
        return;
    }
    
    // 累积超过5秒后进行判断
    if (m_backgroundTotalSec > 4.9) {
        // 计算平均每秒CPU使用率
        float cpuPerSec = m_backgroundTotalCPU / m_backgroundTotalSec;
        MatrixDebug(@"background, cpu per sec: %f", cpuPerSec);
        
        // 如果平均CPU < 6%，认为是异常低
        if (cpuPerSec < 6.) {
            m_backgroundCPUTooSmall = YES;
            m_background = NO;  // 停止后台检测
            MatrixInfo(@"background, cpu per sec: %f, too small, m_backgroundCPUTooSmall: %d", cpuPerSec, m_backgroundCPUTooSmall);
        }
        
        // 重置累积变量，开始新一轮检测
        m_backgroundTotalCPU = 0.;
        m_backgroundTotalSec = 0.;
    }
    
    // 累积CPU消耗
    m_backgroundTotalCPU += cpuUsage * periodSec;
    m_backgroundTotalSec += periodSec;
}

@end
