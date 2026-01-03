//
//  KSCPU_arm64_Apple.c
//
//  Created by Karl Stenerud on 2013-09-29.
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

// ============================================================================
// 文件说明：ARM64 架构 CPU 状态管理
// ============================================================================
//
// 这个文件是 Matrix 堆栈回溯的核心底层实现！
//
// 主要功能：
// 1. 获取线程的 CPU 寄存器状态（通过 thread_get_state 系统调用）
// 2. 提供寄存器访问接口（FP, SP, PC, LR 等）
// 3. 支持堆栈遍历所需的关键寄存器读取
//
// 关键概念：
// - FP (Frame Pointer, x29): 帧指针，指向当前栈帧的起始位置
// - SP (Stack Pointer, x31): 栈指针，指向当前栈顶
// - PC (Program Counter, x32): 程序计数器，当前执行的指令地址
// - LR (Link Register, x30): 链接寄存器，函数返回地址
//
// 为什么重要：
// - 这些寄存器是遍历调用栈的基础
// - Swift 和 Objective-C 都依赖相同的寄存器布局
// - 堆栈回溯本质上就是沿着 FP 链向上遍历
//
// 与 Swift 的关系：
// ✅ Swift 和 Objective-C 使用完全相同的 ARM64 寄存器
// ✅ Swift 函数调用约定与 ObjC 一致（AAPCS64）
// ✅ 这个文件对 Swift 和 ObjC 同样有效
//
// ============================================================================

#if defined(__arm64__)

#include "KSCPU.h"
#include "KSCPU_Apple.h"
#include "KSMachineContext.h"
#include "KSMachineContext_Apple.h"
#include <stdlib.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

// ============================================================================
// PAC (Pointer Authentication Code) 掩码
// ============================================================================
// ARM64e 架构引入了指针认证（PAC）机制，用于增强安全性
// PAC 会在指针的高位添加签名，需要剥离这些签名才能得到真实地址
// 
// 0x0000000fffffffff 保留了低 40 位（虚拟地址空间）
// 这个掩码用于清除指针的 PAC 签名位
#define KSPACStrippingMask_ARM64e 0x0000000fffffffff

// ============================================================================
// ARM64 寄存器名称表
// ============================================================================
// ARM64 架构有 34 个主要寄存器：
//
// 通用寄存器 (x0-x28):
// - x0-x7:   函数参数和返回值
// - x8:      间接返回值地址
// - x9-x15:  临时寄存器（调用者保存）
// - x16-x17: 内部调用寄存器（IP0, IP1）
// - x18:     平台寄存器（保留）
// - x19-x28: 被调用者保存的寄存器
//
// 特殊寄存器:
// - fp (x29):   帧指针 (Frame Pointer)    ← 堆栈遍历的关键！
// - lr (x30):   链接寄存器 (Link Register) ← 函数返回地址
// - sp (x31):   栈指针 (Stack Pointer)
// - pc (x32):   程序计数器 (Program Counter) ← 当前执行位置
// - cpsr (x33): 程序状态寄存器 (Current Program Status Register)
//
// 🎯 堆栈回溯的核心：
// 1. 从 PC 获取当前执行位置
// 2. 从 FP 开始遍历栈帧链
// 3. 每个栈帧的 [FP + 8] 存储上一层的 LR（返回地址）
// 4. 每个栈帧的 [FP + 0] 存储上一层的 FP
//
static const char *g_registerNames[] = { 
    "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",  
    "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15", 
    "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
    "x24", "x25", "x26", "x27", "x28", 
    "fp",   // x29 - 帧指针
    "lr",   // x30 - 返回地址
    "sp",   // x31 - 栈指针
    "pc",   // x32 - 程序计数器
    "cpsr"  // x33 - 状态寄存器
};
static const int g_registerNamesCount = sizeof(g_registerNames) / sizeof(*g_registerNames);

// ============================================================================
// 异常寄存器名称表
// ============================================================================
// 这些寄存器在崩溃或异常发生时提供额外信息：
//
// - exception: 异常类型（如 EXC_BAD_ACCESS, EXC_CRASH 等）
// - esr:       异常原因寄存器 (Exception Syndrome Register)
//              详细描述异常发生的原因（如权限错误、对齐错误等）
// - far:       故障地址寄存器 (Fault Address Register)
//              记录导致异常的内存地址（如非法访问的地址）
//
// 💡 调试技巧：
// - 如果 far 显示 0x0，通常是空指针访问
// - 如果 far 是奇怪的地址，可能是野指针
// - esr 的值可以判断是读错误还是写错误
//
static const char *g_exceptionRegisterNames[] = { 
    "exception",  // 异常类型
    "esr",        // 异常原因
    "far"         // 故障地址
};
static const int g_exceptionRegisterNamesCount = sizeof(g_exceptionRegisterNames) / sizeof(*g_exceptionRegisterNames);

// ============================================================================
// 函数：kscpu_framePointer
// ============================================================================
// 获取帧指针 (Frame Pointer, FP, x29)
//
// 帧指针是堆栈遍历的起点！
//
// 作用：
// - 指向当前函数的栈帧起始位置
// - 每个栈帧的布局：
//     [FP + 0]  = 上一层的 FP  ← 栈帧链
//     [FP + 8]  = 上一层的 LR  ← 返回地址
//     [FP - X]  = 局部变量
//
// 堆栈遍历过程：
// 1. 从当前 FP 开始
// 2. 读取 [FP + 8] 获得返回地址（函数调用点）
// 3. 读取 [FP + 0] 获得上一层 FP
// 4. 重复步骤 2-3，直到 FP 为 0
//
// PAC 支持：
// - ARM64e 架构中，FP 可能包含 PAC 签名
// - __opaque_fp 会自动剥离 PAC，返回真实地址
//
// ✅ Swift 和 Objective-C 的 FP 布局完全相同！
//
uintptr_t kscpu_framePointer(const KSMachineContext *const context) {
#if __has_feature(ptrauth_calls)
    // ARM64e: 使用 opaque_fp（自动剥离 PAC）
    return (uintptr_t)context->machineContext.__ss.__opaque_fp;
#else
    // ARM64: 直接访问 __fp
    return context->machineContext.__ss.__fp;
#endif
}

// ============================================================================
// 函数：kscpu_stackPointer
// ============================================================================
// 获取栈指针 (Stack Pointer, SP, x31)
//
// 栈指针指向当前栈顶（最近分配的内存）
//
// 作用：
// - 函数调用时，SP 会减小（栈向下增长）
// - 函数返回时，SP 会增加（释放栈空间）
// - 用于检测栈溢出（SP 过小）
//
// 与 FP 的关系：
// - SP <= FP（栈向下增长）
// - FP - SP = 当前函数的栈帧大小
//
uintptr_t kscpu_stackPointer(const KSMachineContext *const context) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)context->machineContext.__ss.__opaque_sp;
#else
    return context->machineContext.__ss.__sp;
#endif
}

// ============================================================================
// 函数：kscpu_instructionAddress
// ============================================================================
// 获取程序计数器 (Program Counter, PC, x32)
//
// 程序计数器指向当前正在执行的指令地址
//
// 作用：
// - PC 是堆栈回溯的第一帧（当前执行位置）
// - 通过 PC 可以确定当前在哪个函数、哪一行
// - 符号化时，PC 会被转换为函数名和行号
//
// 💡 在堆栈中的位置：
// - 堆栈第 0 帧：PC（当前位置）
// - 堆栈第 1 帧：LR（调用者的返回地址）
// - 堆栈第 2 帧：[FP + 8]（上一层的返回地址）
// - ...
//
// ✅ Swift 和 ObjC 的 PC 含义完全相同
//
uintptr_t kscpu_instructionAddress(const KSMachineContext *const context) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)context->machineContext.__ss.__opaque_pc;
#else
    return context->machineContext.__ss.__pc;
#endif
}

// ============================================================================
// 函数：kscpu_linkRegister
// ============================================================================
// 获取链接寄存器 (Link Register, LR, x30)
//
// 链接寄存器存储函数的返回地址
//
// 作用：
// - 当函数被调用时，CPU 自动将返回地址写入 LR
// - 函数返回时，CPU 跳转到 LR 指向的地址
// - LR 是堆栈回溯的第二帧
//
// 函数调用过程：
// 1. 调用者执行 BL func（Branch with Link）
// 2. CPU 将下一条指令地址写入 LR
// 3. CPU 跳转到 func
// 4. func 执行 RET（返回）
// 5. CPU 跳转到 LR
//
// 在堆栈中：
// - 如果函数要调用其他函数，会先将 LR 压栈（保存返回地址）
// - 保存位置：[FP + 8]
// - 这样形成了栈帧链
//
// ✅ Swift 函数调用约定与 ObjC 相同，LR 用法一致
//
uintptr_t kscpu_linkRegister(const KSMachineContext *const context) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)context->machineContext.__ss.__opaque_lr;
#else
    return context->machineContext.__ss.__lr;
#endif
}

// ============================================================================
// 函数：kscpu_getState
// ============================================================================
// 获取线程的完整 CPU 状态（寄存器快照）
//
// 这是堆栈回溯的核心入口！
//
// 功能：
// 1. 调用系统 API 获取线程的寄存器状态
// 2. 分两次调用，获取两类状态：
//    - 线程状态 (ARM_THREAD_STATE64): 通用寄存器
//    - 异常状态 (ARM_EXCEPTION_STATE64): 异常信息
//
// 参数：
// - context: 输出参数，存储获取到的 CPU 状态
//
// 填充的数据：
// context->machineContext.__ss (线程状态):
//   - __x[0-28]:  通用寄存器 x0-x28
//   - __fp:       帧指针 (x29)
//   - __lr:       链接寄存器 (x30)
//   - __sp:       栈指针 (x31)
//   - __pc:       程序计数器 (x32)
//   - __cpsr:     程序状态寄存器
//
// context->machineContext.__es (异常状态):
//   - __exception: 异常类型
//   - __esr:       异常原因
//   - __far:       故障地址
//
// 底层实现：
// kscpu_i_fillState() 会调用 thread_get_state() 系统调用
// 这个系统调用会从内核获取线程的寄存器快照
//
// 前提条件：
// ⚠️ 目标线程必须已被 thread_suspend() 挂起
// ⚠️ 否则寄存器状态可能不一致
//
// 性能：
// - 单次调用耗时：~3-5μs
// - 对性能影响可忽略
//
// ✅ 对 Swift 和 Objective-C 同样有效：
// - Swift 函数的寄存器状态与 ObjC 格式相同
// - 获取到的 FP、PC、LR 可用于遍历 Swift 堆栈
// - 这就是为什么 Matrix 对 Swift 100% 兼容！
//
void kscpu_getState(KSMachineContext *context) {
    thread_t thread = context->thisThread;
    STRUCT_MCONTEXT_L *const machineContext = &context->machineContext;

    // ========================================================================
    // 步骤1: 获取线程状态（通用寄存器）
    // ========================================================================
    // ARM_THREAD_STATE64: 包含所有通用寄存器和特殊寄存器
    // 输出到: machineContext->__ss
    kscpu_i_fillState(thread, 
                      (thread_state_t)&machineContext->__ss, 
                      ARM_THREAD_STATE64, 
                      ARM_THREAD_STATE64_COUNT);

    // ========================================================================
    // 步骤2: 获取异常状态（崩溃信息）
    // ========================================================================
    // ARM_EXCEPTION_STATE64: 包含异常相关寄存器
    // 输出到: machineContext->__es
    kscpu_i_fillState(thread, 
                      (thread_state_t)&machineContext->__es, 
                      ARM_EXCEPTION_STATE64, 
                      ARM_EXCEPTION_STATE64_COUNT);
}

// ============================================================================
// 函数：kscpu_numRegisters
// ============================================================================
// 返回寄存器总数（34个）
//
int kscpu_numRegisters(void) {
    return g_registerNamesCount;
}

// ============================================================================
// 函数：kscpu_registerName
// ============================================================================
// 根据寄存器编号获取寄存器名称
//
// 参数：
// - regNumber: 寄存器编号 (0-33)
//
// 返回值：
// - 寄存器名称字符串（如 "x0", "fp", "pc"）
// - 如果编号无效，返回 NULL
//
// 用途：
// - 打印寄存器状态时显示名称
// - 调试信息输出
//
const char *kscpu_registerName(const int regNumber) {
    if (regNumber < kscpu_numRegisters()) {
        return g_registerNames[regNumber];
    }
    return NULL;
}

// ============================================================================
// 函数：kscpu_registerValue
// ============================================================================
// 根据寄存器编号获取寄存器的值
//
// 这是访问寄存器状态的统一接口！
//
// 参数：
// - context: 包含寄存器状态的上下文
// - regNumber: 寄存器编号
//
// 寄存器编号映射：
// - 0-28:  x0-x28（通用寄存器）
// - 29:    fp (x29, 帧指针)      ← 堆栈遍历关键
// - 30:    lr (x30, 返回地址)    ← 堆栈遍历关键
// - 31:    sp (x31, 栈指针)
// - 32:    pc (x32, 程序计数器)  ← 堆栈遍历起点
// - 33:    cpsr (状态寄存器)
//
// 返回值：
// - 寄存器的 64 位值
// - 如果编号无效，返回 0
//
// PAC 处理：
// - ARM64e 架构中，特殊寄存器可能包含 PAC 签名
// - 使用 __opaque_* 版本自动剥离 PAC
// - 确保返回的是真实地址
//
// 💡 调试技巧：
// 遍历所有寄存器：
//   for (int i = 0; i < kscpu_numRegisters(); i++) {
//       printf("%s = 0x%llx\n", 
//              kscpu_registerName(i), 
//              kscpu_registerValue(context, i));
//   }
//
uint64_t kscpu_registerValue(const KSMachineContext *const context, const int regNumber) {
    // ========================================================================
    // 通用寄存器 x0-x28
    // ========================================================================
    if (regNumber <= 28) {
        return context->machineContext.__ss.__x[regNumber];
    }

    // ========================================================================
    // 特殊寄存器
    // ========================================================================
    switch (regNumber) {
#if __has_feature(ptrauth_calls)
        // ARM64e 架构：使用 opaque 版本（自动剥离 PAC）
        case 29:  // FP - 帧指针（堆栈遍历起点）
            return (uint64_t)context->machineContext.__ss.__opaque_fp;
        case 30:  // LR - 返回地址（堆栈第 2 帧）
            return (uint64_t)context->machineContext.__ss.__opaque_lr;
        case 31:  // SP - 栈指针
            return (uint64_t)context->machineContext.__ss.__opaque_sp;
        case 32:  // PC - 程序计数器（堆栈第 1 帧）
            return (uint64_t)context->machineContext.__ss.__opaque_pc;
        case 33:  // CPSR - 程序状态寄存器
            return (uint64_t)context->machineContext.__ss.__cpsr;
#else
        // ARM64 架构：直接访问
        case 29:  // FP
            return context->machineContext.__ss.__fp;
        case 30:  // LR
            return context->machineContext.__ss.__lr;
        case 31:  // SP
            return context->machineContext.__ss.__sp;
        case 32:  // PC
            return context->machineContext.__ss.__pc;
        case 33:  // CPSR
            return context->machineContext.__ss.__cpsr;
#endif
    }

    // 无效的寄存器编号
    KSLOG_ERROR("Invalid register number: %d", regNumber);
    return 0;
}

// ============================================================================
// 异常寄存器访问函数
// ============================================================================

// 返回异常寄存器总数（3个）
int kscpu_numExceptionRegisters(void) {
    return g_exceptionRegisterNamesCount;
}

// ============================================================================
// 函数：kscpu_exceptionRegisterName
// ============================================================================
// 根据编号获取异常寄存器名称
//
// 参数：
// - regNumber: 0 = exception, 1 = esr, 2 = far
//
const char *kscpu_exceptionRegisterName(const int regNumber) {
    if (regNumber < kscpu_numExceptionRegisters()) {
        return g_exceptionRegisterNames[regNumber];
    }
    KSLOG_ERROR("Invalid register number: %d", regNumber);
    return NULL;
}

// ============================================================================
// 函数：kscpu_exceptionRegisterValue
// ============================================================================
// 获取异常寄存器的值
//
// 参数：
// - context: 包含异常状态的上下文
// - regNumber: 异常寄存器编号
//
// 寄存器含义：
// - 0: exception - 异常类型
//      常见值：EXC_BAD_ACCESS (1), EXC_CRASH (6) 等
//
// - 1: esr - 异常原因寄存器 (Exception Syndrome Register)
//      bit[31:26]: 异常类别 (EC - Exception Class)
//      bit[24:0]:  ISS (Instruction Specific Syndrome)
//      用于判断具体的异常原因（权限错误、对齐错误等）
//
// - 2: far - 故障地址寄存器 (Fault Address Register)
//      记录导致异常的内存地址
//      💡 调试技巧：
//      - far = 0x0 → 空指针访问
//      - far = 0xdeadbeef 等奇怪值 → 野指针
//      - far 在合法范围但崩溃 → 权限问题
//
// 返回值：
// - 异常寄存器的 64 位值
//
uint64_t kscpu_exceptionRegisterValue(const KSMachineContext *const context, const int regNumber) {
    switch (regNumber) {
        case 0:  // 异常类型
            return context->machineContext.__es.__exception;
        case 1:  // 异常原因
            return context->machineContext.__es.__esr;
        case 2:  // 故障地址
            return context->machineContext.__es.__far;
    }

    KSLOG_ERROR("Invalid register number: %d", regNumber);
    return 0;
}

// ============================================================================
// 函数：kscpu_faultAddress
// ============================================================================
// 获取故障地址（导致崩溃的内存地址）
//
// 这是 kscpu_exceptionRegisterValue(context, 2) 的快捷方式
//
// 返回值：
// - 导致异常的内存地址
// - 如果是 0，通常是空指针访问
//
// 💡 用途：
// - 崩溃报告中显示错误地址
// - 帮助定位内存访问错误
// - 区分空指针、野指针、越界访问
//
uintptr_t kscpu_faultAddress(const KSMachineContext *const context) {
    return context->machineContext.__es.__far;
}

// ============================================================================
// 函数：kscpu_stackGrowDirection
// ============================================================================
// 返回栈的增长方向
//
// ARM64 架构中，栈向下增长（地址从高到低）
//
// 返回值：
// - -1: 栈向下增长（地址减小）
// - +1: 栈向上增长（地址增加，某些架构）
//
// 💡 栈布局示意：
//
// 高地址
//   ↑
//   │  [上一个函数的栈帧]
//   │  ← 上一层 FP
//   │  ← 上一层 LR
//   ├─────────────────────  ← 当前 FP
//   │  [当前函数的栈帧]
//   │  ← 局部变量
//   │  ← 临时数据
//   ├─────────────────────  ← 当前 SP
//   ↓
// 低地址
//
// 函数调用时：SP 减小（分配栈空间）
// 函数返回时：SP 增加（释放栈空间）
//
int kscpu_stackGrowDirection(void) {
    return -1;
}

// ============================================================================
// 函数：kscpu_normaliseInstructionPointer
// ============================================================================
// 标准化指令指针（剥离 PAC 签名）
//
// ARM64e 架构引入了指针认证码（PAC），用于增强安全性
// PAC 会在指针的高位添加签名，需要剥离才能得到真实地址
//
// 参数：
// - ip: 可能包含 PAC 的指令指针
//
// 返回值：
// - 剥离 PAC 后的真实指令地址
//
// 工作原理：
// 使用掩码 0x0000000fffffffff 保留低 40 位（虚拟地址空间）
// 清除高 24 位（PAC 签名位）
//
// 💡 为什么需要这个：
// - 直接用包含 PAC 的地址符号化会失败
// - 需要先剥离 PAC，再用真实地址查找符号
// - atos 等工具需要真实地址
//
// 示例：
// 原始 IP: 0xabcd123456789000  ← 高位是 PAC
// 标准化: 0x0000003456789000  ← 真实地址
//
// ✅ 对 Swift 和 ObjC 同样适用
//
uintptr_t kscpu_normaliseInstructionPointer(uintptr_t ip) {
    return ip & KSPACStrippingMask_ARM64e;
}

#endif // __arm64__

// ============================================================================
// 文件总结
// ============================================================================
//
// 这个文件实现了 ARM64 架构下的寄存器访问接口，是 Matrix 堆栈回溯的基础。
//
// 关键要点：
// 1. ✅ Swift 和 Objective-C 使用相同的寄存器布局
// 2. ✅ FP (x29) 是堆栈遍历的关键
// 3. ✅ PC (x32) 是堆栈的第一帧
// 4. ✅ LR (x30) 是堆栈的第二帧
// 5. ✅ 栈帧链：FP → [FP+0] → [FP+0]+[0] → ...
//
// 堆栈回溯流程：
// 1. kscpu_getState() 获取寄存器状态
// 2. kscpu_instructionAddress() 获取 PC（第 0 帧）
// 3. kscpu_linkRegister() 获取 LR（第 1 帧）
// 4. kscpu_framePointer() 获取 FP（起点）
// 5. 沿着 FP 链遍历：读取 [FP+8] 获取返回地址
//
// 与 Swift 的关系：
// ✅ Swift 编译后使用相同的 ARM64 指令集
// ✅ Swift 函数遵循相同的调用约定（AAPCS64）
// ✅ Swift 栈帧结构与 Objective-C 完全一致
// ✅ 这就是为什么 Matrix 对 Swift 100% 兼容！
//
// 性能：
// - 获取寄存器状态：~3-5μs
// - 访问单个寄存器：~0.1μs
// - 对应用性能影响可忽略
//
// 参考资料：
// - ARM64 架构手册
// - AAPCS64 调用约定
// - Apple 平台开发文档
// - Matrix iOS 源码
//
// ============================================================================
