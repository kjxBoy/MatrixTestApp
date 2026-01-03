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
#import <TargetConditionals.h>

/**
 * ============================================================================
 * MatrixDeviceInfo - 设备信息获取工具类
 * ============================================================================
 * 
 * 职责：
 * - 提供设备基本信息（系统、型号、CPU等）
 * - 提供CPU使用率监控接口（基于Mach内核API）
 * - 提供内存信息获取接口
 * - 提供调试状态检测
 * 
 * 核心功能：
 * 1. CPU监控：
 *    - cpuUsage：设备整体CPU使用率（单核百分比）
 *    - appCpuUsage：App的CPU使用率（所有核心累加）
 *    - cpuCount：CPU核心数
 * 
 * 2. 内存监控：
 *    - matrix_physicalMemory：设备物理内存总量
 *    - matrix_footprintMemory：进程内存占用
 *    - matrix_availableMemory：进程可用内存
 * 
 * 3. 设备信息：
 *    - platform：设备型号（如iPhone14,2）
 *    - model：设备类型（如iPhone）
 *    - systemVersion：系统版本
 * 
 * 技术实现：
 * - 使用sysctl系统调用获取设备信息
 * - 使用Mach API（task_threads、thread_info）获取CPU数据
 * - 使用host_statistics获取系统级CPU统计
 * 
 * 使用示例：
 * ```objc
 * // 获取App CPU使用率
 * float cpuUsage = [MatrixDeviceInfo appCpuUsage];
 * // 返回值范围：0 - (核心数 × 100)，如8核最大800
 * 
 * // 获取设备整体CPU使用率
 * float deviceCPU = [MatrixDeviceInfo cpuUsage];
 * // 返回值范围：0-100（单核百分比）
 * 
 * // 获取CPU核心数
 * int cores = [MatrixDeviceInfo cpuCount];
 * ```
 * ============================================================================
 */
@interface MatrixDeviceInfo : NSObject

// ============================================================================
#pragma mark - 设备基本信息
// ============================================================================

/**
 * 获取设备类型字符串
 * 
 * @return 设备类型，格式："系统名 + 系统版本"
 *         例如："iOS 15.0"、"iPad iOS 14.5"
 */
+ (NSString *)getDeviceType;

/**
 * 获取系统名称
 * 
 * @return iOS设备返回"iOS"，macOS返回操作系统版本字符串
 */
+ (NSString *)systemName;

/**
 * 获取系统版本
 * 
 * @return 系统版本号，如"15.0"、"14.5"
 */
+ (NSString *)systemVersion;

/**
 * 获取设备型号
 * 
 * @return iOS设备返回"iPhone"、"iPad"等，macOS返回硬件型号
 */
+ (NSString *)model;

/**
 * 获取设备平台标识
 * 
 * @return 设备的机器标识，如"iPhone14,2"、"iPad13,8"
 *         通过sysctlbyname("hw.machine")获取
 */
+ (NSString *)platform;

// ============================================================================
#pragma mark - CPU信息
// ============================================================================

/**
 * 获取CPU核心数
 * 
 * @return CPU核心数，如4、6、8等
 * 
 * 说明：
 * - 此值会被缓存，只在首次调用时通过sysctl获取
 * - 通过sysctl(HW_NCPU)获取
 */
+ (int)cpuCount;

/**
 * 获取CPU频率
 * 
 * @return CPU频率（Hz）
 * 
 * 注意：某些设备可能返回0（系统不支持查询）
 */
+ (int)cpuFrequency;

/**
 * 获取设备整体CPU使用率（单核百分比）
 * 
 * @return CPU使用率，范围：0-100
 *         返回0表示空闲，100表示单核满载
 * 
 * 实现原理：
 * 1. 使用host_statistics获取系统级CPU统计
 * 2. 计算user、nice、system时间的累加
 * 3. 除以总时间（包含idle）得到使用率
 * 4. 使用静态变量存储上次数据，计算增量
 * 
 * 计算公式：
 * cpuUsage = (user_ticks + nice_ticks + system_ticks) / total_ticks * 100
 * 
 * 说明：
 * - 返回的是单核的平均使用率
 * - 如果要计算设备总体负载，需要乘以核心数
 * - 两次调用之间的间隔越长，结果越准确
 * 
 * 使用场景：
 * - 判断设备整体负载情况
 * - 配合appCpuUsage判断是系统繁忙还是App问题
 */
+ (float)cpuUsage;

/**
 * 获取App的CPU使用率（所有核心累加）
 * 
 * @return App的CPU使用率，范围：0 - (核心数 × 100)
 *         例如：8核设备最大可返回800
 *         返回-1表示获取失败
 * 
 * 实现原理：
 * 1. 通过task_threads获取App的所有线程
 * 2. 遍历每个线程，使用thread_info获取CPU使用率
 * 3. 过滤空闲线程（TH_FLAGS_IDLE）
 * 4. 累加所有非空闲线程的CPU使用率
 * 5. 转换为百分比（cpu_usage / TH_USAGE_SCALE * 100）
 * 
 * 计算公式：
 * appCpuUsage = Σ(每个非空闲线程的cpu_usage) / TH_USAGE_SCALE * 100
 * 
 * 说明：
 * - 返回的是所有核心累加的结果
 * - 如果App占用2个核心，返回约200
 * - 如果要计算平均每核使用率，需要除以核心数
 * - TH_USAGE_SCALE是Mach定义的缩放因子（通常为1000）
 * 
 * 使用场景：
 * - CPU监控的核心数据来源
 * - 判断App是否占用过多CPU
 * - 性能优化的关键指标
 * 
 * 性能开销：
 * - 需要遍历所有线程，有一定开销
 * - 建议控制调用频率（如每秒1次）
 * - 在监控线程中调用，避免阻塞主线程
 */
+ (float)appCpuUsage;

/**
 * 获取总线频率
 * 
 * @return 总线频率（Hz）
 */
+ (int)busFrequency;

// ============================================================================
#pragma mark - 内存信息（已废弃的方法）
// ============================================================================

/**
 * 获取物理内存总量（已废弃）
 * 
 * @return 物理内存（字节）
 * @deprecated 请使用matrix_physicalMemory()
 */
+ (int)totalMemory __deprecated;

/**
 * 获取用户可用内存（已废弃）
 * 
 * @return 用户可用内存（字节）
 * @deprecated 请使用matrix_availableMemory()
 */
+ (int)userMemory __deprecated;

// ============================================================================
#pragma mark - CPU缓存信息
// ============================================================================

/**
 * 获取CPU缓存行大小
 * 
 * @return 缓存行大小（字节），通常为64或128
 */
+ (int)cacheLine;

/**
 * 获取L1指令缓存大小
 * 
 * @return L1 I-Cache大小（字节）
 */
+ (int)L1ICacheSize;

/**
 * 获取L1数据缓存大小
 * 
 * @return L1 D-Cache大小（字节）
 */
+ (int)L1DCacheSize;

/**
 * 获取L2缓存大小
 * 
 * @return L2 Cache大小（字节）
 */
+ (int)L2CacheSize;

/**
 * 获取L3缓存大小
 * 
 * @return L3 Cache大小（字节），某些设备可能返回0
 */
+ (int)L3CacheSize;

// ============================================================================
#pragma mark - 调试检测
// ============================================================================

/**
 * 检测App是否正在被调试
 * 
 * @return YES表示正在调试，NO表示正常运行
 * 
 * 实现原理：
 * - 通过sysctl(KERN_PROC)获取进程信息
 * - 检查进程标志位中的P_TRACED标志
 * 
 * 使用场景：
 * - 反调试检测
 * - 区分调试环境和生产环境
 * - 某些监控功能在调试时可能需要禁用
 */
+ (BOOL)isBeingDebugged;

@end

// ============================================================================
#pragma mark - C函数接口（内存监控）
// ============================================================================

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 获取设备的物理内存总量
 * 
 * @return 物理内存大小（字节）
 * 
 * 实现：通过sysctlbyname("hw.memsize")获取
 * 
 * 使用示例：
 * ```c
 * uint64_t totalMemory = matrix_physicalMemory();
 * // 转换为GB：totalMemory / (1024 * 1024 * 1024)
 * ```
 */
uint64_t matrix_physicalMemory();

/**
 * 获取进程已经使用的内存量（Memory Footprint）
 * 
 * @return 进程内存占用（字节）
 * 
 * 实现：通过task_vm_info.phys_footprint获取
 * 
 * 说明：
 * - Footprint是iOS系统使用的内存计量标准
 * - 包含Dirty Memory、Compressed Memory等
 * - 不包含Clean Memory（可以随时释放的内存）
 * - Xcode Instruments显示的就是这个值
 * 
 * 使用场景：
 * - 监控App内存占用
 * - 检测内存泄漏
 * - 内存警告阈值判断
 */
uint64_t matrix_footprintMemory();

/**
 * 获取进程剩余可用的内存量
 * 
 * @return 可用内存大小（字节）
 * 
 * 实现：通过os_proc_available_memory()获取（iOS 13+）
 * 
 * 说明：
 * - 返回的是进程还可以使用的内存
 * - 系统会根据设备内存和当前占用动态计算
 * - 当可用内存过低时，系统可能发送内存警告
 * 
 * 使用场景：
 * - 预判是否会发生内存警告
 * - 决定是否可以执行内存密集型操作
 * - 内存监控和预警
 */
uint64_t matrix_availableMemory();

#ifdef __cplusplus
} // extern "C"
#endif
