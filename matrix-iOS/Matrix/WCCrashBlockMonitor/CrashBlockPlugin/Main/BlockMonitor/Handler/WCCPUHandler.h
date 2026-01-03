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

/**
 * ============================================================================
 * WCCPUHandler - CPU处理器
 * ============================================================================
 * 
 * 职责：
 * - 实现平均CPU使用率检测算法（耗电检测）
 * - 防止频繁误报（退火算法）
 * - 后台CPU异常检测
 * 
 * 核心算法：
 * 1. 三态状态机：
 *    - 未追踪（m_bTracking = NO）
 *    - 追踪中（m_bTracking = YES）
 *    - 冷却中（m_tickTok > 0）
 * 
 * 2. 半区间检测（Half CPU Zone）：
 *    如果追踪期间 totalCPUCost < kOverCPULimit * totalTrackingTime / 2
 *    说明平均CPU < 40%，停止追踪
 * 
 * 3. 完整区间检测（Full CPU Zone）：
 *    追踪60秒后，如果 totalCPUCost > kOverCPULimit * totalTrackingTime
 *    说明平均CPU > 80%，触发报警
 * 
 * 4. 退火算法（Annealing Algorithm）：
 *    触发一次后进入60秒冷却期，避免频繁上报
 * 
 * 使用场景：
 * - 检测长时间的高CPU消耗
 * - 识别耗电问题
 * - 避免短暂峰值的误报
 * ============================================================================
 */
@interface WCCPUHandler : NSObject

/**
 * 初始化CPU处理器
 * 
 * @param cpuLimit CPU阈值（百分比，如80.0表示80%）
 * @return WCCPUHandler实例
 * 
 * 说明：
 * - 此阈值用于判断是否开始追踪CPU使用率
 * - 当CPU超过此阈值时，开始累积CPU消耗
 * - 默认值为80%
 */
- (id)initWithCPULimit:(float)cpuLimit;

/**
 * 培养CPU使用率（核心检测算法）
 * 
 * 此方法实现了一个智能的CPU检测算法，能够：
 * 1. 过滤短暂的CPU峰值
 * 2. 识别持续的高CPU消耗
 * 3. 通过退火算法防止频繁误报
 * 
 * @param cpuUsage 当前的CPU使用率（百分比）
 * @param periodSec 距离上次检查的时间间隔（秒）
 * @return YES表示检测到持续的高CPU消耗，NO表示正常
 * 
 * 算法流程：
 * 1. 退火检测：如果在冷却期（m_tickTok > 0），直接返回NO
 * 2. 开始追踪：当CPU > 阈值且未在追踪中，进入追踪状态
 * 3. 累积计算：m_totalCPUCost += periodSec * cpuUsage
 * 4. 半区间检测：如果CPU消耗不足，停止追踪
 * 5. 完整检测：追踪60秒后，判断是否超标
 * 6. 触发冷却：如果超标，进入60秒冷却期
 * 
 * 示例：
 * - CPU持续85%超过60秒 -> 返回YES（触发报警）
 * - CPU在85%和40%之间波动 -> 返回NO（半区间检测过滤）
 * - CPU短暂峰值95%但很快下降 -> 返回NO（不足60秒）
 * 
 * 注意：
 * - 此方法运行在监控线程中，每次check调用时执行
 * - periodSec应该在0-5秒之间，超出范围会被忽略
 */
- (BOOL)cultivateCpuUsage:(float)cpuUsage periodTime:(float)periodSec;

/**
 * 判断后台CPU是否异常低
 * 
 * @return YES表示后台CPU过低（< 6%），NO表示正常
 * 
 * 说明：
 * - 当App进入后台时，系统可能会限制其CPU使用
 * - 如果后台平均CPU < 6%，可能表示App被系统严格限制
 * - 这种情况下，某些后台任务可能无法正常执行
 * 
 * 使用场景：
 * - 检测App是否被系统限制后台执行
 * - 用于后台任务失败的原因分析
 */
- (BOOL)isBackgroundCPUTooSmall;

@end
