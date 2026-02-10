//
//  KSStackCursor_SelfThread.c
//
//  Copyright (c) 2016 Karl Stenerud. All rights reserved.
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

#include "KSStackCursor_SelfThread.h"
#include "KSStackCursor_Backtrace.h"
#include "KSStackCursor_MachineContext.h"
#include <execinfo.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

// 计算最大回溯长度（基于上下文大小）
#define MAX_BACKTRACE_LENGTH (KSSC_CONTEXT_SIZE - sizeof(KSStackCursor_Backtrace_Context) / sizeof(void *) - 1)

/**
 * 自线程上下文结构
 * 用于存储当前线程的堆栈回溯
 */
typedef struct {
    KSStackCursor_Backtrace_Context SelfThreadContextSpacer;  // 上下文占位符
    uintptr_t backtrace[0];  // 可变长度的回溯数组（C99 柔性数组）
} SelfThreadContext;

/**
 * ============================================================================
 * 函数：kssc_initSelfThread
 * ============================================================================
 * 
 * 功能：初始化当前线程的堆栈游标
 * 
 * 注意：这个函数用于获取"自己"的堆栈（调用者所在的线程）
 *      而 kssc_backtraceCurrentThread 用于获取"其他"线程的堆栈
 * 
 * @param cursor 要初始化的堆栈游标
 * @param skipEntries 要跳过的栈帧数（通常跳过本函数的调用栈）
 */
void kssc_initSelfThread(KSStackCursor *cursor, int skipEntries) {
    // 获取游标上下文
    SelfThreadContext *context = (SelfThreadContext *)cursor->context;
    
    // 使用 POSIX backtrace() 函数获取当前线程的堆栈
    // 这是一个标准库函数，不需要挂起线程
    int backtraceLength = backtrace((void **)context->backtrace, MAX_BACKTRACE_LENGTH);
    
    // 用获取到的回溯初始化游标
    // skipEntries + 1: 跳过指定数量 + 本函数自身
    kssc_initWithBacktrace(cursor, context->backtrace, backtraceLength, skipEntries + 1);
}

/**
 * ============================================================================
 * 函数：kssc_backtraceCurrentThread
 * ============================================================================
 * 
 * 功能：获取指定线程的堆栈回溯
 * 
 * 这是 Matrix 用来获取主线程堆栈的核心函数！
 * 
 * 实现原理：
 * 1. 创建机器上下文结构
 * 2. 通过 thread_get_state 获取线程的寄存器快照（PC, FP, SP, LR等）
 * 3. 使用帧指针（FP）遍历调用栈
 * 4. 收集每个栈帧的返回地址
 * 
 * ARM64 堆栈结构：
 * ┌────────────────┐
 * │ LR (返回地址)  │  ← FP + 8
 * ├────────────────┤
 * │ previous FP    │  ← FP + 0
 * └────────────────┘
 * 
 * 通过链式追踪 FP，可以回溯整个调用链
 * 
 * 前提条件：
 * - 目标线程必须已被 thread_suspend() 挂起
 * - 否则读取的寄存器状态可能不一致
 * 
 * @param currentThread 目标线程（已挂起）
 * @param backtraceBuffer 输出缓冲区，存储堆栈地址
 * @param maxEntries 最大堆栈深度（防止无限递归）
 * @return 实际获取到的堆栈帧数量
 */
int kssc_backtraceCurrentThread(KSThread currentThread, uintptr_t *backtraceBuffer, int maxEntries) {
    // ========================================================================
    // 边界检查
    // ========================================================================
    if (maxEntries == 0) {
        return 0;  // 不需要任何堆栈帧，直接返回
    }

    // ========================================================================
    // 步骤1：创建并初始化机器上下文
    // ========================================================================
    /*
     * KSMC_NEW_CONTEXT 宏展开为：
     * char machineContextBuffer[ksmc_contextSize()];
     * KSMachineContext* machineContext = (KSMachineContext*)machineContextBuffer;
     * memset(machineContext, 0, sizeof(*machineContext));
     * 
     * 作用：
     * - 在栈上分配 KSMachineContext 结构（约 4KB）
     * - 初始化为 0
     * - 用于存储线程的寄存器状态、堆栈信息等
     */
    KSMC_NEW_CONTEXT(machineContext);
    
    // ========================================================================
    // 步骤2：获取线程的机器上下文（寄存器状态）
    // ========================================================================
    /*
     * ksmc_getContextForThread 的作用：
     * 1. 调用 thread_get_state(currentThread, ARM_THREAD_STATE64, ...)
     * 2. 获取线程的寄存器快照：
     *    - PC (Program Counter): 当前执行的指令地址
     *    - FP (Frame Pointer, x29): 帧指针，指向当前栈帧
     *    - SP (Stack Pointer, x31): 栈指针，指向栈顶
     *    - LR (Link Register, x30): 链接寄存器，存储返回地址
     *    - x0-x28: 通用寄存器
     * 3. 将寄存器状态保存到 machineContext 中
     * 
     * 参数说明：
     * - currentThread: 目标线程（必须已被 thread_suspend 挂起）
     * - machineContext: 输出参数，存储机器上下文
     * - false: 这不是崩溃上下文（只是正常的堆栈采集）
     * 
     * 为什么必须先挂起线程？
     * - 如果线程仍在运行，寄存器状态会不断变化
     * - 可能读取到中间状态，导致堆栈不一致
     * - 挂起后，寄存器状态固定，数据一致性有保证
     */
    ksmc_getContextForThread(currentThread, machineContext, false);
    
    // ========================================================================
    // 步骤3：创建并初始化堆栈游标
    // ========================================================================
    /*
     * KSStackCursor 是一个迭代器模式的实现
     *
     * 迭代器模式
     * 结构：
     * - context: 存储遍历所需的上下文数据
     * - advanceCursor: 函数指针，移动到下一个栈帧
     * - stackEntry: 当前栈帧信息（地址、符号等）
     * - state: 遍历状态（深度、是否结束等）
     */
    KSStackCursor stackCursor;
    
    /*
     * kssc_initWithMachineContext 的作用：
     * 1. 设置 stackCursor.advanceCursor = advanceCursor（核心遍历函数）
     * 2. 从 machineContext 中提取初始 FP 和 PC
     * 3. 初始化游标状态
     * 
     * 参数说明：
     * - stackCursor: 要初始化的游标
     * - maxEntries: 最大遍历深度（通常 100）
     * - machineContext: 包含寄存器状态的机器上下文
     */
    kssc_initWithMachineContext(&stackCursor, maxEntries, machineContext);

    // ========================================================================
    // 步骤4：遍历堆栈，收集返回地址
    // ========================================================================
    int i = 0;
    
    /*
     * advanceCursor 的工作原理（ARM64）：
     * 
     * 第1次调用：
     *   - 返回 machineContext.PC（当前指令地址）
     *   - 这是堆栈的"栈顶"
     * 
     * 第2次调用：
     *   - 获取 machineContext.FP（x29 寄存器）
     *   - 读取栈帧：
     *     ┌────────────────┐
     *     │ LR (x30)       │  ← FP + 8 (返回地址)
     *     ├────────────────┤
     *     │ previous FP    │  ← FP + 0 (上一个帧指针)
     *     └────────────────┘
     *   - 返回 LR
     * 
     * 第3-N次调用：
     *   - FP = previous FP（移动到上一个栈帧）
     *   - 读取新 FP 的栈帧（结构同上）
     *   - 返回新的 LR
     *   - 重复此过程
     * 
     * 停止条件：
     *   - previous FP == 0（到达栈底）
     *   - return address == 0（无效返回地址）
     *   - 达到 maxEntries（防止无限循环）
     *   - 内存读取失败（无效地址）
     * 
     * 内存读取安全性：
     *   - 使用 ksmem_copySafely() 安全读取内存
     *   - 如果地址无效，返回 false 而不是崩溃
     */
    while (stackCursor.advanceCursor(&stackCursor)) {
        // 获取当前栈帧的地址（返回地址）
        backtraceBuffer[i] = stackCursor.stackEntry.address;
        i++;
    }
    
    // ========================================================================
    // 返回实际获取到的堆栈帧数量
    // ========================================================================
    /*
     * 返回值说明：
     * - 0: 无法获取堆栈（可能是参数错误或线程状态异常）
     * - 1-maxEntries: 成功获取的栈帧数量
     * 
     * backtraceBuffer 内容示例（从栈顶到栈底）：
     * [0] = 0x100001234  // 当前指令（PC）
     * [1] = 0x100002456  // 函数 A 的返回地址
     * [2] = 0x100003678  // 函数 B 的返回地址
     * [3] = 0x10000489a  // 函数 C 的返回地址
     * ...
     * 
     * 这些地址可以通过符号化（symbolication）转换为函数名：
     * [0] -[ViewController heavyWork] + 52
     * [1] -[ViewController viewDidLoad] + 123
     * [2] -[AppDelegate application:didFinishLaunching:] + 456
     * [3] main + 789
     */
    return i;
}
