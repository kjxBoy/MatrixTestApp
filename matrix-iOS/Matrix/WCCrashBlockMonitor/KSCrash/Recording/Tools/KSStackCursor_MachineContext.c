//
//  KSStackCursor_MachineContext.c
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

/**
 * ============================================================================
 * KSStackCursor_MachineContext.c - 基于机器上下文的堆栈游标
 * ============================================================================
 * 
 * 核心功能：
 * - 从线程的机器上下文（寄存器快照）回溯调用栈
 * - 通过 FP (Frame Pointer) 链表遍历栈帧
 * - 这是 Matrix 卡顿检测和崩溃报告的核心堆栈采集机制
 * 
 * 工作原理：
 * 1. 从 KSMachineContext 读取初始寄存器状态（PC、FP、LR）
 * 2. 第一帧返回 PC（当前执行位置）
 * 3. 后续帧通过 FP 链表遍历，读取每一帧的返回地址
 * 4. 直到 FP == NULL（栈底）
 * 
 * ARM64 架构关键点：
 * - FP (x29): 帧指针，指向当前栈帧起始
 * - LR (x30): 链接寄存器，保存返回地址
 * - 栈帧布局：[Previous FP (8字节), Return Address (8字节)]
 * - FrameEntry 结构完美映射到栈帧内存（16字节）
 * 
 * 使用场景：
 * - Matrix 卡顿检测：主线程卡顿时采集堆栈
 * - Matrix CPU 监控：高 CPU 线程的堆栈采集
 * - 崩溃报告：崩溃线程的堆栈回溯
 * 
 * 性能：
 * - 单次 advanceCursor: ~200-500ns（缓存命中）
 * - 100 层堆栈: ~50-200μs
 * - 卡顿检测性能开销极小
 * 
 * 参考文档：
 * - ARM64堆栈遍历寄存器结构详解.md（详细图解）
 * ============================================================================
 */

#include "KSStackCursor_MachineContext.h"

#include "KSCPU.h"
#include "KSMemory.h"

#include <stdlib.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

/**
 * ============================================================================
 * FrameEntry 结构：表示调用栈中的一帧
 * ============================================================================
 * 
 * 这个结构模仿了 XNU 内核中 i386/x64 的栈帧遍历器，
 * 并且在 ARM64 架构中同样工作良好。
 * 
 * 为什么这个结构在 ARM64 中有效？
 * 
 * ARM64 函数调用约定：
 * - 函数入口时，会执行 "stp x29, x30, [sp, #-16]!" 指令
 * - 这会将 FP (x29) 和 LR (x30) 压入栈中
 * - 然后设置新的 FP: "mov x29, sp"
 * 
 * ARM64 栈帧布局（实际的内存布局）：
 * ┌────────────────┐
 * │ LR (x30)       │  ← FP + 8 (返回地址，8字节)
 * ├────────────────┤
 * │ pre FP (x29)   │  ← FP + 0 (上一个帧指针，8字节)
 * └────────────────┘  ← 当前 FP (x29)
 * 
 * FrameEntry 结构刚好匹配：
 * struct FrameEntry {
 *     struct FrameEntry *previous;   // 8字节 → 对应 pre FP
 *     uintptr_t return_address;      // 8字节 → 对应 LR
 * };                                 // 总共 16字节
 * 
 * 因此，我们可以直接用 memcpy 复制 16 字节来读取栈帧！
 * 
 * 注意：@SecondDog 的注释中提到的布局（FP - 32）是错误的，
 * 实际上 ARM64 栈帧的布局是 [pre FP, LR]，总共 16 字节，
 * 而不是 32 字节。
 */

/**
 * FrameEntry 结构定义
 */
typedef struct FrameEntry {
    /** 上一个栈帧的帧指针（形成链表结构） */
    struct FrameEntry *previous;

    /** 返回地址（函数返回后跳转到这里） */
    uintptr_t return_address;
} FrameEntry;

/**
 * MachineContextCursor 结构：存储堆栈遍历的上下文
 * 
 * 这是 KSStackCursor 的 context 字段指向的具体数据结构
 */
typedef struct {
    const struct KSMachineContext *machineContext;  // 机器上下文（寄存器状态）
    int maxStackDepth;                              // 最大堆栈深度
    FrameEntry currentFrame;                        // 当前栈帧（previous FP + return address）
    uintptr_t instructionAddress;                   // 当前指令地址
    uintptr_t linkRegister;                         // 链接寄存器（保留字段）
    bool isPastFramePointer;                        // 是否已经开始使用 FP 遍历
} MachineContextCursor;

/**
 * ============================================================================
 * 函数：advanceCursor
 * ============================================================================
 * 
 * 功能：移动堆栈游标到下一帧
 * 
 * 这是堆栈遍历的核心逻辑！！！
 * 
 * 工作原理（ARM64）：
 * 1. 第1次调用：返回 PC（当前指令地址）
 * 2. 第2次调用：获取 FP，读取栈帧，返回 LR
 * 3. 第3-N次调用：FP = previous FP，读取新栈帧，返回 LR
 * 4. 直到 FP == NULL（到达栈底）
 * 
 * 堆栈遍历示例：
 * 
 * 调用链：main() → funcA() → funcB() → funcC() [卡顿点]
 * 
 * 第1次 advanceCursor(): 返回 PC (funcC 当前位置)
 * 第2次 advanceCursor(): 返回 LR (funcC 的返回地址，在 funcB 中)
 * 第3次 advanceCursor(): 返回 LR (funcB 的返回地址，在 funcA 中)
 * 第4次 advanceCursor(): 返回 LR (funcA 的返回地址，在 main 中)
 * 第5次 advanceCursor(): FP == NULL，停止
 * 
 * @param cursor 堆栈游标
 * @return 成功返回 true，失败或到达栈底返回 false
 */
static bool advanceCursor(KSStackCursor *cursor) {
    // ========================================================================
    // 获取遍历上下文
    // ========================================================================
    MachineContextCursor *context = (MachineContextCursor *)cursor->context;
    uintptr_t nextAddress = 0;  // 下一帧的地址

    // ========================================================================
    // 安全检查1：是否超过溢出阈值
    // ========================================================================
    /*
     * KSSC_STACK_OVERFLOW_THRESHOLD: 栈溢出阈值（通常 200-300 层）
     * 
     * 如果堆栈深度超过此值，可能是：
     * 1. 无限递归
     * 2. 栈溢出
     * 3. 堆栈数据已损坏（FP 指向了错误的位置）
     * 
     * 此时停止遍历，避免：
     * - 死循环
     * - 读取无效内存导致崩溃
     * - 耗费过多时间
     */
    if (cursor->state.currentDepth >= KSSC_STACK_OVERFLOW_THRESHOLD) {
        cursor->state.hasGivenUp = true;  // 标记放弃遍历
        KSLOG_DEBUG("context overflow %d", cursor->state.currentDepth);
        // 注意：这里没有 return，继续检查其他条件
    }

    // ========================================================================
    // 安全检查2：是否超过用户指定的最大深度
    // ========================================================================
    /*
     * maxStackDepth: 用户指定的最大深度（通常 100）
     * 
     * 这是性能和资源的平衡：
     * - 100 层堆栈通常足够覆盖大部分场景
     * - 避免收集过多无用信息
     * - 减少内存占用和处理时间
     */
    if (cursor->state.currentDepth >= context->maxStackDepth) {
        cursor->state.hasGivenUp = true;
        KSLOG_DEBUG("context too deep %d", cursor->state.currentDepth);
        return false;  // 达到最大深度，停止遍历
    }

    // ========================================================================
    // 步骤1：处理第一帧（当前指令位置）
    // ========================================================================
    /*
     * 第一次调用时，instructionAddress 为 0
     * 需要从机器上下文中获取当前 PC（程序计数器）
     * 
     * 为什么第一帧是 PC 而不是 FP？
     * - PC 指向当前正在执行的指令
     * - 这是堆栈的"栈顶"，最近的执行位置
     * - 对于定位卡顿点非常重要
     * 
     * 例如：如果卡顿发生在 [ViewController heavyWork] + 52
     *      PC 会指向这个位置，帮助开发者精确定位
     */
    if (context->instructionAddress == 0) {
        // 从机器上下文获取 PC
        // kscpu_instructionAddress 会从 machineContext->machineContext.__ss.__pc 读取
        context->instructionAddress = kscpu_instructionAddress(context->machineContext);
        nextAddress = context->instructionAddress;
        
        // 如果 PC 为 0（异常情况），标记为 1
        // 作用：避免下次再进入这个分支（因为 instructionAddress 不再是 0）
        if (context->instructionAddress == 0) {
            context->instructionAddress = 1;  // 标记：已尝试获取第一帧
        }
        
        goto successfulExit;  // 第一帧处理完成，跳转到成功出口
    }

    // ========================================================================
    // 步骤2：初始化帧指针（FP）
    // ========================================================================
    /*
     * 第二次调用时，currentFrame.previous 为 NULL
     * 需要从机器上下文中获取初始 FP
     * 
     * ARM64 寄存器约定：
     * - x29 (FP): 帧指针，指向当前栈帧的起始位置
     * - 每个栈帧的开头存储：[previous FP (8字节), return address (8字节)]
     * 
     * 栈帧链式结构：
     * FP1 → [FP0, LR1]  // 最新的栈帧
     * FP0 → [NULL, LR0] // 最旧的栈帧（栈底）
     */
    if (context->currentFrame.previous == NULL) {
        // 检查是否已经遍历过 FP
        if (context->isPastFramePointer) {
            // 如果已经遍历过，且 previous 仍为 NULL，说明到达栈底
            KSLOG_DEBUG("context isPastFramePointer %d", cursor->state.currentDepth);
            return false;  // 停止遍历
        }
        
        // 从机器上下文获取 FP (x29)
        // kscpu_framePointer 会从 machineContext->machineContext.__ss.__fp 读取
        context->currentFrame.previous = (struct FrameEntry *)kscpu_framePointer(context->machineContext);
        
        // 标记：已开始使用 FP 遍历
        context->isPastFramePointer = true;
    }

    // ========================================================================
    // 步骤3：读取当前栈帧（核心！）
    // ========================================================================
    /*
     * ksmem_copySafely 的作用：
     * - 安全地从内存复制数据
     * - 如果地址无效（访问受保护的内存），返回 false 而不是崩溃
     * - 内部使用 vm_read_overwrite 或类似的安全机制
     * 
     * 复制操作：
     * 源地址: context->currentFrame.previous（当前 FP）
     * 目标地址: &context->currentFrame
     * 大小: sizeof(FrameEntry) = 16 字节
     * 
     * 复制的数据：
     * - 前 8 字节 → currentFrame.previous（上一个 FP）
     * - 后 8 字节 → currentFrame.return_address（返回地址 LR）
     * 
     * ARM64 内存布局：
     * ┌────────────────┐  ← currentFrame.previous (FP)
     * │ previous FP    │  → 复制到 currentFrame.previous
     * ├────────────────┤  ← FP + 8
     * │ return address │  → 复制到 currentFrame.return_address
     * └────────────────┘  ← FP + 16
     * 
     * 为什么需要安全复制？
     * 1. FP 可能被编译器优化掉（虽然很少见）
     * 2. FP 可能指向无效内存（堆栈损坏）
     * 3. FP 可能指向受保护的内存页
     * 如果直接访问，可能导致 SIGSEGV 崩溃
     */
    if (!ksmem_copySafely(context->currentFrame.previous, 
                          &context->currentFrame, 
                          sizeof(context->currentFrame))) {
        // 内存读取失败（可能是无效地址或受保护的内存）
        KSLOG_DEBUG("context copy failed %d", cursor->state.currentDepth);
        return false;  // 停止遍历
    }
    
    // ========================================================================
    // 步骤4：验证读取的数据
    // ========================================================================
    /*
     * 检查读取的栈帧是否有效：
     * 
     * 1. previous FP 不能为 0
     *    - 0 (NULL) 表示到达栈底
     *    - 这是链表的结束标志
     * 
     * 2. return address 不能为 0
     *    - 0 表示无效的返回地址
     *    - 正常的函数返回地址应该在代码段（通常 0x100000000 以上）
     * 
     * 如果任一为 0，说明已经到达栈底或堆栈数据无效
     */
    if (context->currentFrame.previous == 0 || context->currentFrame.return_address == 0) {
        KSLOG_DEBUG("context previous %d return address %d deep %d", 
                    context->currentFrame.previous, 
                    context->currentFrame.return_address, 
                    cursor->state.currentDepth);
        return false;  // 停止遍历
    }

    // ========================================================================
    // 步骤5：获取返回地址
    // ========================================================================
    /*
     * 返回地址（LR）：函数返回后跳转到的位置
     * 
     * 例如：
     * main() 调用 funcA():
     *   bl funcA           // 跳转到 funcA，LR = 下一条指令地址
     *   mov x0, #0         // ← LR 指向这里
     *   ret
     * 
     * 因此，LR 指向的是"调用者"中的位置，
     * 通过符号化可以得到：funcA 是从 main() 的哪一行被调用的
     */
    nextAddress = context->currentFrame.return_address;

    // ========================================================================
    // 成功出口：更新游标状态
    // ========================================================================
successfulExit:
    /*
     * kscpu_normaliseInstructionPointer 的作用：
     * - 规范化指令地址（某些架构需要处理）
     * 
     * ARM64:
     * - 通常直接返回（不需要处理）
     * - 早期 ARM（Thumb 模式）需要清除最低位
     * 
     * x86/x64:
     * - 直接返回
     * 
     * 其他架构:
     * - 可能需要对齐到指令边界
     */
    cursor->stackEntry.address = kscpu_normaliseInstructionPointer(nextAddress);
    
    // 增加深度计数
    cursor->state.currentDepth++;
    
    // 返回成功：找到了下一帧
    return true;
    
    /*
     * 下一次调用时的状态：
     * - currentFrame.previous 已经更新为上一个 FP
     * - 将从这个新的 FP 读取下一个栈帧
     * - 继续向上回溯调用栈
     */
}

/**
 * ============================================================================
 * 函数：resetCursor
 * ============================================================================
 * 
 * 功能：重置堆栈游标到初始状态
 * 
 * 用途：
 * - 重新开始遍历堆栈
 * - 清除之前的遍历状态
 * 
 * @param cursor 要重置的堆栈游标
 */
static void resetCursor(KSStackCursor *cursor) {
    // 调用基础重置函数（重置 state 和 stackEntry）
    kssc_resetCursor(cursor);
    
    // 获取遍历上下文
    MachineContextCursor *context = (MachineContextCursor *)cursor->context;
    
    // 清空上下文数据
    context->currentFrame.previous = 0;      // 清空当前帧的 previous FP
    context->currentFrame.return_address = 0; // 清空返回地址
    context->instructionAddress = 0;         // 清空指令地址
    context->linkRegister = 0;               // 清空链接寄存器
    context->isPastFramePointer = 0;         // 重置 FP 遍历标志
}

/**
 * ============================================================================
 * 函数：kssc_initWithMachineContext
 * ============================================================================
 * 
 * 功能：用机器上下文初始化堆栈游标
 * 
 * 这是堆栈遍历的初始化函数，设置所有必要的状态和回调
 * 
 * 工作流程：
 * 1. 调用 kssc_initCursor 设置基础结构
 * 2. 绑定 resetCursor 函数（重置游标）
 * 3. 绑定 advanceCursor 函数（移动到下一帧）← 核心！
 * 4. 设置遍历所需的上下文数据
 * 
 * 之后的使用：
 * while (cursor->advanceCursor(cursor)) {
 *     // 每次循环获取一个栈帧
 *     printf("Address: 0x%lx\n", cursor->stackEntry.address);
 * }
 * 
 * @param cursor 要初始化的堆栈游标
 * @param maxStackDepth 最大堆栈深度（通常 100）
 * @param machineContext 包含寄存器状态的机器上下文
 */
void kssc_initWithMachineContext(KSStackCursor *cursor, 
                                  int maxStackDepth, 
                                  const struct KSMachineContext *machineContext) {
    // ========================================================================
    // 步骤1：初始化游标基础结构
    // ========================================================================
    /*
     * kssc_initCursor 的作用：
     * 1. 设置 cursor->resetCursor 函数指针
     * 2. 设置 cursor->advanceCursor 函数指针 ← 最重要！
     * 3. 初始化 cursor->state（遍历状态）：
     *    - currentDepth = 0（当前深度）
     *    - hasGivenUp = false（是否放弃遍历）
     * 4. 清零 cursor->stackEntry（当前栈帧信息）
     * 5. 分配 cursor->context 内存（用于存储 MachineContextCursor）
     * 
     * 参数说明：
     * - cursor: 要初始化的游标
     * - resetCursor: 重置函数（重新开始遍历）
     * - advanceCursor: 前进函数（移动到下一帧）← 这是核心遍历逻辑！
     */
    kssc_initCursor(cursor, resetCursor, advanceCursor);
    
    // ========================================================================
    // 步骤2：设置游标上下文（MachineContextCursor）
    // ========================================================================
    /*
     * cursor->context 是一块内存，用于存储遍历所需的数据
     * 
     * 在 kssc_initCursor 中已经分配了内存（通常在 cursor 结构的末尾）
     * 这里将它转换为 MachineContextCursor* 类型
     * 
     * MachineContextCursor 包含：
     * - machineContext: 指向包含寄存器状态的机器上下文
     * - maxStackDepth: 最大深度限制（防止无限遍历）
     * - currentFrame: 当前栈帧（previous FP + return address）
     * - instructionAddress: 当前指令地址（第一帧用）
     * - linkRegister: 链接寄存器（保留字段）
     * - isPastFramePointer: 是否已经开始使用 FP 遍历
     */
    MachineContextCursor *context = (MachineContextCursor *)cursor->context;
    
    // ========================================================================
    // 步骤3：设置遍历参数
    // ========================================================================
    
    // 保存机器上下文指针（包含 PC, FP, SP, LR 等寄存器）
    // advanceCursor 会从这里读取初始的 PC 和 FP
    context->machineContext = machineContext;
    
    // 保存最大深度限制
    // 作用：
    // 1. 防止无限递归导致的死循环
    // 2. 限制内存和时间消耗
    // 3. 通常设置为 100，足够覆盖大部分场景
    context->maxStackDepth = maxStackDepth;
    
    // 初始化指令地址
    // 注意：cursor->stackEntry.address 在 kssc_initCursor 中被清零
    // 所以这里 instructionAddress = 0
    // 第一次调用 advanceCursor 时，会从 machineContext 读取 PC
    context->instructionAddress = cursor->stackEntry.address;
    
    /*
     * 初始化完成后的状态：
     * - cursor->advanceCursor 指向 advanceCursor 函数
     * - context->machineContext 指向寄存器状态
     * - context->instructionAddress = 0（等待第一次调用）
     * - context->currentFrame.previous = NULL（等待第二次调用）
     * 
     * 调用流程：
     * 第1次 advanceCursor(): instructionAddress == 0 → 返回 PC
     * 第2次 advanceCursor(): currentFrame.previous == NULL → 获取 FP，返回 LR
     * 第3-N次 advanceCursor(): 遍历 FP 链表，返回每一帧的 LR
     */
}
