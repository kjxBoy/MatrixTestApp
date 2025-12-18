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
 * WCBlockMonitorMgr - 主线程卡顿监控管理器（头文件）
 * ============================================================================
 * 
 * 这是腾讯Matrix卡顿监控的公共接口，定义了：
 * 1. WCBlockMonitorDelegate 协议 - 接收卡顿检测的各种回调
 * 2. 全局回调函数 - 供KSCrash使用，获取堆栈信息
 * 3. WCBlockMonitorMgr 类 - 卡顿监控的主要管理类
 * 
 * 使用流程：
 * 1. 配置 WCBlockMonitorConfiguration
 * 2. 调用 resetConfiguration: 设置配置
 * 3. 设置 delegate 接收回调
 * 4. 调用 start 启动监控
 * 5. 在 delegate 方法中处理卡顿报告
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#import "WCBlockTypeDef.h"
#import "WCMainThreadHandler.h"

@class WCBlockMonitorConfiguration;
@class WCBlockMonitorMgr;

// ============================================================================
#pragma mark - 卡顿监控代理协议
// ============================================================================

/**
 * WCBlockMonitorDelegate - 卡顿监控代理协议
 * 
 * 实现此协议以接收各种卡顿检测事件的回调
 * 所有方法都是 @required，必须实现
 */
@protocol WCBlockMonitorDelegate <NSObject>

@required

// ============================================================================
// 监控流程回调
// ============================================================================

/**
 * 进入下一轮检查
 * 
 * 在监控线程每轮检查开始时调用
 * 
 * @param bmMgr 监控管理器实例
 * @param dumpType 本轮检查的结果类型
 *        - EDumpType_Unlag: 无卡顿
 *        - EDumpType_MainThreadBlock: 主线程卡顿
 *        - EDumpType_BackgroundMainThreadBlock: 后台主线程卡顿
 *        - EDumpType_CPUBlock: CPU过高卡顿
 */
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr enterNextCheckWithDumpType:(EDumpType)dumpType;

/**
 * 开始生成转储报告
 * 
 * 在检测到卡顿并准备生成转储文件前调用
 * 
 * @param bmMgr 监控管理器实例
 * @param dumpType 转储类型
 * @param blockTime 卡顿时长（微秒）
 * @param runloopThreshold 当前RunLoop超时阈值（微秒）
 */
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr beginDump:(EDumpType)dumpType blockTime:(uint64_t)blockTime runloopThreshold:(useconds_t)runloopThreshold;

/**
 * 卡顿被过滤
 * 
 * 当检测到卡顿但被过滤规则拦截时调用
 * 
 * @param bmMgr 监控管理器实例
 * @param dumpType 转储类型
 * @param filterType 过滤类型
 *        - EFilterType_None: 不过滤
 *        - EFilterType_Meaningless: 无意义堆栈
 *        - EFilterType_Annealing: 退火算法过滤
 *        - EFilterType_TrigerByTooMuch: 超过每日上报限制
 */
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr dumpType:(EDumpType)dumpType filter:(EFilterType)filterType;

/**
 * 获取转储文件
 * 
 * 在成功生成转储文件后调用，可以在此方法中上传报告
 * 
 * @param bmMgr 监控管理器实例
 * @param dumpFile 转储文件路径
 * @param dumpType 转储类型
 */
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr getDumpFile:(NSString *)dumpFile withDumpType:(EDumpType)dumpType;

/**
 * 获取自定义用户信息
 * 
 * 在生成转储报告时调用，可以附加自定义信息到报告中
 * 
 * @param bmMgr 监控管理器实例
 * @param dumpType 转储类型
 * @return 自定义信息字典，将被添加到转储报告中
 */
- (NSDictionary *)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr getCustomUserInfoForDumpType:(EDumpType)dumpType;

// ============================================================================
// CPU监控回调
// ============================================================================

/**
 * 当前CPU使用率过高
 * 
 * 瞬时CPU使用率超过阈值时调用
 * 
 * @param bmMgr 监控管理器实例
 */
- (void)onBlockMonitorCurrentCPUTooHigh:(WCBlockMonitorMgr *)bmMgr;

/**
 * 平均CPU使用率过高
 * 
 * 一段时间内的平均CPU使用率超过阈值时调用（耗电检测）
 * 
 * @param bmMgr 监控管理器实例
 */
- (void)onBlockMonitorIntervalCPUTooHigh:(WCBlockMonitorMgr *)bmMgr;

// ============================================================================
// 设备状态回调
// ============================================================================

/**
 * 设备热状态升高
 * 
 * 设备温度升高时调用（iOS 11.0+）
 * 
 * @param bmMgr 监控管理器实例
 */
- (void)onBlockMonitorThermalStateElevated:(WCBlockMonitorMgr *)bmMgr;

/**
 * 主线程卡顿
 * 
 * 检测到主线程卡顿时调用
 * 
 * @param bmMgr 监控管理器实例
 */
- (void)onBlockMonitorMainThreadBlock:(WCBlockMonitorMgr *)bmMgr;

/**
 * 内存占用过高
 * 
 * 内存占用超过阈值时调用
 * 
 * @param bmMgr 监控管理器实例
 */
- (void)onBlockMonitorMemoryExcessive:(WCBlockMonitorMgr *)bmMgr;

/**
 * RunLoop单次循环卡顿检测（敏感检测）
 * 
 * 单次RunLoop循环超过250ms时调用
 * 这是Apple HangTracer的阈值，比常规卡顿检测更敏感
 * 
 * @param bmMgr 监控管理器实例
 * @param duration 本次RunLoop循环时长（微秒）
 */
- (void)onBlockMonitor:(WCBlockMonitorMgr *)bmMgr runloopHangDetected:(uint64_t)duration;

@end

// ============================================================================
#pragma mark - 全局回调函数（供KSCrash使用）
// ============================================================================

/**
 * 获取最有可能导致卡顿的主线程堆栈（Point Stack）
 * 
 * 此函数供KSCrash在生成崩溃报告时调用
 * 返回通过Point Stack算法分析得出的最耗时堆栈
 * 
 * @return Point Stack的KSStackCursor指针，如果没有则返回NULL
 */
KSStackCursor *kscrash_pointThreadCallback(void);

/**
 * 获取主线程堆栈中每个地址的重复次数数组
 * 
 * 返回Point Stack中每个地址在所有堆栈中的总出现次数
 * 数组长度等于Point Stack的深度
 * 
 * @return 重复次数数组指针
 */
int *kscrash_pointThreadRepeatNumberCallback(void);

/**
 * 获取主线程堆栈Profile（调用树）
 * 
 * 返回JSON格式的堆栈调用树，包含所有采集的堆栈数据
 * 可用于生成火焰图或调用树可视化
 * 
 * @return Profile JSON数据指针（char*）
 */
char *kscrash_pointThreadProfileCallback(void);

/**
 * 获取CPU占用高的线程堆栈数组
 * 
 * 返回CPU占用最高的若干个线程的堆栈
 * 用于CPU过高卡顿分析
 * 
 * @return KSStackCursor数组指针
 */
KSStackCursor **kscrash_pointCPUHighThreadCallback(void);

/**
 * 获取CPU占用高的线程数量
 * 
 * @return CPU占用高的线程数量
 */
int kscrash_pointCpuHighThreadCountCallback(void);

/**
 * 获取CPU占用高的线程对应的CPU使用率数组
 * 
 * 返回每个CPU占用高的线程对应的CPU使用率
 * 数组长度等于CPU占用高的线程数量
 * 
 * @return CPU使用率数组指针（float*）
 */
float *kscrash_pointCpuHighThreadArrayCallBack(void);

// ============================================================================
#pragma mark - 卡顿监控管理器
// ============================================================================

/**
 * WCBlockMonitorMgr - 卡顿监控管理器
 * 
 * 主要功能：
 * 1. 主线程卡顿检测（RunLoop超时检测）
 * 2. CPU使用率监控
 * 3. 内存监控
 * 4. 设备热状态监控
 * 5. 生成卡顿转储报告
 * 
 * 使用示例：
 * ```objc
 * // 1. 配置
 * WCBlockMonitorConfiguration *config = [WCBlockMonitorConfiguration defaultConfig];
 * config.runloopTimeOut = 2000000;  // 2秒
 * 
 * // 2. 设置代理和配置
 * WCBlockMonitorMgr *monitor = [WCBlockMonitorMgr shareInstance];
 * monitor.delegate = self;
 * [monitor resetConfiguration:config];
 * 
 * // 3. 启动监控
 * [monitor start];
 * 
 * // 4. 停止监控
 * [monitor stop];
 * ```
 */
@interface WCBlockMonitorMgr : NSObject

/// 卡顿监控代理，接收各种监控事件回调
@property (nonatomic, weak) id<WCBlockMonitorDelegate> delegate;

// ============================================================================
#pragma mark - 基本控制
// ============================================================================

/**
 * 获取单例实例
 * 
 * @return WCBlockMonitorMgr单例
 */
+ (WCBlockMonitorMgr *)shareInstance;

/**
 * 重置配置
 * 
 * 在启动监控前调用，设置各种监控参数
 * 
 * @param bmConfig 监控配置对象
 */
- (void)resetConfiguration:(WCBlockMonitorConfiguration *)bmConfig;

/**
 * 启动卡顿监控
 * 
 * 启动监控后会：
 * 1. 在主线程的RunLoop上注册Observer
 * 2. 创建独立的监控线程
 * 3. 开始周期性检测和堆栈采集
 */
- (void)start;

/**
 * 停止卡顿监控
 * 
 * 停止监控后会：
 * 1. 移除RunLoop Observer
 * 2. 停止监控线程
 * 3. 清理资源
 */
- (void)stop;

// ============================================================================
#pragma mark - 优化和特殊场景处理
// ============================================================================

#if !TARGET_OS_OSX

/**
 * 处理后台启动
 * 
 * 当App通过Voip Push或BackgroundFetch后台启动时调用
 * 用于避免后台启动期间的误报
 */
- (void)handleBackgroundLaunch;

/**
 * 处理挂起
 * 
 * 当App进入后台挂起时调用
 * 记录挂起时间，用于过滤挂起恢复时的误报
 */
- (void)handleSuspend;

#endif

// ============================================================================
#pragma mark - CPU监控控制
// ============================================================================

/**
 * 开始跟踪CPU使用率
 * 
 * 开始监控App和设备的CPU使用率
 */
- (void)startTrackCPU;

/**
 * 停止跟踪CPU使用率
 * 
 * 停止监控CPU使用率，节省性能开销
 */
- (void)stopTrackCPU;

/**
 * 判断后台CPU是否过低
 * 
 * 检查App在后台时的CPU使用率是否异常低
 * 可能表示App被系统限制
 * 
 * @return YES表示后台CPU过低，NO表示正常
 */
- (BOOL)isBackgroundCPUTooSmall;

// ============================================================================
#pragma mark - 卡顿检测参数动态调整
// ============================================================================

/**
 * 设置RunLoop超时阈值
 * 
 * 动态调整卡顿检测的时间阈值
 * 
 * 约束：
 * - 范围：[400ms, 2s]
 * - 必须是100ms的整数倍
 * - 检查周期自动设置为阈值的一半
 * 
 * @param threshold 新的超时阈值（微秒）
 * @return 设置成功返回YES，失败返回NO
 */
- (BOOL)setRunloopThreshold:(useconds_t)threshold;

/**
 * 降低RunLoop超时阈值
 * 
 * 将阈值降低到配置的低阈值（runloopLowThreshold）
 * 用于实现更敏感的卡顿检测
 * 
 * @return 设置成功返回YES，失败返回NO
 */
- (BOOL)lowerRunloopThreshold;

/**
 * 恢复RunLoop超时阈值
 * 
 * 将阈值恢复到默认值（runloopTimeOut）
 * 
 * @return 设置成功返回YES，失败返回NO
 */
- (BOOL)recoverRunloopThreshold;

/**
 * 设置是否挂起所有线程
 * 
 * 在生成转储报告时，是否挂起App的所有线程
 * 挂起线程可以获得更准确的堆栈，但会导致App短暂卡顿
 * 
 * @param shouldSuspendAllThreads YES表示挂起所有线程，NO表示不挂起
 */
- (void)setShouldSuspendAllThreads:(BOOL)shouldSuspendAllThreads;

// ============================================================================
#pragma mark - 自定义转储
// ============================================================================

/**
 * 手动生成转储报告
 * 
 * 在任意时刻手动触发转储报告生成
 * 用于特殊场景下的性能分析
 * 
 * @param dumpType 转储类型
 * @param reason 自定义原因描述
 * @param bSelfDefined 是否使用自定义路径保存报告
 */
- (void)generateLiveReportWithDumpType:(EDumpType)dumpType withReason:(NSString *)reason selfDefinedPath:(BOOL)bSelfDefined;

// ============================================================================
#pragma mark - 工具方法
// ============================================================================

/**
 * 获取当前转储的用户信息
 * 
 * 调用delegate方法获取自定义用户信息
 * 
 * @param dumpType 转储类型
 * @return 用户信息字典
 */
- (NSDictionary *)getUserInfoForCurrentDumpForDumpType:(EDumpType)dumpType;

#if TARGET_OS_OSX

/**
 * 信号事件开始（macOS）
 * 
 * 在macOS上，标记事件处理开始
 * 用于macOS平台的事件超时检测
 */
+ (void)signalEventStart;

/**
 * 信号事件结束（macOS）
 * 
 * 在macOS上，标记事件处理结束
 */
+ (void)signalEventEnd;

#endif

@end
