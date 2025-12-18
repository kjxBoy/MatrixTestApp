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
 * WCMainThreadHandler - 主线程堆栈处理器（头文件）
 * ============================================================================
 * 
 * 功能概述：
 * 管理主线程堆栈的循环数组，通过Point Stack算法找出最有可能导致卡顿的堆栈。
 * 
 * 核心算法 - Point Stack算法：
 * 1. 使用循环数组保存周期性采集的主线程堆栈
 * 2. 统计每个堆栈栈顶地址的连续重复次数
 * 3. 重复次数最多的堆栈即为Point Stack（最可能导致卡顿的堆栈）
 * 4. 统计Point Stack中每个地址在所有堆栈中的总出现次数
 * 
 * 使用场景：
 * - 在卡顿监控中，每隔50ms采集一次主线程堆栈
 * - 当检测到卡顿时，从循环数组中找出Point Stack
 * - Point Stack就是主线程最耗时的调用栈
 * 
 * 使用示例：
 * ```objc
 * // 1. 初始化（循环数组大小 = 检查周期 / 堆栈间隔）
 * WCMainThreadHandler *handler = [[WCMainThreadHandler alloc] initWithCycleArrayCount:20];
 * 
 * // 2. 周期性添加堆栈
 * for (int i = 0; i < 20; i++) {
 *     usleep(50000);  // 50ms
 *     uintptr_t *stack = getMainThreadStack();
 *     [handler addThreadStack:stack andStackCount:count];
 * }
 * 
 * // 3. 检测到卡顿时，获取Point Stack
 * KSStackCursor *pointStack = [handler getPointStackCursor];
 * 
 * // 4. 获取Profile用于可视化分析
 * char *profile = [handler getStackProfile];
 * ```
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import "KSStackCursor_Backtrace.h"

/**
 * WCMainThreadHandler - 主线程堆栈处理器
 * 
 * 线程安全：内部使用pthread_mutex_t保证线程安全
 */
@interface WCMainThreadHandler : NSObject

// ============================================================================
#pragma mark - 初始化
// ============================================================================

/**
 * 初始化主线程堆栈处理器
 * 
 * 创建指定大小的循环数组用于保存主线程堆栈
 * 
 * @param cycleArrayCount 循环数组大小
 *        计算方式：检查周期时间 / 堆栈采集间隔
 *        例如：1000ms / 50ms = 20
 * @return 初始化后的实例
 */
- (id)initWithCycleArrayCount:(int)cycleArrayCount;

// ============================================================================
#pragma mark - 堆栈管理
// ============================================================================

/**
 * 添加主线程堆栈到循环数组
 * 
 * 将新采集的堆栈添加到循环数组中，并计算栈顶地址连续重复次数
 * 
 * 注意：
 * - stackArray的内存由调用者分配，此方法接管ownership
 * - 当循环数组满时，会自动覆盖最旧的堆栈（FIFO）
 * 
 * @param stackArray 堆栈地址数组（调用者分配的内存）
 * @param stackCount 堆栈深度（地址数量）
 */
- (void)addThreadStack:(uintptr_t *)stackArray andStackCount:(size_t)stackCount;

// ============================================================================
#pragma mark - 获取最近堆栈
// ============================================================================

/**
 * 获取最近一次采集的主线程堆栈深度
 * 
 * @return 堆栈深度（栈帧数量）
 */
- (size_t)getLastMainThreadStackCount;

/**
 * 获取最近一次采集的主线程堆栈
 * 
 * @return 堆栈地址数组指针
 *         注意：返回的指针指向内部数组，不要手动释放
 */
- (uintptr_t *)getLastMainThreadStack;

// ============================================================================
#pragma mark - Point Stack算法
// ============================================================================

/**
 * 获取最有可能导致卡顿的堆栈（Point Stack）
 * 
 * 算法原理：
 * 1. 遍历循环数组，找出栈顶地址连续重复次数最多的堆栈
 * 2. 重复次数越多，说明主线程在该函数上停留时间越长
 * 3. 这就是最有可能导致卡顿的堆栈
 * 
 * 同时计算Point Stack中每个地址在所有堆栈中的总出现次数
 * 
 * @return Point Stack的KSStackCursor指针（调用者需要负责释放）
 *         如果没有有效堆栈，返回NULL
 */
- (KSStackCursor *)getPointStackCursor;

/**
 * 获取Point Stack中每个地址的重复次数数组
 * 
 * 返回Point Stack中每个地址在所有堆栈中的总出现次数
 * 
 * 注意：
 * - 必须先调用getPointStackCursor
 * - 数组长度等于Point Stack的深度
 * - 返回的指针指向内部数组，不要手动释放
 * 
 * @return 重复次数数组指针（int*）
 */
- (int *)getPointStackRepeatCount;

// ============================================================================
#pragma mark - 批量获取堆栈
// ============================================================================

/**
 * 获取指定数量的最近堆栈
 * 
 * 从最新到最旧获取指定数量的堆栈
 * 
 * @param limitCount 要获取的堆栈数量（不超过循环数组大小）
 * @param stackSize 输出参数，实际返回的堆栈数量
 * @return KSStackCursor数组指针（调用者需要负责释放）
 *         返回NULL表示失败
 */
- (KSStackCursor **)getStackCursorWithLimit:(int)limitCount withReturnSize:(NSUInteger &)stackSize;

/**
 * 获取循环数组中的所有堆栈
 * 
 * 从最新到最旧获取所有有效的堆栈
 * 
 * @param stackSize 输出参数，实际返回的堆栈数量
 * @return KSStackCursor数组指针（调用者需要负责释放）
 *         返回NULL表示失败
 */
- (KSStackCursor **)getAllStackCursorWithReturnSize:(NSUInteger &)stackSize;

// ============================================================================
#pragma mark - 配置和统计
// ============================================================================

/**
 * 获取单个堆栈的最大地址数量
 * 
 * @return 单个堆栈的最大栈帧数（默认100）
 */
- (size_t)getStackMaxCount;

/**
 * 获取堆栈Profile（调用树）
 * 
 * 将循环数组中的所有堆栈合并成调用树，生成JSON格式的Profile数据
 * 
 * Profile包含：
 * - 所有函数调用的层级关系
 * - 每个函数的调用次数统计
 * - 可用于生成火焰图或调用树可视化
 * 
 * @return JSON格式的Profile数据（char*）
 *         调用者需要负责释放内存
 */
- (char *)getStackProfile;

@end
