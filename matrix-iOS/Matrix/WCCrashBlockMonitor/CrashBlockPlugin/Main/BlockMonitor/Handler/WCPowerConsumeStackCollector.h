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
#import "KSStackCursor_Backtrace.h"

// ============================================================================
#pragma mark - WCStackTracePool
// ============================================================================

/**
 * ============================================================================
 * WCStackTracePool - 堆栈追踪池
 * ============================================================================
 * 
 * 职责：
 * - 维护一个循环数组，存储最近的堆栈信息
 * - 每个堆栈关联CPU使用率和前后台状态
 * - 生成调用树（Call Tree）用于火焰图分析
 * 
 * 数据结构：
 * - 循环数组：最多存储100个堆栈（可配置）
 * - 每个堆栈包含：
 *   * 地址数组（uintptr_t*）
 *   * 堆栈深度（size_t）
 *   * CPU使用率（float）
 *   * 是否后台采集（BOOL）
 * 
 * 调用树生成：
 * 1. 遍历所有堆栈
 * 2. 构建地址帧（Address Frame）树结构
 * 3. 合并相同的调用路径，累加重复次数
 * 4. 按重复次数排序
 * 5. 符号化地址（地址 -> 函数名）
 * 6. 转换为字典数组
 * 
 * 使用场景：
 * - CPU耗电分析
 * - 识别CPU热点函数
 * - 生成火焰图数据
 * ============================================================================
 */
@interface WCStackTracePool : NSObject

/**
 * 初始化堆栈池
 * 
 * @param maxStackTraceCount 最大堆栈数量，通常为100
 * @return WCStackTracePool实例
 * 
 * 说明：
 * - 使用循环数组实现，当达到最大数量时，新堆栈会覆盖最旧的
 * - 内部会分配4个数组：堆栈地址、长度、CPU、前后台状态
 */
- (id)initWithMaxStackTraceCount:(NSUInteger)maxStackTraceCount;

/**
 * 添加线程堆栈到池中
 * 
 * @param stackArray 堆栈地址数组（调用者负责释放）
 * @param stackCount 堆栈深度（地址数量）
 * @param stackCPU 该线程的CPU使用率（百分比）
 * @param isInBackground 是否在后台采集
 * 
 * 说明：
 * - 堆栈数组会被复制到池中，原数组由调用者管理
 * - 使用循环数组，自动覆盖最旧的堆栈
 * - CPU使用率用于生成调用树时的权重计算
 */
- (void)addThreadStack:(uintptr_t *)stackArray andLength:(size_t)stackCount andCPU:(float)stackCPU isInBackground:(BOOL)isInBackground;

/**
 * 生成调用树（Call Tree）
 * 
 * @return 调用树数组，每个元素是一个字典，包含：
 *         - address：函数地址（字符串）
 *         - symbol：函数符号（函数名）
 *         - repeat_count：出现次数
 *         - cpu_percent：CPU占比
 *         - children：子调用数组（递归结构）
 * 
 * 算法流程：
 * 1. 遍历所有堆栈，构建地址帧树
 * 2. 合并相同的调用路径
 * 3. 按重复次数排序（高频调用在前）
 * 4. 符号化地址
 * 5. 转换为JSON友好的字典结构
 * 
 * 使用场景：
 * - 生成火焰图（Flame Graph）
 * - 识别CPU热点函数
 * - 耗电分析报告
 * 
 * 示例输出：
 * [
 *   {
 *     "address": "0x100001234",
 *     "symbol": "-[MyViewController heavyMethod]",
 *     "repeat_count": 45,
 *     "cpu_percent": 75.0,
 *     "children": [
 *       {
 *         "address": "0x100005678",
 *         "symbol": "-[MyClass innerLoop]",
 *         "repeat_count": 40,
 *         "children": [...]
 *       }
 *     ]
 *   }
 * ]
 */
- (NSArray<NSDictionary *> *)makeCallTree;

@end

// ============================================================================
#pragma mark - WCPowerConsumeStackCollector
// ============================================================================

/**
 * WCPowerConsumeStackCollectorDelegate - 耗电堆栈收集器代理协议
 * 
 * 用于接收生成的耗电堆栈调用树
 */
@protocol WCPowerConsumeStackCollectorDelegate <NSObject>

/**
 * 耗电堆栈收集器生成结论回调
 * 
 * @param stackTree 调用树数组，结构同WCStackTracePool的makeCallTree返回值
 * 
 * 说明：
 * - 此回调在全局队列中异步调用
 * - stackTree可用于生成火焰图或上传到服务器分析
 */
- (void)powerConsumeStackCollectorConclude:(NSArray<NSDictionary *> *)stackTree;

@end

/**
 * ============================================================================
 * WCPowerConsumeStackCollector - 耗电堆栈收集器
 * ============================================================================
 * 
 * 职责：
 * - 在获取CPU使用率的同时，自动采集高CPU线程的堆栈
 * - 识别CPU占用高的线程
 * - 生成耗电分析报告（调用树）
 * - 为CPU卡顿转储提供堆栈数据
 * 
 * 工作流程：
 * 1. 每次check时调用getCPUUsageAndPowerConsumeStack
 * 2. 遍历App所有线程，获取CPU使用率
 * 3. 如果总CPU > 阈值，采集高CPU线程的堆栈
 * 4. 将堆栈添加到堆栈池（WCStackTracePool）
 * 5. 当触发平均CPU过高时，调用makeConclusion生成报告
 * 
 * 核心功能：
 * - 自动识别CPU占用高的线程（> 阈值）
 * - 采集线程堆栈（backtrace）
 * - 维护最近100个堆栈样本
 * - 生成火焰图式的调用树
 * 
 * 与WCCPUHandler的配合：
 * - WCCPUHandler：负责平均CPU检测算法
 * - WCPowerConsumeStackCollector：负责堆栈采集和分析
 * - 配合使用可以在检测到持续高CPU时，自动提供详细的堆栈分析
 * 
 * 使用示例：
 * ```objc
 * WCPowerConsumeStackCollector *collector = 
 *     [[WCPowerConsumeStackCollector alloc] initWithCPULimit:80.0];
 * collector.delegate = self;
 * 
 * // 在监控循环中调用
 * float cpuUsage = [collector getCPUUsageAndPowerConsumeStack];
 * 
 * // 当检测到持续高CPU时
 * [collector makeConclusion];  // 异步生成调用树，通过代理回调
 * ```
 * ============================================================================
 */
@interface WCPowerConsumeStackCollector : NSObject

/**
 * 代理对象，用于接收生成的调用树
 */
@property (nonatomic, weak) id<WCPowerConsumeStackCollectorDelegate> delegate;

/**
 * 初始化耗电堆栈收集器
 * 
 * @param cpuLimit CPU阈值（百分比），如80.0表示80%
 * @return WCPowerConsumeStackCollector实例
 * 
 * 说明：
 * - 当App总CPU使用率超过此阈值时，才会采集堆栈
 * - 内部会创建WCStackTracePool，最多存储100个堆栈
 * - 会监听前后台切换通知
 */
- (id)initWithCPULimit:(float)cpuLimit;

/**
 * 生成耗电堆栈调用树
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
 */
- (void)makeConclusion;

/**
 * 获取CPU使用率并采集耗电堆栈（核心方法）
 * 
 * @return App的CPU使用率（百分比），-1表示失败
 * 
 * 工作流程：
 * 1. 遍历App所有线程，获取每个线程的CPU使用率
 * 2. 累加得到App总CPU使用率
 * 3. 识别CPU占用高的线程（> 一定阈值）
 * 4. 如果总CPU > cpuLimit：
 *    a. 对每个高CPU线程执行backtrace
 *    b. 将堆栈添加到堆栈池
 * 5. 返回总CPU使用率
 * 
 * 技术细节：
 * - 使用task_threads获取所有线程
 * - 使用thread_info获取每个线程的CPU使用率
 * - 使用backtrace或KSStackCursor获取堆栈
 * - 自动过滤空闲线程
 * 
 * 性能考虑：
 * - 只有当CPU超过阈值时才采集堆栈，避免不必要的开销
 * - backtrace有一定性能开销，建议控制调用频率
 * 
 * 使用场景：
 * - 在WCBlockMonitorMgr的check方法中调用
 * - 替代MatrixDeviceInfo的appCpuUsage，在获取CPU的同时采集堆栈
 */
- (float)getCPUUsageAndPowerConsumeStack;

/**
 * 判断是否为CPU高占用卡顿
 * 
 * @return YES表示是CPU高占用导致的卡顿，NO表示不是
 * 
 * 说明：
 * - 当瞬时CPU过高时，调用此方法判断是否需要生成CPU卡顿转储
 * - 内部会检查当前是否有采集到高CPU线程的堆栈
 * 
 * 使用场景：
 * - 在check方法检测到瞬时CPU过高时调用
 * - 用于决定是否返回EDumpType_CPUBlock
 */
- (BOOL)isCPUHighBlock;

/**
 * 获取当前CPU高占用堆栈数量
 * 
 * @return CPU高占用线程的数量
 * 
 * 说明：
 * - 返回最近一次getCPUUsageAndPowerConsumeStack采集的高CPU线程数量
 * - 用于生成转储报告时，决定需要写入多少个堆栈
 */
- (int)getCurrentCpuHighStackNumber;

/**
 * 获取CPU高占用线程的堆栈游标数组
 * 
 * @return KSStackCursor指针数组，用于KSCrash写入堆栈
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
- (KSStackCursor **)getCPUStackCursor;

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
- (float *)getCpuHighThreadValueArray;

@end
