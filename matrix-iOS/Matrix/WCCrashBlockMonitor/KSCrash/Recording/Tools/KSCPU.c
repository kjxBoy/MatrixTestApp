//
//  KSCPU.c
//
//  Created by Karl Stenerud on 2012-01-29.
//
//  Copyright (c) 2012 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

/**
 * ============================================================================
 * KSCPU.c - CPU 架构信息和线程状态管理
 * ============================================================================
 * 
 * 功能：
 * - 获取当前 CPU 架构信息（arm64、x86_64 等）
 * - 获取线程的寄存器状态（用于堆栈回溯）
 * 
 * 核心方法：
 * 1. kscpu_currentArch(): 获取当前 CPU 架构名称
 * 2. kscpu_i_fillState(): 填充线程的寄存器状态
 * 
 * 技术说明：
 * - 使用 Mach API 的 thread_get_state() 获取线程寄存器快照
 * - 寄存器状态是堆栈回溯的基础（需要 PC、FP、SP、LR 等寄存器）
 * - 线程必须先被挂起（thread_suspend）才能安全地读取状态
 * 
 * 使用场景：
 * - 崩溃报告中记录 CPU 架构
 * - 堆栈回溯前获取线程寄存器快照
 * - 跨平台支持（ARM、x86、ARM64 等）
 * ============================================================================
 */

#include "KSCPU.h"

#include "KSSystemCapabilities.h"

#include <mach/mach.h>
#include <mach-o/arch.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

/**
 * 获取当前设备的 CPU 架构名称
 * 
 * @return CPU 架构名称字符串
 *         - "arm64": ARM 64位（iPhone 5s 及以后）
 *         - "arm64e": ARM 64位增强版（A12 及以后，支持 PAC）
 *         - "armv7": ARM 32位（已淘汰）
 *         - "x86_64": Intel 64位（模拟器或 Mac）
 *         - NULL: 获取失败
 * 
 * 实现原理：
 * - 使用 NXGetLocalArchInfo() 获取本地架构信息
 * - 此函数返回的是编译时的架构，不是运行时 CPU 类型
 * 
 * 使用场景：
 * - 崩溃报告中记录架构信息
 * - 符号化时需要匹配架构（arm64 vs x86_64）
 * - 判断是真机还是模拟器
 * 
 * 注意事项：
 * - Universal Binary 会根据运行设备返回对应架构
 * - 模拟器运行时返回 "x86_64"
 */
const char *kscpu_currentArch(void) {
    const NXArchInfo *archInfo = NXGetLocalArchInfo();
    return archInfo == NULL ? NULL : archInfo->name;
}

#if KSCRASH_HAS_THREADS_API
/**
 * 填充线程的寄存器状态（内部函数）
 * 
 * @param thread 目标线程（必须已被 thread_suspend 挂起）
 * @param state 输出缓冲区，用于存储线程的寄存器状态
 * @param flavor 状态类型（flavor），指定要获取哪些寄存器
 *        - ARM_THREAD_STATE64: ARM 64位寄存器（x0-x29, fp, lr, sp, pc）
 *        - ARM_THREAD_STATE: ARM 32位寄存器
 *        - x86_THREAD_STATE64: x86 64位寄存器
 * @param stateCount 状态缓冲区的大小（寄存器数量）
 * @return true: 获取成功, false: 获取失败
 * 
 * 实现原理：
 * 1. 调用 Mach 内核的 thread_get_state() 获取线程寄存器快照
 * 2. 寄存器状态包含：
 *    - PC (Program Counter): 当前执行的指令地址
 *    - FP (Frame Pointer, x29): 帧指针，用于回溯调用栈
 *    - SP (Stack Pointer): 栈指针，指向当前栈顶
 *    - LR (Link Register, x30): 链接寄存器，存储返回地址
 *    - 通用寄存器（x0-x28）
 * 
 * 前提条件：
 * - 目标线程必须已被 thread_suspend() 挂起
 * - 否则读取的寄存器状态可能在中间变化，导致数据不一致
 * 
 * 使用场景：
 * - 堆栈回溯前获取线程的寄存器快照
 * - 崩溃报告中记录崩溃时的寄存器状态
 * - 卡顿检测时获取主线程寄存器
 * 
 * 调用示例：
 * ```c
 * thread_suspend(targetThread);  // 必须先挂起
 * 
 * _STRUCT_MACH_MACHINE_THREAD_STATE machineState;
 * bool success = kscpu_i_fillState(
 *     targetThread,
 *     (thread_state_t)&machineState,
 *     THREAD_STATE_FLAVOR,
 *     THREAD_STATE_COUNT
 * );
 * 
 * if (success) {
 *     // 使用 machineState.fp 进行堆栈回溯
 * }
 * 
 * thread_resume(targetThread);  // 恢复线程
 * ```
 * 
 * 技术细节：
 * - stateCountBuff 是输入输出参数，输入时指定缓冲区大小，输出时返回实际写入的大小
 * - 不同架构的 state 结构体大小不同，需要传入正确的 stateCount
 * - thread_get_state() 是内核调用，有一定性能开销
 */
bool kscpu_i_fillState(const thread_t thread,
                       const thread_state_t state,
                       const thread_state_flavor_t flavor,
                       const mach_msg_type_number_t stateCount) {
    KSLOG_TRACE("Filling thread state with flavor %x.", flavor);
    
    // 复制 stateCount 到缓冲区（thread_get_state 会修改此值）
    mach_msg_type_number_t stateCountBuff = stateCount;
    kern_return_t kr;

    // 调用 Mach 内核 API 获取线程状态
    kr = thread_get_state(thread, flavor, state, &stateCountBuff);
    if (kr != KERN_SUCCESS) {
        KSLOG_ERROR("thread_get_state: %s", mach_error_string(kr));
        return false;
    }
    return true;
}
#else
/**
 * 填充线程状态的占位实现（不支持线程 API 的平台）
 * 
 * 说明：
 * - 在不支持 Mach 线程 API 的平台上，此函数直接返回 false
 * - KSCRASH_HAS_THREADS_API 宏在编译时根据平台能力定义
 * - watchOS 等平台可能不支持线程 API
 */
bool kscpu_i_fillState(__unused const thread_t thread,
                       __unused const thread_state_t state,
                       __unused const thread_state_flavor_t flavor,
                       __unused const mach_msg_type_number_t stateCount) {
    return false;
}

#endif
