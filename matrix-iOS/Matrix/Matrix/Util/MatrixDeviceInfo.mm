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

#import "MatrixDeviceInfo.h"
#import "MatrixLogDef.h"

#include <sys/sysctl.h>
#include <sys/mount.h>
#include <mach/mach_error.h>
#include <mach/mach_host.h>
#include <mach/mach_port.h>
#include <mach/task.h>
#include <mach/thread_act.h>
#include <mach/vm_map.h>
#include <os/proc.h>

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#define kIPadSystemNamePrefix @"iPad "

@implementation MatrixDeviceInfo

// ============================================================================
#pragma mark - 私有辅助方法
// ============================================================================

/**
 * 判断设备是否为iPad
 * 
 * @return YES表示iPad，NO表示其他设备
 * 
 * 说明：
 * - 使用dispatch_once确保只判断一次
 * - 通过model字符串是否以"iPad"开头来判断
 */
+ (BOOL)isiPad {
    static BOOL s_isiPad = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *nsModel = [MatrixDeviceInfo model];
        s_isiPad = [nsModel hasPrefix:@"iPad"];
    });
    return s_isiPad;
}

/**
 * 获取适配设备类型的系统名称
 * 
 * @return 系统名称，iPad设备会添加"iPad "前缀
 * 
 * 说明：
 * - iPhone/iPod：返回"iOS"
 * - iPad：返回"iPad iOS"
 */
+ (NSString *)SystemNameForDeviceType {
    NSString *systemName = [MatrixDeviceInfo systemName];
    if ([MatrixDeviceInfo isiPad]) {
        systemName = [kIPadSystemNamePrefix stringByAppendingString:systemName];
    }
    return systemName;
}

/**
 * 获取设备类型字符串（内部实现）
 * 
 * @return 设备类型字符串
 * 
 * 说明：
 * - 格式："系统名 + 系统版本"
 * - 使用静态变量缓存结果
 */
+ (NSString *)getDeviceType {
    static NSString *deviceType = @"";
    if (deviceType.length == 0) {
        NSString *systemName = [self SystemNameForDeviceType];
        NSString *systemVersion = [MatrixDeviceInfo systemVersion];
        deviceType = [NSString stringWithFormat:@"%@%@", systemName, systemVersion];
    }
    return deviceType;
}

/**
 * 通过名称获取系统信息（字符串类型）
 * 
 * @param typeSpeifier sysctl名称，如"hw.machine"、"hw.model"
 * @return 系统信息字符串
 * 
 * 实现：
 * 1. 调用sysctlbyname获取数据大小
 * 2. 分配内存
 * 3. 再次调用获取实际数据
 * 4. 转换为NSString
 * 5. 释放内存
 * 
 * 使用场景：
 * - 获取设备平台标识（hw.machine）
 * - 获取硬件型号（hw.model）
 */
+ (NSString *)getSysInfoByName:(char *)typeSpeifier {
    size_t size;
    // 第一次调用：获取数据大小
    sysctlbyname(typeSpeifier, NULL, &size, NULL, 0);
    
    // 分配内存
    char *answer = (char *)malloc(size);
    
    // 第二次调用：获取实际数据
    sysctlbyname(typeSpeifier, answer, &size, NULL, 0);
    
    // 转换为NSString
    NSString *results = [NSString stringWithCString:answer encoding:NSUTF8StringEncoding];
    if (results == nil) {
        results = @"";
    }
    
    // 释放内存
    free(answer);
    return results;
}

/**
 * 通过类型标识符获取系统信息（整数类型）
 * 
 * @param typeSpecifier 系统信息类型，如HW_NCPU、HW_PHYSMEM等
 * @return 系统信息整数值
 * 
 * 实现：
 * - 使用sysctl系统调用
 * - mib数组：[CTL_HW, typeSpecifier]
 * 
 * 支持的类型：
 * - HW_NCPU：CPU核心数
 * - HW_CPU_FREQ：CPU频率
 * - HW_BUS_FREQ：总线频率
 * - HW_PHYSMEM：物理内存
 * - HW_USERMEM：用户可用内存
 * - HW_CACHELINE：缓存行大小
 * - HW_L1ICACHESIZE：L1指令缓存大小
 * - HW_L1DCACHESIZE：L1数据缓存大小
 * - HW_L2CACHESIZE：L2缓存大小
 * - HW_L3CACHESIZE：L3缓存大小
 */
+ (int)getSysInfo:(uint)typeSpecifier {
    size_t size = sizeof(int);
    int results;
    int mib[2] = { CTL_HW, (int)typeSpecifier };
    sysctl(mib, 2, &results, &size, NULL, 0);
    return results;
}

// ============================================================================
#pragma mark - 公开接口实现
// ============================================================================

/**
 * 获取系统名称
 * 
 * iOS：返回"iOS"
 * macOS：返回操作系统版本字符串
 */
+ (NSString *)systemName {
#if !TARGET_OS_OSX
    return [UIDevice currentDevice].systemName;
#else
    NSProcessInfo *pInfo = [NSProcessInfo processInfo];
    return [pInfo operatingSystemVersionString];
#endif
}

/**
 * 获取系统版本
 * 
 * iOS：从UIDevice获取
 * macOS：从SystemVersion.plist读取
 */
+ (NSString *)systemVersion {
#if !TARGET_OS_OSX
    return [UIDevice currentDevice].systemVersion;
#else
    static NSString *g_s_systemVersion = nil;
    if (g_s_systemVersion == nil) {
        NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *productVersion = [sv objectForKey:@"ProductVersion"];
        NSString *productBuildVersion = [sv objectForKey:@"ProductBuildVersion"];
        g_s_systemVersion = [NSString stringWithFormat:@"OSX %@ build(%@)", productVersion, productBuildVersion];
    }
    return g_s_systemVersion;
#endif
}

/**
 * 获取设备型号
 * 
 * iOS：返回"iPhone"、"iPad"等
 * macOS：返回硬件型号
 */
+ (NSString *)model {
#if !TARGET_OS_OSX
    return [UIDevice currentDevice].model;
#endif
    return [MatrixDeviceInfo getSysInfoByName:(char *)"hw.model"];
}

/**
 * 获取设备平台标识
 * 
 * @return 设备标识，如"iPhone14,2"、"iPad13,8"
 * 
 * 通过sysctlbyname("hw.machine")获取
 */
+ (NSString *)platform {
    return [MatrixDeviceInfo getSysInfoByName:(char *)"hw.machine"];
}

/**
 * 获取CPU核心数
 * 
 * @return CPU核心数
 * 
 * 说明：
 * - 使用dispatch_once缓存结果
 * - 通过sysctl(HW_NCPU)获取
 */
+ (int)cpuCount {
    static int s_cpuCount = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_cpuCount = [MatrixDeviceInfo getSysInfo:HW_NCPU];
    });
    return s_cpuCount;
}

/**
 * 获取CPU频率
 * 
 * @return CPU频率（Hz），某些设备可能返回0
 * 
 * 通过sysctl(HW_CPU_FREQ)获取
 */
+ (int)cpuFrequency {
    return [MatrixDeviceInfo getSysInfo:HW_CPU_FREQ];
}

/**
 * 获取设备整体CPU使用率（单核百分比）
 * 
 * 技术实现：
 * 1. 使用host_statistics获取系统级CPU统计信息
 * 2. CPU时间分为4种状态：
 *    - USER：用户态程序运行时间
 *    - NICE：低优先级用户态程序运行时间
 *    - SYSTEM：内核态运行时间
 *    - IDLE：空闲时间
 * 3. 使用静态变量保存上次的统计数据
 * 4. 计算两次调用之间的CPU时间增量
 * 5. CPU使用率 = (非空闲时间) / (总时间)
 * 
 * 返回值：
 * - 0-100：CPU使用率百分比（单核平均）
 * - 0：获取失败或CPU完全空闲
 * 
 * 注意事项：
 * - 返回的是单核的平均使用率
 * - 如果设备有8个核心，每个核心50%，此方法返回50
 * - 两次调用间隔越长，结果越准确
 * - 首次调用返回0（因为没有previous_info）
 * 
 * @return CPU使用率（0-100）
 */
+ (float)cpuUsage {
    kern_return_t kr;
    mach_msg_type_number_t count;
    
    // 静态变量：保存上次的CPU统计信息，用于计算增量
    static host_cpu_load_info_data_t previous_info = { 0, 0, 0, 0 };
    host_cpu_load_info_data_t info;

    count = HOST_CPU_LOAD_INFO_COUNT;

    // 获取系统级CPU负载信息
    kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }

    // 计算自上次调用以来，各状态的CPU时间增量（单位：ticks）
    natural_t user = info.cpu_ticks[CPU_STATE_USER] - previous_info.cpu_ticks[CPU_STATE_USER];
    natural_t nice = info.cpu_ticks[CPU_STATE_NICE] - previous_info.cpu_ticks[CPU_STATE_NICE];
    natural_t system = info.cpu_ticks[CPU_STATE_SYSTEM] - previous_info.cpu_ticks[CPU_STATE_SYSTEM];
    natural_t idle = info.cpu_ticks[CPU_STATE_IDLE] - previous_info.cpu_ticks[CPU_STATE_IDLE];
    
    // 总时间 = 所有状态的时间之和
    natural_t total = user + nice + system + idle;
    
    // 保存本次数据，供下次调用使用
    previous_info = info;

    // 计算CPU使用率
    if (total == 0) {
        return 0;
    } else {
        // CPU使用率 = (用户态 + 低优先级用户态 + 内核态) / 总时间 * 100
        return (user + nice + system) * 100.0 / total;
    }
}

//+ (float)cpuUsage {
//    CGFloat cpuUsage = 0;
//    unsigned _numCPUs;
//    static processor_info_array_t _cpuInfo = NULL, _prevCPUInfo = NULL;
//    static mach_msg_type_number_t _numCPUInfo, _numPrevCPUInfo;
//
//    int _mib[2U] = { CTL_HW, HW_NCPU };
//    size_t _sizeOfNumCPUs = sizeof(_numCPUs);
//    int _status = sysctl(_mib, 2U, &_numCPUs, &_sizeOfNumCPUs, NULL, 0U);
//    if (_status) {
//        _numCPUs = 1;
//    }
//
//    natural_t _numCPUsU = 0U;
//    kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &_numCPUsU, &_cpuInfo, &_numCPUInfo);
//    if (err == KERN_SUCCESS) {
//        for (unsigned i = 0U; i < _numCPUs; ++i) {
//            CGFloat _inUse, _total = 0;
//            if (_prevCPUInfo) {
//                _inUse = ((_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER])
//                          + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM])
//                          + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE]));
//                _total = _inUse + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE]);
//            } else {
//                _inUse = _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER] + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM]
//                         + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE];
//                _total = _inUse + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE];
//            }
//
//            if (_total != 0) {
//                cpuUsage += _inUse / _total;
//            }
//        }
//
//        if (_prevCPUInfo) {
//            size_t prevCpuInfoSize = sizeof(integer_t) * _numPrevCPUInfo;
//            vm_deallocate(mach_task_self(), (vm_address_t)_prevCPUInfo, prevCpuInfoSize);
//        }
//
//        _prevCPUInfo = _cpuInfo;
//        _numPrevCPUInfo = _numCPUInfo;
//
//        _cpuInfo = NULL;
//        _numCPUInfo = 0U;
//
//        return cpuUsage * 100.0;
//    } else {
//        return -1;
//    }
//}

/**
 * 获取App的CPU使用率（所有核心累加）
 * 
 * 技术实现：
 * 1. 使用task_threads获取App的所有线程
 * 2. 遍历每个线程，使用thread_info获取其CPU使用信息
 * 3. 过滤掉空闲线程（TH_FLAGS_IDLE）
 * 4. 累加所有非空闲线程的CPU使用率
 * 5. 将Mach单位转换为百分比
 * 
 * 返回值：
 * - 0 - (核心数 × 100)：App的CPU使用率
 * - 例如8核设备，最大可返回800（占满8个核心）
 * - -1：获取失败
 * 
 * 计算公式：
 * appCpuUsage = Σ(每个非空闲线程的cpu_usage) / TH_USAGE_SCALE * 100
 * 
 * 其中：
 * - cpu_usage：Mach内核提供的CPU使用率（整数，范围0-TH_USAGE_SCALE）
 * - TH_USAGE_SCALE：Mach定义的缩放因子，通常为1000
 * - 例如：cpu_usage = 850，转换为百分比 = 850 / 1000 * 100 = 85%
 * 
 * 注意事项：
 * - 此方法有一定性能开销，需要遍历所有线程
 * - 建议在后台线程调用，避免阻塞主线程
 * - 建议控制调用频率，如每秒1-2次
 * - 返回值是所有核心的累加，不是平均值
 * 
 * 资源清理：
 * - 方法会正确释放所有Mach端口和内存
 * - 使用goto cleanup确保即使出错也能清理资源
 * 
 * @return App的CPU使用率（0-800），-1表示失败
 */
+ (float)appCpuUsage {
    // 获取当前task（App进程）
    const task_t thisTask = mach_task_self();
    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;
    
    // 获取App的所有线程
    kern_return_t kr = task_threads(thisTask, &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    // 累加所有线程的CPU使用率
    float tot_cpu = 0;

    // 遍历每个线程
    for (int j = 0; j < thread_count; j++) {
        thread_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        
        // 获取线程的基本信息
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            tot_cpu = -1;
            goto cleanup;  // 出错时跳转到清理代码
        }
        
        // 将thread_info_data_t转换为thread_basic_info_t
        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
        
        // 只统计非空闲线程
        // TH_FLAGS_IDLE：线程处于空闲状态（没有工作）
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            // cpu_usage：Mach提供的CPU使用率（0-TH_USAGE_SCALE）
            // TH_USAGE_SCALE：通常为1000
            // 转换公式：cpu_usage / TH_USAGE_SCALE * 100 = 百分比
            // 例如：cpu_usage = 850 -> 85%
            tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
        }
    }

cleanup:
    // 清理资源：释放所有线程端口
    for (int i = 0; i < thread_count; i++) {
        mach_port_deallocate(thisTask, thread_list[i]);
    }

    // 释放线程列表内存
    kr = vm_deallocate(thisTask, (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
    assert(kr == KERN_SUCCESS);

    return tot_cpu;
}

/**
 * 获取总线频率
 * 
 * @return 总线频率（Hz）
 */
+ (int)busFrequency {
    return [MatrixDeviceInfo getSysInfo:HW_BUS_FREQ];
}

/**
 * 获取物理内存总量（已废弃）
 * 
 * @return 物理内存（字节）
 * @deprecated 请使用matrix_physicalMemory()
 */
+ (int)totalMemory {
    return [MatrixDeviceInfo getSysInfo:HW_PHYSMEM];
}

/**
 * 获取用户可用内存（已废弃）
 * 
 * @return 用户可用内存（字节）
 * @deprecated 请使用matrix_availableMemory()
 */
+ (int)userMemory {
    return [MatrixDeviceInfo getSysInfo:HW_USERMEM];
}

/**
 * 获取CPU缓存行大小
 * 
 * @return 缓存行大小（字节），通常为64或128
 */
+ (int)cacheLine {
    return [MatrixDeviceInfo getSysInfo:HW_CACHELINE];
}

/**
 * 获取L1指令缓存大小
 * 
 * @return L1 I-Cache大小（字节）
 */
+ (int)L1ICacheSize {
    return [MatrixDeviceInfo getSysInfo:HW_L1ICACHESIZE];
}

/**
 * 获取L1数据缓存大小
 * 
 * @return L1 D-Cache大小（字节）
 */
+ (int)L1DCacheSize {
    return [MatrixDeviceInfo getSysInfo:HW_L1DCACHESIZE];
}

/**
 * 获取L2缓存大小
 * 
 * @return L2 Cache大小（字节）
 */
+ (int)L2CacheSize {
    return [MatrixDeviceInfo getSysInfo:HW_L2CACHESIZE];
}

/**
 * 获取L3缓存大小
 * 
 * @return L3 Cache大小（字节），某些设备可能返回0
 */
+ (int)L3CacheSize {
    return [MatrixDeviceInfo getSysInfo:HW_L3CACHESIZE];
}

/**
 * 检测App是否正在被调试
 * 
 * @return YES表示正在调试，NO表示正常运行
 * 
 * 实现原理：
 * 1. 通过sysctl获取当前进程的kinfo_proc信息
 * 2. 检查进程标志位中的P_TRACED标志
 * 3. P_TRACED标志表示进程正在被调试器跟踪
 * 
 * 使用场景：
 * - 反调试检测
 * - 区分调试环境和生产环境
 * - 某些监控功能在调试时可能需要禁用
 */
+ (BOOL)isBeingDebugged {
    // 如果当前进程正在被调试，返回true
    // （无论是运行在调试器下还是调试器附加到进程）
    int junk;
    int mib[4];
    struct kinfo_proc info;
    size_t size;

    // 初始化标志位，这样如果sysctl由于某些原因失败，
    // 我们也能得到一个可预测的结果
    info.kp_proc.p_flag = 0;

    // 初始化mib数组，告诉sysctl我们需要什么信息
    // 在这个例子中，我们要查找特定进程ID的信息
    mib[0] = CTL_KERN;          // 内核信息
    mib[1] = KERN_PROC;         // 进程信息
    mib[2] = KERN_PROC_PID;     // 通过PID查询
    mib[3] = getpid();          // 当前进程的PID

    // 调用sysctl获取进程信息
    size = sizeof(info);
    junk = sysctl(mib, sizeof(mib) / sizeof(*mib), &info, &size, NULL, 0);
    assert(junk == 0);

    // 如果P_TRACED标志被设置，说明我们正在被调试
    return ((info.kp_proc.p_flag & P_TRACED) != 0);
}

@end

// ============================================================================
#pragma mark - C函数接口实现
// ============================================================================

/**
 * 获取设备的物理内存总量
 * 
 * @return 物理内存大小（字节），失败返回0
 * 
 * 实现：
 * - 通过sysctlbyname("hw.memsize")获取
 * - 等同于[[NSProcessInfo processInfo] physicalMemory]
 * 
 * 注意：
 * - 不使用带错误日志的辅助函数，因为出错时日志函数可能调用malloc
 * - 这在某些特殊情况下（如内存不足时）可能导致问题
 */
uint64_t matrix_physicalMemory() {
    uint64_t value;
    size_t size = sizeof(value);

    // 等同于 [[NSProcessInfo processInfo] physicalMemory]
    int ret = sysctlbyname("hw.memsize", &value, &size, NULL, 0);
    if (ret != 0) {
        // 不用带日志的辅助函数，因为出错时KSLOG_ERROR可能会调用malloc
        return 0;
    }

    return value;
}

/**
 * 获取进程已经使用的内存量（Memory Footprint）
 * 
 * @return 进程内存占用（字节），失败返回0
 * 
 * 实现：
 * - 通过task_info获取TASK_VM_INFO
 * - 读取task_vm_info.phys_footprint字段
 * 
 * 说明：
 * - phys_footprint是iOS/macOS的标准内存计量方式
 * - 包含Dirty Memory、Compressed Memory等
 * - 不包含Clean Memory（可以随时释放的内存）
 * - Xcode Instruments中显示的就是这个值
 * - 这是判断内存警告的关键指标
 * 
 * 组成部分：
 * - Dirty Memory：进程修改过的内存页
 * - Compressed Memory：被压缩的内存页
 * - IOKit mappings：某些IOKit映射
 * 
 * 注意：
 * - 不调用MatrixError，因为它会调用ObjC方法
 */
uint64_t matrix_footprintMemory() {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t infoCount = TASK_VM_INFO_COUNT;
    
    // 获取当前任务的虚拟内存信息
    kern_return_t kernReturn = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &infoCount);

    if (kernReturn != KERN_SUCCESS) {
        // 不调用MatrixError，因为它会调用ObjC方法
        // MatrixError(@"Error with task_info(): %s", mach_error_string(kernReturn));
        return 0;
    }

    // 返回物理内存占用（Footprint）
    return vmInfo.phys_footprint;
}

/**
 * 获取进程剩余可用的内存量
 * 
 * @return 可用内存大小（字节），失败返回0
 * 
 * 实现：
 * - iOS 13+：使用os_proc_available_memory()
 * - iOS 13以下：通过host_statistics计算
 * 
 * iOS 13以下的计算方式：
 * - 获取系统VM统计信息
 * - 可用内存 = (free_count + inactive_count) * vm_page_size
 * - free_count：空闲页数
 * - inactive_count：不活跃页数（可以回收）
 * - vm_page_size：页大小（通常为4KB或16KB）
 * 
 * 说明：
 * - 返回的是进程还可以使用的内存
 * - 系统会根据设备内存和当前占用动态计算
 * - 当可用内存过低时，系统会发送内存警告
 * - 这个值会随着系统状态变化
 * 
 * 使用场景：
 * - 预判是否会发生内存警告
 * - 决定是否可以执行内存密集型操作
 * - 实现主动的内存管理策略
 * 
 * 注意：
 * - iOS 13之前的实现是近似值，不完全准确
 * - 建议优先使用iOS 13+的API
 */
uint64_t matrix_availableMemory() {
#if !TARGET_OS_OSX
    // iOS 13及以上版本，使用系统提供的API
    if (@available(iOS 13.0, *)) {
        return os_proc_available_memory();
    }
#endif

    // iOS 13以下版本的降级实现

    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t infoCount = HOST_VM_INFO_COUNT;
    
    // 获取主机VM统计信息
    kern_return_t kernReturn = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmStats, &infoCount);

    if (kernReturn != KERN_SUCCESS) {
        // 不调用MatrixError，因为它会调用ObjC方法
        // MatrixError(@"Error with host_statistics(): %s", mach_error_string(kernReturn));
        return 0;
    }

    // 计算可用内存
    // 可用内存 = (空闲页数 + 不活跃页数) × 页大小
    return (uint64_t)vm_page_size * (vmStats.free_count + vmStats.inactive_count);
}
