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
 * WCBlockMonitorMgr - 主线程卡顿监控管理器
 * ============================================================================
 * 
 * 功能概述：
 * 这是腾讯Matrix iOS性能监控框架的核心组件，负责检测和上报主线程卡顿问题。
 * 
 * ============================================================================
 * 核心原理：
 * ============================================================================
 * 
 * 1. RunLoop监控：
 *    - 在主线程的RunLoop上注册Observer，监听其活动状态
 *    - 记录RunLoop开始处理任务的时间（kCFRunLoopBeforeSources/AfterWaiting）
 *    - 在独立的监控线程中周期性检查RunLoop执行时长
 *    - 如果执行时长超过阈值（默认2秒），判定为卡顿
 * 
 * 2. 堆栈采集（Point Stack算法）：
 *    - 在检查周期内，每隔50ms采集一次主线程堆栈
 *    - 保存在循环数组中（例如：1秒周期采集20次）
 *    - 通过栈顶地址连续重复次数，找出最有可能导致卡顿的堆栈
 *    - 重复次数越多，说明主线程在该函数上停留时间越长
 * 
 * 3. 退火算法（Simulated Annealing）：
 *    - 如果连续多次检测到相同的堆栈，说明主线程一直卡在同一处
 *    - 此时延长检查间隔（1s -> 2s -> 3s -> 5s -> ...），减少检测频率
 *    - 节省性能开销，避免重复上报相同卡顿
 * 
 * 4. CPU监控：
 *    - 同时监控CPU使用率
 *    - 检测瞬时CPU过高（单次超过阈值）
 *    - 检测平均CPU过高（持续一段时间超过阈值）
 *    - 收集CPU高占用线程的堆栈
 * 
 * 5. 多种过滤策略：
 *    - 过滤无意义堆栈（深度<=1）
 *    - 过滤后台启动期间的误报
 *    - 过滤App挂起恢复时的误报
 *    - 限制每日上报次数
 * 
 * ============================================================================
 * 关键概念：
 * ============================================================================
 * 
 * - RunLoop超时阈值（g_RunLoopTimeOut）：
 *   判定卡顿的时间阈值，默认2000ms，可动态调整到400-2000ms
 * 
 * - 检查周期（g_CheckPeriodTime）：
 *   一轮堆栈采集的总时间，通常为超时阈值的一半（1000ms）
 * 
 * - 堆栈采集间隔（g_PerStackInterval）：
 *   单次堆栈采集的时间间隔，固定为50ms
 * 
 * - Point Stack：
 *   最有可能导致卡顿的堆栈，通过栈顶地址连续重复次数分析得出
 * 
 * - 循环数组：
 *   保存一轮检查周期内采集的所有堆栈，大小 = 检查周期 / 堆栈间隔
 * 
 * ============================================================================
 * 使用示例：
 * ============================================================================
 * 
 * // 1. 配置
 * WCBlockMonitorConfiguration *config = [WCBlockMonitorConfiguration defaultConfig];
 * config.runloopTimeOut = 2000000;  // 2秒
 * config.checkPeriodTime = 1000000; // 1秒
 * 
 * // 2. 启动监控
 * [[WCBlockMonitorMgr shareInstance] resetConfiguration:config];
 * [[WCBlockMonitorMgr shareInstance] start];
 * 
 * // 3. 实现代理接收回调
 * - (void)onBlockMonitor:(WCBlockMonitorMgr *)monitor 
 *            getDumpFile:(NSString *)dumpFile 
 *           withDumpType:(EDumpType)dumpType {
 *     // 处理卡顿报告
 * }
 * 
 * ============================================================================
 */

#import "WCBlockMonitorMgr.h"
#import <vector>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <mach/mach_types.h>
#import <pthread/pthread.h>
#import <mach/mach_time.h>
#import <vector>
#import <algorithm>

#import "MatrixLogDef.h"
#import "MatrixDeviceInfo.h"
#import "WCGetMainThreadUtil.h"
#import "WCCPUHandler.h"
#import "WCBlockMonitorConfigHandler.h"
#import "WCDumpInterface.h"
#import "WCCrashBlockFileHandler.h"
#import "WCGetCallStackReportHandler.h"
#import "WCCrashBlockMonitorPlugin.h"
#import "WCFilterStackHandler.h"
#import "KSSymbolicator.h"
#import "WCPowerConsumeStackCollector.h"
#import "logger_internal.h"


// ============================================================================
#pragma mark - CPU频率测量
// ============================================================================

#if defined(__arm64__)

/**
 * 尝试估算CPU频率
 * @return CPU频率(GHz)，失败返回0
 * 
 * 原理：通过汇编指令执行固定次数的循环，测量消耗的时间，从而计算出CPU频率
 * 使用两次测量并相减的技巧来提高准确性
 */
double measure_frequency() {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    const size_t test_duration_in_cycles =
    65536;// 1048576;
    // travis feels strongly about the measure-twice-and-subtract trick.
    auto begin1 = mach_absolute_time();
    size_t cycles = 2 * test_duration_in_cycles;
    
    __asm volatile(
                   ".align 4\n Lcyclemeasure1:\nsubs %[counter],%[counter],#1\nbne Lcyclemeasure1\n "
                   : /* read/write reg */ [counter] "+r"(cycles));
    auto end1 = mach_absolute_time();
    double nanoseconds1 =
    (double) (end1 - begin1) * (double)info.numer / (double)info.denom;
    
    auto begin2 = mach_absolute_time();
    cycles = test_duration_in_cycles;
    // I think that this will have a 2-cycle latency on ARM?
    __asm volatile(
                   ".align 4\n Lcyclemeasure2:\nsubs %[counter],%[counter],#1\nbne Lcyclemeasure2\n "
                   : /* read/write reg */ [counter] "+r"(cycles));
    auto end2 = mach_absolute_time();
    double nanoseconds2 =
    (double) (end2 - begin2) * (double)info.numer / (double)info.denom;
    double nanoseconds = (nanoseconds1 - nanoseconds2);
    if ((fabs(nanoseconds - nanoseconds1 / 2) > 0.05 * nanoseconds) or
        (fabs(nanoseconds - nanoseconds2) > 0.05 * nanoseconds)) {
        return 0;
    }
    double frequency = double(test_duration_in_cycles) / nanoseconds;
    return frequency;
}

/**
 * 获取CPU频率
 * @return CPU频率(GHz)
 * 
 * 通过多次测量取中位数，提高测量准确性
 * 测量1000次，排序后取中位数
 */
double cpu_frequency()
{
    double result = 0;
    size_t attempt = 1000;  // 测量次数
    std::vector<double> freqs;
    
    // 进行多次测量
    for (int i = 0; i < attempt; i++) {
        double freq = measure_frequency();
        if(freq > 0) freqs.push_back(freq);
    }
    
    // 如果没有成功的测量，返回0
    if(freqs.size() == 0) {
        return result;
    }
    
    // 排序后取中位数
    std::sort(freqs.begin(),freqs.end());
    result = freqs[freqs.size() / 2];
    return result;
}

#endif

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#if TARGET_OS_OSX
#import "NSApplicationEvent.h"
#endif

// ============================================================================
#pragma mark - 全局配置变量
// ============================================================================

static useconds_t g_RunLoopTimeOut = g_defaultRunLoopTimeOut;  // RunLoop超时阈值(微秒)，超过此时间判定为卡顿
static useconds_t g_CheckPeriodTime = g_defaultCheckPeriodTime;  // 检查周期时间(微秒)，一般为超时阈值的一半
static float g_CPUUsagePercent = 1000;  // CPU使用率阈值，超过此值判定为CPU过高（初始值很大是为了防止错误设置）
static useconds_t g_PerStackInterval = g_defaultPerStackInterval;  // 每次采集堆栈的时间间隔(微秒)，默认50ms
static size_t g_StackMaxCount = 100;  // 单个堆栈的最大地址数量
static BOOL g_bSensitiveRunloopHangDetection = NO;  // 是否开启敏感的RunLoop卡顿检测（Apple HangTracer阈值250ms）

// ============================================================================
#pragma mark - 主线程堆栈相关全局变量
// ============================================================================

static NSUInteger g_CurrentThreadCount = 0;  // 当前线程数量
static BOOL g_MainThreadHandle = NO;  // 是否处理主线程堆栈
static BOOL g_MainThreadProfile = NO;  // 是否生成主线程Profile
static int g_MainThreadCount = 0;  // 主线程堆栈数组大小，根据检查周期和堆栈间隔计算
static KSStackCursor *g_PointMainThreadArray = NULL;  // 指向最有可能卡顿的主线程堆栈
static int *g_PointMainThreadRepeatCountArray = NULL;  // 主线程堆栈中每个地址的重复次数数组
static char *g_PointMainThreadProfile = NULL;  // 主线程Profile JSON数据
static KSStackCursor **g_PointCPUHighThreadArray = NULL;  // CPU占用高的线程堆栈数组
static int g_PointCpuHighThreadCount = 0;  // CPU占用高的线程数量
static float *g_PointCpuHighThreadValueArray = NULL;  // CPU占用高的线程对应的CPU使用率数组
static BOOL g_runloopThresholdUpdated = NO;  // RunLoop阈值是否已更新标志

// ============================================================================
#pragma mark - 设备状态变量
// ============================================================================

API_AVAILABLE(ios(11.0))
static NSProcessInfoThermalState g_thermalState = NSProcessInfoThermalStateNominal;  // 设备热状态（温度状态）

// ============================================================================
#pragma mark - 监控常量定义
// ============================================================================

#define PRINT_MEMORY_USE_INTERVAL (5 * BM_MicroFormat_Second)  // 打印内存使用情况的时间间隔：5秒
#define PRINT_CPU_FREQUENCY_INTERVAL (10 * BM_MicroFormat_Second)  // 打印CPU频率的时间间隔：10秒

#define DETECTION_THREAD_JUDGE_SUSPEND_THRESHOLD (10 * BM_MicroFormat_Second)  // 检测线程挂起判断阈值：10秒

#define __timercmp(tvp, uvp, cmp) (((tvp)->tv_sec == (uvp)->tv_sec) ? ((tvp)->tv_usec cmp(uvp)->tv_usec) : ((tvp)->tv_sec cmp(uvp)->tv_sec))

#define BM_SAFE_CALL_SELECTOR_NO_RETURN(obj, sel, func) \
    {                                                   \
        if (obj && [obj respondsToSelector:sel]) {      \
            [obj func];                                 \
        }                                               \
    }

// ============================================================================
#pragma mark - RunLoop状态追踪变量
// ============================================================================

#if TARGET_OS_OSX
static struct timeval g_tvEvent;  // macOS事件开始时间
static BOOL g_eventStart;  // macOS事件是否已开始
#endif

static struct timeval g_tvRun;  // RunLoop开始运行的时间戳
static BOOL g_bRun;  // RunLoop是否正在运行（YES表示正在处理任务）
static struct timeval g_tvSuspend;  // App挂起（进入后台）的时间戳
static CFRunLoopActivity g_runLoopActivity;  // 当前RunLoop的活动状态
static struct timeval g_lastCheckTime;  // 上一次检查的时间戳

// ============================================================================
#pragma mark - 应用启动状态变量
// ============================================================================

static BOOL g_bLaunchOver = NO;  // 应用启动是否完成
#if !TARGET_OS_OSX
static BOOL g_bBackgroundLaunch = NO;  // 是否为后台启动
#endif

/**
 * RunLoop模式枚举
 * eRunloopInitMode: 初始化模式（UIInitializationRunLoopMode）
 * eRunloopDefaultMode: 默认模式（kCFRunLoopCommonModes）
 */
typedef enum : NSUInteger {
    eRunloopInitMode,
    eRunloopDefaultMode,
} ERunloopMode;

static ERunloopMode g_runLoopMode;  // 当前RunLoop模式

// ============================================================================
#pragma mark - 全局回调函数
// ============================================================================

/**
 * 进程退出回调
 * 在App退出时调用，停止卡顿监控
 */
void exitCallBack() {
    [[WCBlockMonitorMgr shareInstance] stop];
}

/**
 * 获取指向主线程堆栈的回调
 * 供KSCrash使用，获取最有可能导致卡顿的主线程堆栈
 */
KSStackCursor *kscrash_pointThreadCallback(void) {
    return g_PointMainThreadArray;
}

/**
 * 获取主线程堆栈重复次数数组的回调
 * 返回每个堆栈地址在所有采样中出现的次数
 */
int *kscrash_pointThreadRepeatNumberCallback(void) {
    return g_PointMainThreadRepeatCountArray;
}

/**
 * 获取主线程Profile数据的回调
 * 返回JSON格式的Profile数据
 */
char *kscrash_pointThreadProfileCallback(void) {
    return g_PointMainThreadProfile;
}

/**
 * 获取CPU占用高的线程堆栈数组的回调
 * 用于CPU过高卡顿的堆栈分析
 */
KSStackCursor **kscrash_pointCPUHighThreadCallback(void) {
    return g_PointCPUHighThreadArray;
}

/**
 * 获取CPU占用高的线程数量的回调
 */
int kscrash_pointCpuHighThreadCountCallback(void) {
    return g_PointCpuHighThreadCount;
}

/**
 * 获取CPU占用高的线程对应CPU使用率数组的回调
 */
float *kscrash_pointCpuHighThreadArrayCallBack(void) {
    return g_PointCpuHighThreadValueArray;
}

/**
 * WCBlockMonitorMgr 类扩展
 * 实现 WCPowerConsumeStackCollectorDelegate 协议，处理耗电堆栈收集
 */
@interface WCBlockMonitorMgr () <WCPowerConsumeStackCollectorDelegate> {
    // ============================================================================
    // 线程管理
    // ============================================================================
    NSThread *m_monitorThread;  // 监控线程，在后台独立线程中运行检测逻辑
    BOOL m_bStop;  // 是否停止监控标志

#if !TARGET_OS_OSX
    UIApplicationState m_currentState;  // 当前应用状态（前台/后台）
#endif

    // ============================================================================
    // 退火算法相关（Simulated Annealing for Lag Detection）
    // ============================================================================
    
    NSUInteger m_nIntervalTime; // 当前检查时间间隔（微秒）。在此时间段内持续采集主线程堆栈
    NSUInteger m_nLastTimeInterval; // 上一轮检查的时间间隔（微秒），用于退火算法
    
    /**
     * 退火算法说明：
     * 如果连续两次检查的主线程堆栈相同，说明主线程一直卡在同一个地方
     * 此时增加检查间隔 m_nIntervalTime，减少检查频率，节省性能
     * 公式：m_nIntervalTime = m_nLastTimeInterval + m_nIntervalTime
     * 如果堆栈不同，重置为默认值 g_CheckPeriodTime
     */

    std::vector<NSUInteger> m_vecLastMainThreadCallStack;  // 上一次主线程堆栈（用于比对）
    NSUInteger m_lastMainThreadStackCount;  // 上一次主线程堆栈深度

    // ============================================================================
    // 卡顿检测相关
    // ============================================================================

    uint64_t m_blockDiffTime;  // 卡顿时长（微秒）

    uint32_t m_firstSleepTime;  // 首次启动时的延迟时间（秒），避免启动时误报

    NSString *m_potenHandledLagFile;  // 当前处理的卡顿文件路径

    WCMainThreadHandler *m_pointMainThreadHandler;  // 主线程堆栈处理器，管理堆栈循环数组

    // ============================================================================
    // RunLoop Observer
    // ============================================================================
    
    CFRunLoopObserverRef m_runLoopBeginObserver;  // 默认模式的RunLoop开始观察者（最早执行）
    CFRunLoopObserverRef m_runLoopEndObserver;  // 默认模式的RunLoop结束观察者（最晚执行）
    CFRunLoopObserverRef m_initializationBeginRunloopObserver;  // 初始化模式的RunLoop开始观察者
    CFRunLoopObserverRef m_initializationEndRunloopObserver;  // 初始化模式的RunLoop结束观察者

    // ============================================================================
    // 异步处理和CPU监控
    // ============================================================================
    
    dispatch_queue_t m_asyncDumpQueue;  // 异步转储队列，用于异步生成卡顿报告

    WCCPUHandler *m_cpuHandler;  // CPU处理器，监控CPU平均使用率
    BOOL m_bTrackCPU;  // 是否跟踪CPU使用率

    WCFilterStackHandler *m_stackHandler;  // 堆栈过滤处理器，用于过滤重复报告
    WCPowerConsumeStackCollector *m_powerConsumeStackCollector;  // 耗电堆栈收集器

    // ============================================================================
    // 周期性打印相关
    // ============================================================================
    
    uint32_t m_printMemoryTickTok;  // 内存打印计时器（微秒）
    uint32_t m_printCPUFrequencyTickTok;  // CPU频率打印计时器（微秒）

    // ============================================================================
    // 转储配置
    // ============================================================================
    
    BOOL m_suspendAllThreads;  // 转储时是否挂起所有线程
    BOOL m_enableSnapshot;  // 是否启用快照功能
    
    struct timeval m_recordStackTime;  // 记录堆栈的时间戳，用于检测挂起
}

@property (nonatomic, strong) WCBlockMonitorConfigHandler *monitorConfigHandler;

#if TARGET_OS_OSX
@property (nonatomic, strong) NSApplicationEvent *eventHandler;
#endif

@end

@implementation WCBlockMonitorMgr

+ (WCBlockMonitorMgr *)shareInstance {
    static WCBlockMonitorMgr *g_monitorMgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_monitorMgr = [[WCBlockMonitorMgr alloc] init];
    });
    return g_monitorMgr;
}

- (void)resetConfiguration:(WCBlockMonitorConfiguration *)bmConfig {
    _monitorConfigHandler = [[WCBlockMonitorConfigHandler alloc] init];
    [_monitorConfigHandler setConfiguration:bmConfig];
}

- (id)init {
    if (self = [super init]) {
#if !TARGET_OS_OSX
        g_bLaunchOver = NO;
#else
        g_bLaunchOver = YES;
#endif
        m_potenHandledLagFile = nil;
        m_asyncDumpQueue = dispatch_queue_create("com.tencent.xin.asyncdump", DISPATCH_QUEUE_SERIAL);
        m_bStop = YES;
    }

    return self;
}

- (void)dealloc {
    CFRelease(m_runLoopBeginObserver);
    CFRelease(m_runLoopEndObserver);
    CFRelease(m_initializationBeginRunloopObserver);
    CFRelease(m_initializationEndRunloopObserver);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (g_PointMainThreadArray != NULL) {
        free(g_PointMainThreadArray);
    }
    if (g_PointMainThreadRepeatCountArray != NULL) {
        free(g_PointMainThreadRepeatCountArray);
    }
}

- (void)freeCpuHighThreadArray {
    for (int i = 0; i < g_PointCpuHighThreadCount; i++) {
        if (g_PointCPUHighThreadArray[i] != NULL) {
            KSStackCursor_Backtrace_Context *context = (KSStackCursor_Backtrace_Context *)g_PointCPUHighThreadArray[i]->context;
            if (context->backtrace != NULL) {
                free((uintptr_t *)context->backtrace);
            }
            free(g_PointCPUHighThreadArray[i]);
            g_PointCPUHighThreadArray[i] = NULL;
        }
    }

    if (g_PointCPUHighThreadArray != NULL) {
        free(g_PointCPUHighThreadArray);
        g_PointCPUHighThreadArray = NULL;
    }

    if (g_PointCpuHighThreadValueArray != NULL) {
        free(g_PointCpuHighThreadValueArray);
        g_PointCpuHighThreadValueArray = NULL;
    }

    g_PointCpuHighThreadCount = 0;
}

// ============================================================================
#pragma mark - 公共方法
// ============================================================================

/**
 * 启动卡顿监控
 * 
 * 主要步骤：
 * 1. 从配置中读取各种阈值参数
 * 2. 初始化主线程堆栈处理器
 * 3. 初始化CPU监控
 * 4. 注册应用状态通知
 * 5. 添加RunLoop观察者
 * 6. 启动监控线程
 */
- (void)start {
    // 如果已经在运行，直接返回
    if (!m_bStop) {
        return;
    }

    // ============================================================================
    // 1. 读取配置参数
    // ============================================================================
    
    g_MainThreadHandle = [_monitorConfigHandler getMainThreadHandle];  // 是否采集主线程堆栈
    g_MainThreadProfile = [_monitorConfigHandler getMainThreadProfile];  // 是否生成Profile
    [self setRunloopThreshold:[_monitorConfigHandler getRunloopTimeOut] isFirstTime:YES];  // 设置RunLoop超时阈值
    [self setCPUUsagePercent:[_monitorConfigHandler getCPUUsagePercent]];  // 设置CPU使用率阈值
    [self setPerStackInterval:[_monitorConfigHandler getPerStackInterval]];  // 设置堆栈采集间隔

    // ============================================================================
    // 2. 初始化时间和状态变量
    // ============================================================================
    
    m_nIntervalTime = g_CheckPeriodTime;  // 初始化检查间隔为默认值
    m_nLastTimeInterval = m_nIntervalTime;
    m_blockDiffTime = 0;  // 重置卡顿时长
    m_firstSleepTime = 5;  // 首次启动延迟5秒，避免启动期间的误报
    gettimeofday(&g_tvSuspend, NULL);  // 记录当前时间为挂起时间
    gettimeofday(&g_lastCheckTime, NULL);  // 记录上次检查时间

    // ============================================================================
    // 3. 配置周期性打印
    // ============================================================================
    
    // 设置内存打印计时器
    if ([_monitorConfigHandler getShouldPrintMemoryUse]) {
        m_printMemoryTickTok = 0;  // 立即开始打印
    } else {
        m_printMemoryTickTok = 6 * BM_MicroFormat_Second;  // 跳过首次打印
    }
    
    // 设置CPU频率打印计时器
    if ([_monitorConfigHandler getShouldPrintCPUFrequency]) {
        m_printCPUFrequencyTickTok = 0;  // 立即开始打印
    } else {
        m_printCPUFrequencyTickTok = 11 * BM_MicroFormat_Second;  // 跳过首次打印
    }

    // ============================================================================
    // 4. 初始化主线程堆栈处理器
    // ============================================================================
    
    /**
     * 计算主线程堆栈数组大小：
     * g_MainThreadCount = g_CheckPeriodTime / g_PerStackInterval
     * 
     * 例如：检查周期 = 1000ms，堆栈间隔 = 50ms
     * 则：g_MainThreadCount = 1000ms / 50ms = 20
     * 即：一轮检查中会采集20个主线程堆栈，使用循环数组保存
     */
    g_MainThreadCount = g_CheckPeriodTime / g_PerStackInterval;
    m_pointMainThreadHandler = [[WCMainThreadHandler alloc] initWithCycleArrayCount:g_MainThreadCount];
    g_StackMaxCount = [m_pointMainThreadHandler getStackMaxCount];  // 获取单个堆栈的最大地址数

    // ============================================================================
    // 5. 初始化CPU监控
    // ============================================================================
    
    m_bTrackCPU = YES;  // 开启CPU跟踪

    // 初始化CPU处理器，用于监控平均CPU使用率
    m_cpuHandler = [[WCCPUHandler alloc] initWithCPULimit:[_monitorConfigHandler getPowerConsumeCPULimit]];

    // 如果配置了耗电堆栈收集，则初始化耗电堆栈收集器
    if ([_monitorConfigHandler getShouldGetPowerConsumeStack]) {
        m_powerConsumeStackCollector = [[WCPowerConsumeStackCollector alloc] initWithCPULimit:[_monitorConfigHandler getPowerConsumeCPULimit]];
        m_powerConsumeStackCollector.delegate = self;  // 设置代理，接收耗电堆栈回调
    } else {
        m_powerConsumeStackCollector = nil;
    }

    // ============================================================================
    // 6. 配置敏感检测和转储选项
    // ============================================================================
    
    g_bSensitiveRunloopHangDetection = [_monitorConfigHandler getSensitiveRunloopHangDetection];  // 是否启用敏感的RunLoop卡顿检测（250ms阈值）

    m_suspendAllThreads = [_monitorConfigHandler getShouldSuspendAllThreads];  // 转储时是否挂起所有线程
    m_enableSnapshot = [_monitorConfigHandler getShouldEnableSnapshot];  // 是否启用快照

#if !TARGET_OS_OSX
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willTerminate) name:UIApplicationWillTerminateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(willResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    if (@available(iOS 11.0, *)) {
        // Apple doc: To receive NSProcessInfoThermalStateDidChangeNotification, you must access the thermalState prior to registering for the notification.
        g_thermalState = [[NSProcessInfo processInfo] thermalState];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(thermalStateDidChange)
                                                     name:NSProcessInfoThermalStateDidChangeNotification
                                                   object:nil];
    }
#endif

    atexit(exitCallBack);

    [self addRunLoopObserver];
    [self addMonitorThread];

#if TARGET_OS_OSX
    self.eventHandler = [[NSApplicationEvent alloc] init];
    [self.eventHandler tryswizzle];
#endif
}

- (void)stop {
    if (m_bStop) {
        return;
    }

    m_bStop = YES;

    [self removeRunLoopObserver];

    while ([m_monitorThread isExecuting]) {
        usleep(100 * BM_MicroFormat_MillSecond);
    }
}

#if !TARGET_OS_OSX

- (void)handleBackgroundLaunch {
    g_bBackgroundLaunch = YES;
}

- (void)handleSuspend {
    gettimeofday(&g_tvSuspend, NULL);
}

#endif

- (NSDictionary *)getUserInfoForCurrentDumpForDumpType:(EDumpType)dumpType {
    if (_delegate != nil && [_delegate respondsToSelector:@selector(onBlockMonitor:getCustomUserInfoForDumpType:)]) {
        return [_delegate onBlockMonitor:self getCustomUserInfoForDumpType:dumpType];
    }
    return nil;
}

// ============================================================================
#pragma mark - Application State (Notification Observer)
// ============================================================================

#if !TARGET_OS_OSX
- (void)willTerminate {
    [self stop];
}

- (void)didBecomeActive {
    MatrixInfo(@"已变为活跃状态");

    m_currentState = [UIApplication sharedApplication].applicationState;

    if (g_bBackgroundLaunch && !g_bLaunchOver) {
        MatrixInfo(@"启动完成前后台启动，清除转储");
        [self clearDumpInBackgroundLaunch];
        g_bBackgroundLaunch = NO;
    }
    
    g_bLaunchOver = YES;

    [self clearLaunchLagRecord];
}

- (void)didEnterBackground {
    MatrixInfo(@"已进入后台");
    m_currentState = [UIApplication sharedApplication].applicationState;
}

- (void)willResignActive {
    MatrixInfo(@"即将失去活跃状态");
    m_currentState = [UIApplication sharedApplication].applicationState;
    g_bLaunchOver = YES;
}

- (void)thermalStateDidChange {
    MatrixDebug(@"热状态已改变");

    if (@available(iOS 11.0, *)) {
        // On iOS 15.0.2, Foundation.framework might post ThermalStateDidChangeNotification from -[NSProcessInfo thermalState],
        // recursively calling -[NSProcessInfo thermalState] in the notification's observer could cause a crash.
        // Dispatch it as a workaround. FB9802727 to Apple. Already fixed on iOS 15.2.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSProcessInfoThermalState currentThermalState = [[NSProcessInfo processInfo] thermalState];
            if (currentThermalState > g_thermalState) {
                BM_SAFE_CALL_SELECTOR_NO_RETURN(self.delegate,
                                                @selector(onBlockMonitorThermalStateElevated:),
                                                onBlockMonitorThermalStateElevated:self);
            }
            g_thermalState = currentThermalState;
        });
    }
}

#endif

// ============================================================================
#pragma mark - Config
// ============================================================================

- (void)setCPUUsagePercent:(float)usagePercent {
    float tmpUsagePercent = g_CPUUsagePercent;
    g_CPUUsagePercent = usagePercent;
    MatrixInfo(@"设置 CPU 使用率 之前[%lf] 之后[%lf]", tmpUsagePercent, g_CPUUsagePercent);
}

- (void)setPerStackInterval:(useconds_t)perStackInterval {
    if (perStackInterval < BM_MicroFormat_FrameMillSecond || perStackInterval > BM_MicroFormat_Second) {
        MatrixWarning(@"每次堆栈间隔无效，当前[%u] 设为[%u]", g_PerStackInterval, perStackInterval);
        return;
    }
    useconds_t tmpStackInterval = g_PerStackInterval;
    g_PerStackInterval = perStackInterval;
    MatrixInfo(@"设置每次堆栈间隔 之前[%u] 之后[%u]", tmpStackInterval, g_PerStackInterval);
}

// ============================================================================
#pragma mark - Monitor Thread
// ============================================================================

- (void)addMonitorThread {
    m_bStop = NO;
    m_monitorThread = [[NSThread alloc] initWithTarget:self selector:@selector(threadProc) object:nil];
    [m_monitorThread start];
}

/**
 * 监控线程主循环
 * 
 * 这是卡顿监控的核心逻辑，运行在独立的后台线程中
 * 
 * 执行流程：
 * 1. 首次启动延迟5秒（避免启动期间误报）
 * 2. 初始化堆栈过滤处理器
 * 3. 进入无限循环：
 *    a. 调用check方法检测是否卡顿
 *    b. 如果检测到卡顿，根据类型生成转储报告
 *    c. 调用recordCurrentStack采集主线程堆栈
 *    d. 重复上述步骤
 * 
 * 转储类型处理：
 * - EDumpType_MainThreadBlock: 主线程卡顿
 * - EDumpType_BackgroundMainThreadBlock: 后台主线程卡顿
 * - EDumpType_CPUBlock: CPU过高卡顿
 * - EDumpType_Unlag: 无卡顿
 */
- (void)threadProc {
    // ============================================================================
    // 1. 首次启动延迟
    // ============================================================================
    
    if (m_firstSleepTime) {
        sleep(m_firstSleepTime);  // 延迟5秒，避免启动期间的误报
        m_firstSleepTime = 0;
    }

    // ============================================================================
    // 2. 初始化堆栈过滤处理器
    // ============================================================================
    
    m_stackHandler = [[WCFilterStackHandler alloc] init];

    // 设置当前线程忽略内存日志（避免监控线程本身产生的内存分配被记录）
    set_curr_thread_ignore_logging(true);

    // ============================================================================
    // 3. 监控主循环
    // ============================================================================
    
    while (YES) {
        @autoreleasepool {
            // ====================================================================
            // 3.1 检测是否发生卡顿
            // ====================================================================
            
            EDumpType dumpType = [self check];
            
            // 如果收到停止信号，退出循环
            if (m_bStop) {
                break;
            }
            
            // 通知代理：进入下一轮检查
            BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                            @selector(onBlockMonitor:enterNextCheckWithDumpType:),
                                            onBlockMonitor:self enterNextCheckWithDumpType:dumpType);
            
            
            // ====================================================================
            // 3.2 处理卡顿（生成转储报告）
            // ====================================================================
            
            if (dumpType != EDumpType_Unlag) {
                // ----------------------------------------------------------------
                // 3.2.1 主线程卡顿（前台或后台）
                // ----------------------------------------------------------------
                if (EDumpType_BackgroundMainThreadBlock == dumpType || EDumpType_MainThreadBlock == dumpType) {
                    // 判断是否需要过滤（退火算法、上报限制等）
                    EFilterType filterType = [self needFilter];
                    
                    if (filterType == EFilterType_None) {
                        // 不过滤，生成转储报告
                        
                        if (g_MainThreadHandle) {
                            // 开启了主线程堆栈采集
                            
                            // 释放旧的Point Stack
                            if (g_PointMainThreadArray != NULL) {
                                free(g_PointMainThreadArray);
                                g_PointMainThreadArray = NULL;
                            }
                            
                            // 如果配置了生成Profile，获取堆栈Profile
                            if (g_MainThreadProfile) {
                                g_PointMainThreadProfile = [m_pointMainThreadHandler getStackProfile];
                            }
                            
                            // 获取最有可能导致卡顿的堆栈（Point Stack）
                            g_PointMainThreadArray = [m_pointMainThreadHandler getPointStackCursor];
                            g_PointMainThreadRepeatCountArray = [m_pointMainThreadHandler getPointStackRepeatCount];
                            
                            // 生成转储文件
                            m_potenHandledLagFile = [self dumpFileWithType:dumpType];
                            
                            // 通知代理：已生成转储文件
                            BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                                            @selector(onBlockMonitor:getDumpFile:withDumpType:),
                                                            onBlockMonitor:self getDumpFile:m_potenHandledLagFile withDumpType:dumpType);
                            
                            // 释放Point Stack内存
                            if (g_PointMainThreadArray != NULL) {
                                KSStackCursor_Backtrace_Context *context = (KSStackCursor_Backtrace_Context *)g_PointMainThreadArray->context;
                                if (context->backtrace) {
                                    free((uintptr_t *)context->backtrace);
                                }
                                free(g_PointMainThreadArray);
                                g_PointMainThreadArray = NULL;
                            }
                            
                            // 释放Profile内存
                            if (g_PointMainThreadProfile != NULL) {
                                free(g_PointMainThreadProfile);
                                g_PointMainThreadProfile = NULL;
                            }
                        } else {
                            // 未开启主线程堆栈采集，直接生成转储文件
                            m_potenHandledLagFile = [self dumpFileWithType:dumpType];
                            BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                                            @selector(onBlockMonitor:getDumpFile:withDumpType:),
                                                            onBlockMonitor:self getDumpFile:m_potenHandledLagFile withDumpType:dumpType);
                        }
                    } else {
                        // 需要过滤，通知代理
                        BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                                        @selector(onBlockMonitor:dumpType:filter:),
                                                        onBlockMonitor:self dumpType:dumpType filter:filterType);
                    }

                    // 通知代理：检测到主线程卡顿
                    BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                                    @selector(onBlockMonitorMainThreadBlock:),
                                                    onBlockMonitorMainThreadBlock:self);
                    
                // ----------------------------------------------------------------
                // 3.2.2 CPU过高卡顿
                // ----------------------------------------------------------------
                } else if (EDumpType_CPUBlock == dumpType) {
                    // 1. 获取CPU占用高的线程堆栈
                    if (m_powerConsumeStackCollector) {
                        // 释放旧的CPU高占用线程堆栈
                        if (g_PointCPUHighThreadArray != NULL) {
                            [self freeCpuHighThreadArray];
                        }
                        
                        // 获取CPU高占用线程的堆栈
                        g_PointCPUHighThreadArray = [m_powerConsumeStackCollector getCPUStackCursor];
                        g_PointCpuHighThreadCount = [m_powerConsumeStackCollector getCurrentCpuHighStackNumber];
                        g_PointCpuHighThreadValueArray = [m_powerConsumeStackCollector getCpuHighThreadValueArray];
                    }
                    
                    // 2. 生成转储文件
                    m_potenHandledLagFile = [self dumpFileWithType:dumpType];
                    
                    // 3. 释放CPU高占用线程堆栈内存
                    [self freeCpuHighThreadArray];
                    
                // ----------------------------------------------------------------
                // 3.2.3 其他类型卡顿
                // ----------------------------------------------------------------
                } else {
                    m_potenHandledLagFile = [self dumpFileWithType:dumpType];
                }
            } else {
                // ----------------------------------------------------------------
                // 3.2.4 无卡顿，重置状态
                // ----------------------------------------------------------------
                [self resetStatus];
            }

            // ====================================================================
            // 3.3 采集主线程堆栈（周期性采集）
            // ====================================================================
            
            [self recordCurrentStack];

            // 如果收到停止信号，退出循环
            if (m_bStop) {
                break;
            }
        }
    }
}

/**
 * 记录当前主线程堆栈
 * 
 * 这是监控线程的核心循环之一，负责周期性地采集主线程堆栈
 * 
 * 时间参数说明：
 * 1. m_nIntervalTime: 本次总的采集时间（可能因退火算法而变化）
 *    - 正常情况：等于 g_CheckPeriodTime
 *    - 退火情况：如果连续检测到相同堆栈，会逐步增加
 * 
 * 2. g_CheckPeriodTime: 单次检查周期（固定值，通常为RunLoop超时阈值的一半）
 *    - 例如：RunLoop超时阈值为2000ms，则 g_CheckPeriodTime = 1000ms
 * 
 * 3. g_PerStackInterval: 单次堆栈采集间隔（固定50ms）
 * 
 * 采集策略示例：
 * - 假设 g_CheckPeriodTime = 1000ms, g_PerStackInterval = 50ms
 * - 则一个检查周期内会采集 1000ms / 50ms = 20 次堆栈
 * - 如果退火算法生效，m_nIntervalTime = 6000ms
 * - 则总循环次数 nTotalCnt = 6000ms / 1000ms = 6
 * - 即：会执行6个检查周期，总共采集 6 * 20 = 120 次堆栈
 */
- (void)recordCurrentStack {
    // 计算本次需要执行的检查周期数
    unsigned long nTotalCnt = m_nIntervalTime / g_CheckPeriodTime;
    
    // 外层循环：遍历每个检查周期
    for (int nCnt = 0; nCnt < nTotalCnt && !m_bStop; nCnt++) {
        // 记录本轮开始时间，用于检测是否被系统挂起
        gettimeofday(&m_recordStackTime, NULL);
        
        // 如果开启了主线程堆栈采集
        if (g_MainThreadHandle) {
            // 计算一个检查周期内需要采集的次数
            // 例如：1000ms / 50ms = 20次
            int intervalCount = g_CheckPeriodTime / g_PerStackInterval;
            
            if (intervalCount <= 0) {
                // 如果配置不合理，直接sleep整个周期
                usleep(g_CheckPeriodTime);
            } else {
                int mainThreadCheckTimes = 0;
                
                // 内层循环：在一个检查周期内多次采集堆栈
                for (int index = 0; index < intervalCount && !m_bStop; index++) {
                    // 等待堆栈采集间隔时间（50ms）
                    usleep(g_PerStackInterval);
                    
                    // 分配堆栈数组内存
                    size_t stackBytes = sizeof(uintptr_t) * g_StackMaxCount;
                    uintptr_t *stackArray = (uintptr_t *)malloc(stackBytes);
                    if (stackArray == NULL) {
                        continue;  // 内存分配失败，跳过本次采集
                    }
                    
                    // 初始化堆栈数组
                    __block size_t nSum = 0;
                    memset(stackArray, 0, stackBytes);
                    
                    // 获取主线程当前堆栈
                    [WCGetMainThreadUtil
                    getCurrentMainThreadStack:^(NSUInteger pc) {
                        stackArray[nSum] = (uintptr_t)pc;  // 保存每个栈帧的程序计数器
                        nSum++;
                    }
                               withMaxEntries:g_StackMaxCount  // 最大栈帧数量
                              withThreadCount:g_CurrentThreadCount];  // 当前线程数
                    
                    // 将采集到的堆栈添加到循环数组中
                    [m_pointMainThreadHandler addThreadStack:stackArray andStackCount:nSum];
                    mainThreadCheckTimes++;
                }
            }
        } else {
            // 如果未开启主线程堆栈采集，直接sleep
            usleep(g_CheckPeriodTime);
        }
        
        // ============================================================================
        // 检测是否被系统挂起（suspend）
        // ============================================================================
        
        struct timeval tvCur;
        gettimeofday(&tvCur, NULL);
        unsigned long long diff = [WCBlockMonitorMgr diffTime:&m_recordStackTime endTime:&tvCur];
        
        // 如果实际消耗时间远大于预期（超过10秒），说明App被系统挂起过
        if (diff > DETECTION_THREAD_JUDGE_SUSPEND_THRESHOLD) {
            // 更新RunLoop运行时间，避免误报
            gettimeofday(&g_tvRun, NULL);
            MatrixInfo(@"挂起后运行，差值 %llu", diff);
            return;  // 提前返回，不继续检测
        }
    }
}

/**
 * 检查是否发生卡顿
 * 
 * 这是卡顿监控的核心检测方法，在监控线程中周期性调用
 * 
 * 检测维度：
 * 1. RunLoop超时检测：主线程RunLoop执行时间超过阈值
 * 2. CPU过高检测：CPU使用率持续超过阈值
 * 3. 内存监控：定期打印内存使用情况
 * 4. 热状态监控：监控设备温度状态
 * 
 * @return EDumpType 转储类型
 *         - EDumpType_Unlag: 无卡顿
 *         - EDumpType_MainThreadBlock: 主线程卡顿
 *         - EDumpType_BackgroundMainThreadBlock: 后台主线程卡顿
 *         - EDumpType_CPUBlock: CPU过高卡顿
 */
- (EDumpType)check {
    // ============================================================================
    // 1. RunLoop超时检测
    // ============================================================================

    // 使用临时变量避免多线程竞争（这些全局变量在主线程的RunLoop Observer中被修改）
    BOOL tmp_g_bRun = g_bRun;  // RunLoop是否正在运行
    struct timeval tmp_g_tvRun = g_tvRun;  // RunLoop开始运行的时间

    // 获取当前时间
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);
    
    // 计算RunLoop已经运行了多久（微秒）
    unsigned long long diff = [WCBlockMonitorMgr diffTime:&tmp_g_tvRun endTime:&tvCur];

#if TARGET_OS_OSX
    // macOS平台：额外检测事件处理超时
    BOOL tmp_g_bEventStart = g_eventStart;
    struct timeval tmp_g_tvEvent = g_tvEvent;
    unsigned long long eventDiff = [WCBlockMonitorMgr diffTime:&tmp_g_tvEvent endTime:&tvCur];
#endif

#if !TARGET_OS_OSX
    // iOS平台：检测是否在RunLoop运行后发生了挂起
    struct timeval tmp_g_tvSuspend = g_tvSuspend;
    if (__timercmp(&tmp_g_tvSuspend, &tmp_g_tvRun, >)) {
        // 如果挂起时间 > RunLoop开始时间，说明App被挂起了
        // 这种情况不是真正的卡顿，需要过滤
        MatrixInfo(@"运行后挂起，已过滤");
        return EDumpType_Unlag;
    }
#endif

    m_blockDiffTime = 0;  // 重置卡顿时长

    // 判断是否发生RunLoop超时：
    // 1. RunLoop正在运行（tmp_g_bRun == YES）
    // 2. 时间戳有效（tv_sec 和 tv_usec 不为0）
    // 3. 开始时间 < 当前时间
    // 4. 运行时长超过阈值
    if (tmp_g_bRun && tmp_g_tvRun.tv_sec && tmp_g_tvRun.tv_usec && __timercmp(&tmp_g_tvRun, &tvCur, <) && diff > g_RunLoopTimeOut) {
        m_blockDiffTime = diff;  // 记录卡顿时长
#if TARGET_OS_OSX
        MatrixInfo(@"检查 RunLoop 超时阈值 %u，bRun %d，runloop 活动 %lu，阻塞时间差 %llu", g_RunLoopTimeOut, g_bRun, g_runLoopActivity, diff);
#endif

#if !TARGET_OS_OSX
        MatrixInfo(@"检查 RunLoop 超时阈值 %u，应用状态 %ld，bRun %d，runloop 活动 %lu，阻塞时间差 %llu",
                   g_RunLoopTimeOut,
                   (long)m_currentState,
                   g_bRun,
                   g_runLoopActivity,
                   diff);

        if (g_bBackgroundLaunch && !g_bLaunchOver) {
            MatrixInfo(@"启动完成前后台启动，已过滤");
            return EDumpType_Unlag;
        }

        if (m_currentState == UIApplicationStateBackground) {
            return EDumpType_BackgroundMainThreadBlock;
        }
#endif
        return EDumpType_MainThreadBlock;
    }

#if TARGET_OS_OSX
    if (tmp_g_bEventStart && tmp_g_tvEvent.tv_sec && tmp_g_tvEvent.tv_usec && __timercmp(&tmp_g_tvEvent, &tvCur, <) && eventDiff > g_RunLoopTimeOut) {
        m_blockDiffTime = eventDiff;
        MatrixInfo(@"检查事件超时 %u bRun %d", g_RunLoopTimeOut, g_eventStart);
        return EDumpType_MainThreadBlock;
    }
#endif

    // ============================================================================
    // 2. CPU使用率检测
    // ============================================================================

    float appCpuUsage = 0.;
    
    // 获取当前App的CPU使用率
    if (m_powerConsumeStackCollector == nil) {
        // 没有耗电堆栈收集器，直接获取CPU使用率
        appCpuUsage = [MatrixDeviceInfo appCpuUsage];
    } else {
        // 有耗电堆栈收集器，在获取CPU使用率的同时收集堆栈
        appCpuUsage = [m_powerConsumeStackCollector getCPUUsageAndPowerConsumeStack];
    }

    // 获取设备整体CPU使用率
    float deviceCpuUsage = [MatrixDeviceInfo cpuUsage];

    // 如果配置了打印CPU使用率，且CPU较高时打印
    if ([_monitorConfigHandler getShouldPrintCPUUsage] && (appCpuUsage > 40.0f || deviceCpuUsage > 40.0f)) {
        MatrixInfo(@"应用 CPU 使用率: %.2f，设备: %.2f", appCpuUsage, deviceCpuUsage * [MatrixDeviceInfo cpuCount]);
    }

    /**
     * CPU检测分为两种：
     * 
     * 1. 平均CPU使用率检测（耗电堆栈检测）：
     *    - 在耗电堆栈收集器内部会记录累计时间（通常60秒）
     *    - 只有累积时间达到阈值且CPU持续超过阈值才会触发
     *    - 用于检测长时间的高CPU消耗
     * 
     * 2. 瞬时CPU过高检测：
     *    - 根据当前检查时刻的CPU使用率判断
     *    - 超过阈值立即触发
     *    - 用于检测短时间的CPU峰值
     */
    if (m_bTrackCPU) {
        // 计算距离上次检查的时间间隔
        unsigned long long checkPeriod = [WCBlockMonitorMgr diffTime:&g_lastCheckTime endTime:&tvCur];
        gettimeofday(&g_lastCheckTime, NULL);  // 更新上次检查时间
        
        // 检测平均CPU使用率（耗电检测）
        if ([m_cpuHandler cultivateCpuUsage:appCpuUsage periodTime:(float)checkPeriod / 1000000]) {
            MatrixInfo(@"超出 CPU 平均使用率");
            
            // 如果有耗电堆栈收集器，生成结论报告
            if (m_powerConsumeStackCollector) {
                [m_powerConsumeStackCollector makeConclusion];
            }
            
            // 通知代理：检测到持续CPU过高
            BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate, @selector(onBlockMonitorIntervalCPUTooHigh:), onBlockMonitorIntervalCPUTooHigh:self)
        }
        
        // 检测瞬时CPU过高
        if (appCpuUsage > g_CPUUsagePercent) {
            MatrixInfo(@"检查 CPU 过度使用转储 %f", appCpuUsage);
            
            // 通知代理：检测到瞬时CPU过高
            BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate, @selector(onBlockMonitorCurrentCPUTooHigh:), onBlockMonitorCurrentCPUTooHigh:self)
            
            // 如果配置了获取CPU高占用时的堆栈日志
            if ([_monitorConfigHandler getShouldGetCPUHighLog]) {
                if (m_powerConsumeStackCollector && [m_powerConsumeStackCollector isCPUHighBlock]) {
                    return EDumpType_CPUBlock;  // 返回CPU卡顿类型
                }
            }
        }
    }

    // ============================================================================
    // 3. 内存监控（周期性打印）
    // ============================================================================

    if (m_printMemoryTickTok < PRINT_MEMORY_USE_INTERVAL) {
        // 当计时器刚好到达打印间隔时打印
        if ((m_printMemoryTickTok % PRINT_MEMORY_USE_INTERVAL) == 0) {
            // 获取内存占用（footprint）
            uint64_t footprint = matrix_footprintMemory();
            uint64_t footprintMB = footprint / 1024 / 1024;
            
            // 获取可用内存
            uint64_t available = matrix_availableMemory();
            uint64_t availableMB = available / 1024 / 1024;
            
            // 根据内存占用大小选择日志级别
            if (footprintMB > 400) {
                MatrixInfo(@"check memory footprint %llu MB, available: %llu MB", footprintMB, availableMB);
            } else {
                MatrixDebug(@"check memory footprint %llu MB, available: %llu MB", footprintMB, availableMB);
            }
            
            // 如果内存占用超过阈值，通知代理
            if (footprintMB > [_monitorConfigHandler getMemoryWarningThresholdInMB]) {
                BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate, @selector(onBlockMonitorMemoryExcessive:), onBlockMonitorMemoryExcessive:self);
            }
        }
        
        // 累加计时器（每次check调用时增加一个检查周期的时间）
        // 注意：这里使用 g_CheckPeriodTime 而不是 m_nIntervalTime
        // 因为内存监控需要固定间隔，不受退火算法影响
        m_printMemoryTickTok += g_CheckPeriodTime;
        
        // 如果达到或超过打印间隔，重置计时器
        if (m_printMemoryTickTok >= PRINT_MEMORY_USE_INTERVAL) {
            m_printMemoryTickTok = 0;
        }
    }

    // ============================================================================
    // 4. 热状态监控（周期性打印）
    // ============================================================================
    
#if defined(__arm64__)
    if (m_printCPUFrequencyTickTok < PRINT_CPU_FREQUENCY_INTERVAL) {
        // 当计时器刚好到达打印间隔时打印
        if ((m_printCPUFrequencyTickTok % PRINT_CPU_FREQUENCY_INTERVAL) == 0) {
            if (@available(iOS 11.0, *)) {
                // 获取设备热状态（温度状态）
                NSProcessInfoThermalState state = [[NSProcessInfo processInfo] thermalState];
                
                /**
                 * 热状态级别：
                 * - NSProcessInfoThermalStateNominal: 正常（0级）
                 * - NSProcessInfoThermalStateFair: 轻微升温（1级）
                 * - NSProcessInfoThermalStateSerious: 明显升温（2级）
                 * - NSProcessInfoThermalStateCritical: 严重升温（3级）
                 */
                if (state == NSProcessInfoThermalStateFair) {
                    MatrixInfo(@"check thermal state in 'level 1' high");
                } else if (state == NSProcessInfoThermalStateSerious) {
                    MatrixInfo(@"check thermal state in 'level 2' high");
                } else if (state == NSProcessInfoThermalStateCritical) {
                    MatrixInfo(@"check thermal state in 'level 3' high");
                } else {
                    MatrixInfo(@"check thermal state OK");
                }
            }
        }
        
        // 累加计时器
        m_printCPUFrequencyTickTok += g_CheckPeriodTime;
        
        // 如果达到或超过打印间隔，重置计时器
        if (m_printCPUFrequencyTickTok >= PRINT_CPU_FREQUENCY_INTERVAL) {
            m_printCPUFrequencyTickTok = 0;
        }
    }
#endif

    // ============================================================================
    // 5. 无卡顿
    // ============================================================================
    
    return EDumpType_Unlag;
}

/**
 * 判断是否需要过滤当前卡顿
 * 
 * 过滤策略：
 * 1. 无意义堆栈：堆栈深度 <= 1，过滤
 * 2. 退火算法：连续多次检测到相同堆栈，延长检查间隔，减少检测频率
 * 3. 上报限制：每日上报次数超过限制，过滤
 * 
 * 退火算法（Simulated Annealing）：
 * - 如果连续检测到相同的主线程堆栈，说明主线程一直卡在同一处
 * - 此时不需要频繁检测和上报，增加检查间隔以节省性能
 * - 间隔增长规律：m_nIntervalTime = m_nLastTimeInterval + m_nIntervalTime（类似斐波那契）
 * - 例如：1s -> 2s -> 3s -> 5s -> 8s -> 13s ...
 * 
 * @return EFilterType 过滤类型
 */
- (EFilterType)needFilter {
    BOOL bIsSame = NO;
    static std::vector<NSUInteger> vecCallStack(300);  // 当前堆栈临时存储
    __block NSUInteger nSum = 0;

    // ============================================================================
    // 1. 获取当前主线程堆栈
    // ============================================================================
    
    if (g_MainThreadHandle) {
        // 如果开启了主线程堆栈采集，从处理器中获取最近一次的堆栈
        nSum = [m_pointMainThreadHandler getLastMainThreadStackCount];
        uintptr_t *stack = [m_pointMainThreadHandler getLastMainThreadStack];
        if (stack) {
            // 复制堆栈到临时数组
            for (size_t i = 0; i < nSum; i++) {
                vecCallStack[i] = stack[i];
            }
        } else {
            nSum = 0;
        }
    } else {
        // 如果未开启主线程堆栈采集，实时获取当前堆栈
        [WCGetMainThreadUtil getCurrentMainThreadStack:^(NSUInteger pc) {
            if (nSum < WXGBackTraceMaxEntries) {
                vecCallStack[nSum] = pc;
            }
            nSum++;
        }];
    }

    // ============================================================================
    // 2. 过滤无意义堆栈
    // ============================================================================
    
    if (nSum <= 1) {
        MatrixInfo(@"filter meaningless stack");
        return EFilterType_Meaningless;
    }

    // ============================================================================
    // 3. 比对当前堆栈与上一次堆栈是否相同
    // ============================================================================
    
    if (nSum == m_lastMainThreadStackCount) {
        NSUInteger index = 0;
        // 逐个比对堆栈地址
        for (index = 0; index < nSum; index++) {
            if (vecCallStack[index] != m_vecLastMainThreadCallStack[index]) {
                break;  // 发现不同，跳出循环
            }
        }
        // 如果所有地址都相同，则认为堆栈相同
        if (index == nSum) {
            bIsSame = YES;
        }
    }

    // ============================================================================
    // 4. 根据堆栈比对结果，应用退火算法或重置
    // ============================================================================
    
    if (bIsSame) {
        // 堆栈相同 -> 应用退火算法，延长检查间隔
        NSUInteger lastTimeInterval = m_nIntervalTime;
        m_nIntervalTime = m_nLastTimeInterval + m_nIntervalTime;  // 斐波那契式增长
        m_nLastTimeInterval = lastTimeInterval;
        MatrixInfo(@"call stack same timeinterval = %lu", (unsigned long)m_nIntervalTime);
        return EFilterType_Annealing;  // 返回退火过滤类型
    } else {
        // 堆栈不同 -> 重置检查间隔
        m_nIntervalTime = g_CheckPeriodTime;  // 恢复默认检查周期
        m_nLastTimeInterval = m_nIntervalTime;

        // ============================================================================
        // 5. 更新保存的上一次堆栈
        // ============================================================================
        
        m_vecLastMainThreadCallStack.clear();
        m_lastMainThreadStackCount = 0;
        for (NSUInteger index = 0; index < nSum; index++) {
            m_vecLastMainThreadCallStack.push_back(vecCallStack[index]);
            m_lastMainThreadStackCount++;
        }

        // ============================================================================
        // 6. 检查每日上报次数限制
        // ============================================================================
        
        NSUInteger reportCount = [m_stackHandler addStackFeat:0]; // 传入0当作简单计数器
        if (reportCount > [_monitorConfigHandler getDumpDailyLimit]) {
            MatrixInfo(@"exceeds report limit today, count:[%lu]", reportCount);
            return EFilterType_TrigerByTooMuch;  // 超过每日上报限制
        }

        MatrixInfo(@"call stack diff");
        return EFilterType_None;  // 不过滤，可以上报
    }
}

/**
 * 重置监控状态
 * 
 * 在以下情况调用：
 * 1. 检测结果为无卡顿（EDumpType_Unlag）
 * 2. 准备开始新一轮监控
 * 
 * 重置内容：
 * 1. 退火算法相关变量（检查间隔恢复为默认值）
 * 2. 卡顿时长清零
 * 3. 上一次的主线程堆栈清空
 * 4. 如果RunLoop阈值已更新，重新初始化主线程堆栈处理器
 * 
 * 线程安全：
 * - 此方法在监控线程（m_monitorThread）中执行
 * - m_pointMainThreadHandler的所有读写都在同一线程，无需加锁
 */
- (void)resetStatus {
    // ============================================================================
    // 1. 重置退火算法相关变量
    // ============================================================================
    
    m_nIntervalTime = g_CheckPeriodTime;  // 恢复默认检查间隔
    m_nLastTimeInterval = m_nIntervalTime;
    
    // ============================================================================
    // 2. 重置卡顿时长
    // ============================================================================
    
    m_blockDiffTime = 0;
    
    // ============================================================================
    // 3. 清空上一次的主线程堆栈（用于退火算法比对）
    // ============================================================================
    
    m_vecLastMainThreadCallStack.clear();
    m_lastMainThreadStackCount = 0;
    
    // ============================================================================
    // 4. 清空转储文件路径
    // ============================================================================
    
    m_potenHandledLagFile = nil;

    // ============================================================================
    // 5. 如果RunLoop阈值已更新，重新初始化主线程堆栈处理器
    // ============================================================================
    
    // 注意：此处对 m_pointMainThreadHandler 的更改，和其他地方对它的读写，
    // 都在 m_monitorThread 线程里执行，避免线程安全问题
    if (g_runloopThresholdUpdated) {
        g_runloopThresholdUpdated = NO;
        
        // 重新计算循环数组大小
        // 因为阈值变化会导致检查周期变化，进而影响循环数组大小
        g_MainThreadCount = g_CheckPeriodTime / g_PerStackInterval;
        
        // 重新创建主线程堆栈处理器
        m_pointMainThreadHandler = [[WCMainThreadHandler alloc] initWithCycleArrayCount:g_MainThreadCount];
    }
}

// ============================================================================
#pragma mark - Runloop Observer & Call back
// ============================================================================

- (void)addRunLoopObserver {
    NSRunLoop *curRunLoop = [NSRunLoop currentRunLoop];

    // the first observer
    CFRunLoopObserverContext context = { 0, (__bridge void *)self, NULL, NULL, NULL };
    CFRunLoopObserverRef beginObserver =
    CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAllActivities, YES, LONG_MIN, &myRunLoopBeginCallback, &context);
    CFRetain(beginObserver);
    m_runLoopBeginObserver = beginObserver;

    // the last observer
    CFRunLoopObserverRef endObserver =
    CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAllActivities, YES, LONG_MAX, &myRunLoopEndCallback, &context);
    CFRetain(endObserver);
    m_runLoopEndObserver = endObserver;

    CFRunLoopRef runloop = [curRunLoop getCFRunLoop];
    CFRunLoopAddObserver(runloop, beginObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(runloop, endObserver, kCFRunLoopCommonModes);

    // for InitializationRunLoopMode
    CFRunLoopObserverContext initializationContext = { 0, (__bridge void *)self, NULL, NULL, NULL };
    m_initializationBeginRunloopObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                                                   kCFRunLoopAllActivities,
                                                                   YES,
                                                                   LONG_MIN,
                                                                   &myInitializetionRunLoopBeginCallback,
                                                                   &initializationContext);
    CFRetain(m_initializationBeginRunloopObserver);

    m_initializationEndRunloopObserver =
    CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAllActivities, YES, LONG_MAX, &myInitializetionRunLoopEndCallback, &initializationContext);
    CFRetain(m_initializationEndRunloopObserver);

    CFRunLoopAddObserver(runloop, m_initializationBeginRunloopObserver, (CFRunLoopMode) @"UIInitializationRunLoopMode");
    CFRunLoopAddObserver(runloop, m_initializationEndRunloopObserver, (CFRunLoopMode) @"UIInitializationRunLoopMode");
}

- (void)removeRunLoopObserver {
    NSRunLoop *curRunLoop = [NSRunLoop currentRunLoop];

    CFRunLoopRef runloop = [curRunLoop getCFRunLoop];
    CFRunLoopRemoveObserver(runloop, m_runLoopBeginObserver, kCFRunLoopCommonModes);
    CFRunLoopRemoveObserver(runloop, m_runLoopBeginObserver, (CFRunLoopMode) @"UIInitializationRunLoopMode");

    CFRunLoopRemoveObserver(runloop, m_runLoopEndObserver, kCFRunLoopCommonModes);
    CFRunLoopRemoveObserver(runloop, m_runLoopEndObserver, (CFRunLoopMode) @"UIInitializationRunLoopMode");
}

/**
 * RunLoop 开始回调（默认模式）
 * 
 * 此回调的 Observer 优先级设置为 LONG_MIN，确保在所有其他 Observer 之前执行
 * 用于标记 RunLoop 开始处理任务的时刻
 * 
 * RunLoop 活动状态流程：
 * Entry -> BeforeTimers -> BeforeSources -> BeforeWaiting
 *                                              ↓
 *                                         AfterWaiting -> BeforeTimers -> ...
 * 
 * @param observer RunLoop观察者
 * @param activity RunLoop活动状态
 * @param info 用户信息（此处未使用）
 */
void myRunLoopBeginCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    g_runLoopActivity = activity;  // 记录当前活动状态
    g_runLoopMode = eRunloopDefaultMode;  // 标记为默认模式
    
    switch (activity) {
        case kCFRunLoopEntry:
            // RunLoop 进入
            g_bRun = YES;
            break;

        case kCFRunLoopBeforeTimers:
            // 即将处理 Timer
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);  // 记录开始时间
            }
            g_bRun = YES;
            break;

        case kCFRunLoopBeforeSources:
            // 即将处理 Source
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);  // 记录开始时间
            }
            g_bRun = YES;
            break;

        case kCFRunLoopAfterWaiting:
            // 从休眠中唤醒
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);  // 记录开始时间
            }
            g_bRun = YES;
            break;

        case kCFRunLoopAllActivities:
            break;

        default:
            break;
    }
}

/**
 * RunLoop 结束回调（默认模式）
 * 
 * 此回调的 Observer 优先级设置为 LONG_MAX，确保在所有其他 Observer 之后执行
 * 用于标记 RunLoop 完成任务处理的时刻
 * 
 * @param observer RunLoop观察者
 * @param activity RunLoop活动状态
 * @param info 用户信息（此处未使用）
 */
void myRunLoopEndCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    g_runLoopActivity = activity;  // 记录当前活动状态
    g_runLoopMode = eRunloopDefaultMode;  // 标记为默认模式
    
    switch (activity) {
        case kCFRunLoopBeforeWaiting:
            // 即将进入休眠
            
            // 如果开启了敏感的 RunLoop 卡顿检测，检查本次循环时长
            if (g_bSensitiveRunloopHangDetection && g_bRun) {
                [WCBlockMonitorMgr checkRunloopDuration];
            }
            
            gettimeofday(&g_tvRun, NULL);  // 更新时间（此时RunLoop即将休眠）
            g_bRun = NO;  // 标记RunLoop不再运行
            break;

        case kCFRunLoopExit:
            // RunLoop 退出
            g_bRun = NO;
            break;

        case kCFRunLoopAllActivities:
            break;

        default:
            break;
    }
}

void myInitializetionRunLoopBeginCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    g_runLoopActivity = activity;
    g_runLoopMode = eRunloopInitMode;
    switch (activity) {
        case kCFRunLoopEntry:
            g_bRun = YES;
            g_bLaunchOver = NO;
            break;

        case kCFRunLoopBeforeTimers:
            gettimeofday(&g_tvRun, NULL);
            g_bRun = YES;
            g_bLaunchOver = NO;
            break;

        case kCFRunLoopBeforeSources:
            gettimeofday(&g_tvRun, NULL);
            g_bRun = YES;
            g_bLaunchOver = NO;
            break;

        case kCFRunLoopAfterWaiting:
            gettimeofday(&g_tvRun, NULL);
            g_bRun = YES;
            g_bLaunchOver = NO;
            break;

        case kCFRunLoopAllActivities:
            break;
        default:
            break;
    }
}

void myInitializetionRunLoopEndCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    g_runLoopActivity = activity;
    g_runLoopMode = eRunloopInitMode;
    switch (activity) {
        case kCFRunLoopBeforeWaiting:
            gettimeofday(&g_tvRun, NULL);
            g_bRun = NO;
            g_bLaunchOver = YES;
            break;

        case kCFRunLoopExit:
            g_bRun = NO;
            g_bLaunchOver = YES;
            break;

        case kCFRunLoopAllActivities:
            break;

        default:
            break;
    }
}

// ============================================================================
#pragma mark - NSApplicationEvent
// ============================================================================

#if TARGET_OS_OSX

+ (void)signalEventStart {
    gettimeofday(&g_tvEvent, NULL);
    g_eventStart = YES;
}

+ (void)signalEventEnd {
    g_eventStart = NO;
}

#endif

// ============================================================================
#pragma mark - Lag File
// ============================================================================

- (NSString *)dumpFileWithType:(EDumpType)dumpType {
    NSString *dumpFileName = @"";
    if (g_bLaunchOver) {
        BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                        @selector(onBlockMonitor:beginDump:blockTime:runloopThreshold:),
                                        onBlockMonitor:self beginDump:dumpType blockTime:m_blockDiffTime runloopThreshold:g_RunLoopTimeOut);
        dumpFileName = [WCDumpInterface dumpReportWithReportType:dumpType suspendAllThreads:m_suspendAllThreads enableSnapshot:m_enableSnapshot];
    } else {
        BM_SAFE_CALL_SELECTOR_NO_RETURN(_delegate,
                                        @selector(onBlockMonitor:beginDump:blockTime:runloopThreshold:),
                                        onBlockMonitor:self beginDump:EDumpType_LaunchBlock blockTime:m_blockDiffTime runloopThreshold:g_RunLoopTimeOut);
        dumpFileName = [WCDumpInterface dumpReportWithReportType:EDumpType_LaunchBlock suspendAllThreads:m_suspendAllThreads enableSnapshot:m_enableSnapshot];
        NSString *filePath = [WCCrashBlockFileHandler getLaunchBlockRecordFilePath];
        NSData *infoData = [NSData dataWithContentsOfFile:filePath];
        if (infoData.length > 0) {
            NSString *alreadyHaveString = [[NSString alloc] initWithData:infoData encoding:NSUTF8StringEncoding];
            alreadyHaveString = [NSString stringWithFormat:@"%@,%@", alreadyHaveString, dumpFileName];
            MatrixInfo(@"current launch lag file: %@", alreadyHaveString);
            [alreadyHaveString writeToFile:filePath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        } else {
            MatrixInfo(@"current launch lag file: %@", dumpFileName);
            [dumpFileName writeToFile:filePath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    }
    return dumpFileName;
}

// ============================================================================
#pragma mark - Launch Lag
// ============================================================================

- (void)clearLaunchLagRecord {
    NSString *filePath = [WCCrashBlockFileHandler getLaunchBlockRecordFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        MatrixInfo(@"launch over, clear dump file record");
    }
}

- (void)clearDumpInBackgroundLaunch {
    NSString *filePath = [WCCrashBlockFileHandler getLaunchBlockRecordFilePath];
    NSString *infoString = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    if (infoString && infoString.length > 0) {
        NSArray *dumpFileArray = [infoString componentsSeparatedByString:@","];
        for (NSString *dumpFile in dumpFileArray) {
            [fileMgr removeItemAtPath:dumpFile error:nil];
            MatrixWarning(@"remove wrong launch lag: %@", dumpFile);
        }
    }
    [fileMgr removeItemAtPath:filePath error:nil];
}

// ============================================================================
#pragma mark - CPU
// ============================================================================

- (void)startTrackCPU {
    m_bTrackCPU = YES;
}

- (void)stopTrackCPU {
    m_bTrackCPU = NO;
}

- (BOOL)isBackgroundCPUTooSmall {
    return [m_cpuHandler isBackgroundCPUTooSmall];
}

// ============================================================================
#pragma mark - Hangs Detection
// ============================================================================

- (BOOL)lowerRunloopThreshold {
    useconds_t lowThreshold = [_monitorConfigHandler getRunloopLowThreshold];
    useconds_t defaultThreshold = [_monitorConfigHandler getRunloopTimeOut];

    if (lowThreshold > defaultThreshold) {
        MatrixWarning(@"Failed to lower runloop threshold: lowThreshold [%u] > defaultThreshold [%u].", lowThreshold, defaultThreshold);
        return NO;
    }

    return [self setRunloopThreshold:lowThreshold];
}

- (BOOL)recoverRunloopThreshold {
    useconds_t defaultThreshold = [_monitorConfigHandler getRunloopTimeOut];
    return [self setRunloopThreshold:defaultThreshold];
}

- (BOOL)setRunloopThreshold:(useconds_t)threshold {
    return [self setRunloopThreshold:threshold isFirstTime:NO];
}

/**
 * 设置RunLoop超时阈值（支持动态调整）
 * 
 * 阈值约束：
 * - 范围：[400ms, 2s]
 * - 必须是100ms的整数倍
 * - 检查周期 = 阈值 / 2
 * - 检查周期必须是堆栈采集间隔（50ms）的整数倍
 * 
 * 动态调整说明：
 * - 可以在运行时动态降低阈值，实现更敏感的卡顿检测
 * - 也可以恢复到默认阈值
 * - 阈值变化后，会在下次resetStatus时重新初始化主线程堆栈处理器
 * 
 * @param threshold 新的超时阈值（微秒）
 * @param isFirstTime 是否首次设置（首次设置跳过动态阈值检查）
 * @return 设置成功返回YES，失败返回NO
 */
- (BOOL)setRunloopThreshold:(useconds_t)threshold isFirstTime:(BOOL)isFirstTime {
    // ============================================================================
    // 1. 检查是否支持动态阈值
    // ============================================================================
    
    if (!isFirstTime && ![_monitorConfigHandler getRunloopDynamicThresholdEnabled]) {
        MatrixInfo(@"Failed to set runloop threshold: dynamic threshold isn't supported on this device.");
        return NO;
    }

    // ============================================================================
    // 2. 验证阈值范围
    // ============================================================================
    
    if (threshold < (400 * BM_MicroFormat_MillSecond) || threshold > (2 * BM_MicroFormat_Second)) {
        MatrixWarning(@"Failed to set runloop threshold: %u isn't in the range of [400ms, 2s].", threshold);
        return NO;
    }

    // ============================================================================
    // 3. 验证阈值必须是100ms的整数倍
    // ============================================================================
    
    if (threshold % (100 * BM_MicroFormat_MillSecond) != 0) {
        MatrixWarning(@"Failed to set runloop threshold: %u isn't a multiple of 100ms.", threshold);
        return NO;
    }

    // ============================================================================
    // 4. 如果阈值没有变化，直接返回成功
    // ============================================================================
    
    if (threshold == g_RunLoopTimeOut) {
        MatrixInfo(@"Set runloop threshold: same as current value.");
        return YES;
    }

    // ============================================================================
    // 5. 计算检查周期（阈值的一半）
    // ============================================================================
    
    useconds_t checkPeriodTime = threshold / 2;
    assert(checkPeriodTime % g_PerStackInterval == 0); // 确保是50ms的整数倍

    // ============================================================================
    // 6. 更新全局阈值变量
    // ============================================================================
    
    useconds_t previousRunLoopTimeOut = g_RunLoopTimeOut;
    useconds_t previousCheckPeriodTime = g_CheckPeriodTime;
    g_RunLoopTimeOut = threshold;
    g_CheckPeriodTime = checkPeriodTime;

    // ============================================================================
    // 7. 标记需要更新主线程堆栈处理器
    // ============================================================================
    
    if (!isFirstTime) {
        // 设置标志，在下一次 resetStatus 时重新初始化主线程堆栈处理器
        // 这是因为循环数组大小 = checkPeriodTime / stackInterval，阈值变化会导致数组大小变化
        g_runloopThresholdUpdated = YES;
    }

    MatrixInfo(@"Set runloop threshold: before[%u] after[%u], check period: before[%u] after[%u]", 
               previousRunLoopTimeOut, g_RunLoopTimeOut, previousCheckPeriodTime, g_CheckPeriodTime);

    return YES;
}

/**
 * 检查RunLoop单次循环时长（敏感卡顿检测）
 * 
 * 此方法在主线程的RunLoop即将进入休眠时调用（kCFRunLoopBeforeWaiting）
 * 用于检测单次RunLoop循环是否超过Apple HangTracer的阈值（250ms）
 * 
 * 与常规卡顿检测的区别：
 * - 常规检测：在监控线程中周期性检查，阈值较高（通常 >= 2s）
 * - 敏感检测：在主线程每次RunLoop结束时检查，阈值较低（250ms）
 * 
 * 注意：
 * - 此方法在主线程执行，必须尽快返回，避免影响主线程性能
 * - 实际处理逻辑异步到后台线程执行
 * 
 * Apple HangTracer：
 * - 系统级卡顿监控工具，阈值为250ms
 * - 此检测与HangTracer对齐，可以更早发现卡顿
 */
+ (void)checkRunloopDuration {
    assert(g_bSensitiveRunloopHangDetection);  // 必须开启敏感检测
    assert(g_bRun);  // RunLoop必须正在运行

    // ============================================================================
    // 注意：此代码在主线程频繁执行，必须保持轻量级
    // ============================================================================
    
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);
    
    // 计算本次RunLoop循环的时长
    unsigned long long duration = [WCBlockMonitorMgr diffTime:&g_tvRun endTime:&tvCur];

    // ============================================================================
    // 判断是否超过Apple HangTracer的阈值（250ms）
    // ============================================================================
    
    if ((duration > 250 * BM_MicroFormat_MillSecond) && (duration < 60 * BM_MicroFormat_Second)) {
        // 立即离开主线程，避免阻塞
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // 如果正在调试，只记录日志，不上报
            if ([MatrixDeviceInfo isBeingDebugged]) {
                MatrixInfo(@"Runloop hang detected: %llu ms (debugger attached, not reporting)", duration / 1000);
            } else {
                // 检测到卡顿，通知代理
                MatrixInfo(@"Runloop hang detected: %llu ms", duration / 1000);
                WCBlockMonitorMgr *blockMonitorMgr = [WCBlockMonitorMgr shareInstance];
                BM_SAFE_CALL_SELECTOR_NO_RETURN(blockMonitorMgr.delegate,
                                                @selector(onBlockMonitor:runloopHangDetected:),
                                                onBlockMonitor:blockMonitorMgr runloopHangDetected:duration);
            }
        });
    }
}

- (void)setShouldSuspendAllThreads:(BOOL)dynamicConfig {
    BOOL staticConfig = [_monitorConfigHandler getShouldSuspendAllThreads];
    m_suspendAllThreads = staticConfig && dynamicConfig;
    MatrixInfo(@"setShouldSuspendAllThreads: dynamicConfig = %d, staticConfig = %d", dynamicConfig, staticConfig);
}

// ============================================================================
#pragma mark - Custom Dump
// ============================================================================

- (void)generateLiveReportWithDumpType:(EDumpType)dumpType withReason:(NSString *)reason selfDefinedPath:(BOOL)bSelfDefined {
    [WCDumpInterface dumpReportWithReportType:dumpType
                          withExceptionReason:reason
                            suspendAllThreads:m_suspendAllThreads
                               enableSnapshot:m_enableSnapshot
                                writeCpuUsage:NO
                              selfDefinedPath:bSelfDefined];
}

// ============================================================================
#pragma mark - WCPowerConsumeStackCollectorDelegate
// ============================================================================

- (void)powerConsumeStackCollectorConclude:(NSArray<NSDictionary *> *)stackTree {
    dispatch_async(m_asyncDumpQueue, ^{
        if (stackTree == nil) {
            MatrixInfo(@"save battery cost stack log, but stack tree is empty");
            return;
        }
        MatrixInfo(@"save battery cost stack log");
        NSString *reportID = [[NSUUID UUID] UUIDString];
        NSData *reportData = [WCGetCallStackReportHandler getReportJsonDataWithPowerConsumeStack:stackTree
                                                                                    withReportID:reportID
                                                                                    withDumpType:EDumpType_PowerConsume];
        [WCDumpInterface saveDump:reportData withReportType:EDumpType_PowerConsume withReportID:reportID];
    });
}

// ============================================================================
#pragma mark - Utility
// ============================================================================

+ (unsigned long long)diffTime:(struct timeval *)tvStart endTime:(struct timeval *)tvEnd {
    return 1000000 * (tvEnd->tv_sec - tvStart->tv_sec) + tvEnd->tv_usec - tvStart->tv_usec;
}

@end
