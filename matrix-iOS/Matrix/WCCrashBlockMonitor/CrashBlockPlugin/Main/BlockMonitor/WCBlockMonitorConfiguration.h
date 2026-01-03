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

#import <Foundation/Foundation.h>

#define BM_MicroFormat_MillSecond 1000
#define BM_MicroFormat_Second 1000000
#define BM_MicroFormat_FrameMillSecond 16000

const static useconds_t g_defaultRunLoopTimeOut = 2 * BM_MicroFormat_Second;
const static useconds_t g_defaultCheckPeriodTime = 1 * BM_MicroFormat_Second;
const static useconds_t g_defaultPerStackInterval = 50 * BM_MicroFormat_MillSecond;
const static float g_defaultCPUUsagePercent = 80.;
const static float g_defaultPowerConsumeCPULimit = 80.;
const static int g_defaultMainThreadCount = 10;
const static int g_defaultFrameDropCount = 8;
const static size_t g_defaultSingleReadLimit = 100 * 1024;
const static size_t g_defaultSingleWriteLimit = 100 * 1024;
const static size_t g_defaultTotalReadLimit = 500 * 1024 * 1024;
const static size_t g_defaultTotalWriteLimit = 200 * 1024 * 1024;
const static uint32_t g_defaultMemoryThresholdInMB = 1024;
const static int g_defaultDumpDailyLimit = 100;

@interface WCBlockMonitorConfiguration : NSObject

+ (id)defaultConfig;

/// define the timeout of the main runloop
@property (nonatomic, assign) useconds_t runloopTimeOut;

/// define the suggested value when lowering the runloop threshold
@property (nonatomic, assign) useconds_t runloopLowThreshold;

/// enable runloop threshold dynamic adjustment
@property (nonatomic, assign) BOOL bRunloopDynamicThreshold;

/// define the checking period of the main runloop
@property (nonatomic, assign) useconds_t checkPeriodTime DEPRECATED_MSG_ATTRIBUTE("depends on runloopTimeOut");

/// enable the main thread handle, whether to handle the main thread to get the most time-consuming stack recently
@property (nonatomic, assign) BOOL bMainThreadHandle;

/// enable the main thread profile, whether to handle the main thread to get all stacks after merging
@property (nonatomic, assign) BOOL bMainThreadProfile;

/// define the interval of the acquire of the main thread stack
@property (nonatomic, assign) useconds_t perStackInterval;

/// define the count of the main thread stack that be saved
@property (nonatomic, assign) uint32_t mainThreadCount DEPRECATED_MSG_ATTRIBUTE("depends on runloopTimeOut");

/**
 * CPU使用率阈值（瞬时检测）
 * 
 * 默认值：80.0（80%）
 * 
 * 说明：
 * - 用于瞬时CPU过高检测
 * - 当App CPU使用率超过此值时，触发onBlockMonitorCurrentCPUTooHigh回调
 * - 注意：这是单核的百分比，不是总CPU
 * - 例如：设置为80，表示单核CPU使用率超过80%时触发
 * 
 * 与核心数的关系：
 * - 如果设备有8个核心，App占用6个核心（600%）
 * - 单核平均：600 / 8 = 75%，不会触发
 * - 如果App占用7个核心（700%），单核平均87.5%，会触发
 * 
 * 建议值：
 * - 开发环境：60-70（更敏感，便于发现问题）
 * - 生产环境：80-90（避免误报）
 * 
 * 使用场景：
 * - 快速捕捉CPU峰值
 * - 实时性能监控
 * - 与bGetCPUHighLog配合生成转储报告
 */
@property (nonatomic, assign) float limitCPUPercent;

/**
 * 是否在日志中打印CPU使用率
 * 
 * 默认值：NO
 * 
 * 说明：
 * - 当此选项开启且CPU > 40%时，会打印日志
 * - 日志包含：App CPU使用率、设备整体CPU使用率
 * - 格式："应用 CPU 使用率: %.2f，设备: %.2f"
 * 
 * 性能影响：
 * - 轻微（仅影响日志输出）
 * 
 * 建议：
 * - 开发环境：YES（便于调试）
 * - 生产环境：NO（减少日志量）
 */
@property (nonatomic, assign) BOOL bPrintCPUUsage;

/**
 * 是否生成CPU高占用的转储报告
 * 
 * 默认值：NO
 * 
 * 说明：
 * - 当瞬时CPU过高时，是否生成EDumpType_CPUBlock类型的转储报告
 * - 需要同时满足以下条件才会生成：
 *   1. bGetCPUHighLog = YES
 *   2. 当前CPU > limitCPUPercent
 *   3. bGetPowerConsumeStack = YES（需要堆栈收集器）
 *   4. isCPUHighBlock返回YES（有采集到高CPU堆栈）
 * 
 * 转储报告包含：
 * - CPU高占用线程的堆栈
 * - 每个线程的CPU使用率
 * - 设备和App的整体CPU使用率
 * - 可以用于符号化和分析
 * 
 * 性能影响：
 * - 中等（生成转储需要暂停线程、采集堆栈）
 * - 建议配合dumpDailyLimit限制每日上报量
 * 
 * 建议：
 * - 开发环境：YES（便于定位CPU问题）
 * - 生产环境：YES（但要设置dumpDailyLimit）
 */
@property (nonatomic, assign) BOOL bGetCPUHighLog;

/**
 * 是否收集耗电堆栈（平均CPU检测）
 * 
 * 默认值：NO
 * 
 * 说明：
 * - 开启后会创建WCPowerConsumeStackCollector
 * - 每次check时，在获取CPU使用率的同时采集高CPU线程的堆栈
 * - 用于WCCPUHandler的平均CPU检测
 * - 当检测到持续高CPU时，生成调用树（Call Tree）
 * 
 * 功能：
 * 1. 实时采集：每次check采集当前高CPU线程的堆栈
 * 2. 堆栈池：维护最近100个堆栈样本
 * 3. 调用树：当触发平均CPU过高时，生成火焰图数据
 * 4. 异步回调：通过powerConsumeStackCollectorConclude回调返回
 * 
 * 与瞬时检测的区别：
 * - 瞬时检测（bGetCPUHighLog）：捕捉瞬间的CPU峰值
 * - 耗电检测（bGetPowerConsumeStack）：分析60秒内的持续高CPU
 * 
 * 性能影响：
 * - 较高（每次check都要遍历线程、采集堆栈）
 * - 只有当CPU > powerConsumeStackCPULimit时才采集，减少开销
 * 
 * 建议：
 * - 开发环境：YES（便于性能优化）
 * - 生产环境：根据需求决定（耗电问题重要时开启）
 */
@property (nonatomic, assign) BOOL bGetPowerConsumeStack;

/**
 * 耗电检测的CPU阈值
 * 
 * 默认值：80.0（80%）
 * 
 * 说明：
 * - 用于WCCPUHandler的平均CPU检测
 * - 用于WCPowerConsumeStackCollector的堆栈采集触发
 * - 当App总CPU超过此值时：
 *   1. WCCPUHandler开始累积CPU消耗
 *   2. WCPowerConsumeStackCollector开始采集堆栈
 * 
 * 与limitCPUPercent的区别：
 * - limitCPUPercent：瞬时检测的阈值（单核百分比）
 * - powerConsumeStackCPULimit：耗电检测的阈值（总CPU百分比）
 * 
 * 检测机制：
 * - 需要在60秒内平均CPU持续超过此值
 * - 使用半区间检测过滤短暂峰值
 * - 触发后进入60秒冷却期
 * 
 * 建议值：
 * - 一般设置：70-80
 * - 省电要求高：60-70
 * - 性能要求高：80-90
 */
@property (nonatomic, assign) float powerConsumeStackCPULimit;

/// enable to filter the same stack in one day, the stack be captured over "triggerToBeFilteredCount" times would be filtered
@property (nonatomic, assign) BOOL bFilterSameStack DEPRECATED_MSG_ATTRIBUTE("use dumpDailyLimit instead");

/// define the count that a stack can be captured in one day, see above "bFilterSameStack"
@property (nonatomic, assign) uint32_t triggerToBeFilteredCount DEPRECATED_MSG_ATTRIBUTE("use dumpDailyLimit instead");

/// define the max number of lag dump per day
@property (nonatomic, assign) uint32_t dumpDailyLimit;

/// enable printing the memory use
@property (nonatomic, assign) BOOL bPrintMemomryUse;

/**
 * 是否打印CPU频率
 * 
 * 默认值：NO
 * 
 * 说明：
 * - 周期性打印CPU频率信息
 * - 用于了解设备的CPU性能特征
 * - 某些设备可能不支持查询CPU频率（返回0）
 * 
 * 性能影响：
 * - 极小（仅sysctl调用）
 * 
 * 建议：
 * - 开发环境：可选（用于设备性能分析）
 * - 生产环境：NO（不是关键信息）
 */
@property (nonatomic, assign) BOOL bPrintCPUFrequency;

/// enable get the "disk io" callstack
@property (nonatomic, assign) BOOL bGetDiskIOStack DEPRECATED_MSG_ATTRIBUTE("feature removed");

/// define the value of single fd read limit
@property (nonatomic, assign) size_t singleReadLimit DEPRECATED_MSG_ATTRIBUTE("feature removed");

/// define the value of single fd write limit
@property (nonatomic, assign) size_t singleWriteLimit DEPRECATED_MSG_ATTRIBUTE("feature removed");

/// define the value of total read limit in 1s
@property (nonatomic, assign) size_t totalReadLimit DEPRECATED_MSG_ATTRIBUTE("feature removed");

/// define the value of total write limit in 1s
@property (nonatomic, assign) size_t totalWriteLimit DEPRECATED_MSG_ATTRIBUTE("feature removed");

/// define the threshold of memory warning
@property (nonatomic, assign) uint32_t memoryWarningThresholdInMB;

/// enable to detect any runloop hangs on main thread
@property (nonatomic, assign) BOOL bSensitiveRunloopHangDetection;

/// define whether to suspend all threads when handling user exception
@property (nonatomic, assign) BOOL bSuspendAllThreads;

/// define whether to enable snapshot when handling user exception
@property (nonatomic, assign) BOOL bEnableSnapshot;

@end
