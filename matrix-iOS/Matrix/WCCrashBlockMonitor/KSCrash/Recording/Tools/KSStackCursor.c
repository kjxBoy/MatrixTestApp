//
//  KSStackCursor.c
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
 * KSStackCursor.c - 堆栈游标基础实现
 * ============================================================================
 * 
 * 功能：
 * - 提供堆栈游标的基础初始化和重置功能
 * - 定义默认的行为（当未设置自定义函数指针时）
 * 
 * 文件结构：
 * 1. 默认的 advanceCursor 实现（警告未正确初始化）
 * 2. 通用重置函数
 * 3. 通用初始化函数
 * 
 * 注意：
 * - 这个文件只包含基础功能
 * - 具体的堆栈遍历逻辑在子类型文件中：
 *   - KSStackCursor_MachineContext.c: 从机器上下文回溯
 *   - KSStackCursor_Backtrace.c: 从 backtrace 数组创建
 *   - KSStackCursor_SelfThread.c: 当前线程堆栈
 * ============================================================================
 */

#include "KSStackCursor.h"
#include "KSSymbolicator.h"
#include <stdlib.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

/**
 * 默认的游标前进函数（占位实现）
 * 
 * 说明：
 * - 如果游标初始化时未提供自定义的 advanceCursor 函数，会使用此默认实现
 * - 此函数会输出警告日志并返回 false
 * 
 * 触发原因：
 * 1. 忘记调用具体的初始化函数（如 kssc_initWithMachineContext）
 * 2. C++ 异常处理钩子 (__cxa_throw) 失败
 * 3. Embedded Frameworks 导致符号冲突
 * 
 * 警告内容解释：
 * - "No stack cursor has been set": 游标未正确初始化
 * - "hooking __cxa_throw() failed": C++ 异常捕获失败
 * - "Embedded frameworks can cause this": 嵌入式框架可能导致此问题
 * 
 * 解决方案：
 * - 确保使用正确的初始化函数
 * - 检查 C++ 异常处理钩子是否正常工作
 * - 参考 GitHub issue: https://github.com/kstenerud/KSCrash/issues/205
 * 
 * @param cursor 游标指针（未使用，标记为 __unused）
 * @return 始终返回 false（表示无法前进）
 */
static bool g_advanceCursor(__unused KSStackCursor *cursor) {
    KSLOG_WARN(
    "No stack cursor has been set. For C++, this means that hooking __cxa_throw() failed for some reason. Embedded frameworks can cause this: https://github.com/kstenerud/KSCrash/issues/205");
    return false;
}

/**
 * 重置堆栈游标到初始状态
 * 
 * 作用：
 * - 清空状态信息：深度、放弃标志
 * - 清空堆栈帧信息：地址、镜像、符号
 * 
 * 详细操作：
 * 1. currentDepth = 0: 重置深度计数器
 * 2. hasGivenUp = false: 重置放弃标志
 * 3. address = 0: 清空当前地址
 * 4. imageAddress = 0: 清空镜像基址
 * 5. imageName = NULL: 清空镜像名称
 * 6. symbolAddress = 0: 清空符号地址
 * 7. symbolName = NULL: 清空符号名称
 * 
 * 注意事项：
 * - 这是通用重置函数，只清理 KSStackCursor 的公共字段
 * - 不会清理 context[] 中的私有数据
 * - 子类型游标如果有私有数据，需要自定义 resetCursor 函数
 * 
 * 使用场景：
 * - 需要重新遍历同一个堆栈
 * - 作为自定义 resetCursor 的基础实现
 * 
 * 示例：
 * ```c
 * void myCustomReset(KSStackCursor* cursor) {
 *     // 先调用基础重置
 *     kssc_resetCursor(cursor);
 *     
 *     // 再重置私有数据
 *     MyPrivateData* data = (MyPrivateData*)cursor->context[0];
 *     data->index = 0;
 *     data->framePointer = data->initialFP;
 * }
 * ```
 * 
 * @param cursor 要重置的游标
 */
void kssc_resetCursor(KSStackCursor *cursor) {
    // 重置状态信息
    cursor->state.currentDepth = 0;      // 深度归零
    cursor->state.hasGivenUp = false;    // 清除放弃标志
    
    // 重置堆栈帧信息
    cursor->stackEntry.address = 0;         // 清空当前指令地址
    cursor->stackEntry.imageAddress = 0;    // 清空镜像基址
    cursor->stackEntry.imageName = NULL;    // 清空镜像名称（指针置空）
    cursor->stackEntry.symbolAddress = 0;   // 清空符号起始地址
    cursor->stackEntry.symbolName = NULL;   // 清空符号名称（指针置空）
}

/**
 * 初始化堆栈游标（基础初始化）
 * 
 * 这是所有游标类型的通用初始化入口！
 * 
 * 功能：
 * 1. 设置符号化函数指针（统一使用 kssymbolicator_symbolicate）
 * 2. 设置游标前进函数指针（自定义或默认）
 * 3. 设置游标重置函数指针（自定义或默认）
 * 4. 调用重置函数，清空初始状态
 * 
 * @param cursor 要初始化的游标
 * @param resetCursor 自定义重置函数（NULL = 使用默认的 kssc_resetCursor）
 * @param advanceCursor 自定义前进函数（NULL = 使用默认的 g_advanceCursor，会警告）
 * 
 * 函数指针设置说明：
 * 
 * 1. symbolicate:
 *    - 始终使用 kssymbolicator_symbolicate
 *    - 这是统一的符号化接口，内部调用 dladdr()
 *    - 将虚拟地址转换为符号信息
 * 
 * 2. advanceCursor:
 *    - 如果提供自定义函数，使用自定义
 *    - 如果为 NULL，使用默认的 g_advanceCursor（会警告并返回 false）
 *    - 这是游标遍历的核心逻辑，必须正确实现
 * 
 * 3. resetCursor:
 *    - 如果提供自定义函数，使用自定义
 *    - 如果为 NULL，使用默认的 kssc_resetCursor
 *    - 初始化时会立即调用一次
 * 
 * 初始化流程示例：
 * ```c
 * // 子类型游标的初始化示例（如 KSStackCursor_MachineContext）
 * void kssc_initWithMachineContext(
 *     KSStackCursor* cursor,
 *     int maxStackDepth,
 *     const KSMachineContext* machineContext
 * ) {
 *     // 1. 调用基础初始化
 *     kssc_initCursor(
 *         cursor,
 *         resetCursor_MachineContext,  // 自定义重置函数
 *         advanceCursor_MachineContext // 自定义前进函数
 *     );
 *     
 *     // 2. 存储私有数据到 context[]
 *     cursor->context[0] = (void*)machineContext;
 *     cursor->context[1] = (void*)(uintptr_t)maxStackDepth;
 *     
 *     // 3. 初始化第一帧（PC 寄存器）
 *     cursor->stackEntry.address = kscpu_instructionAddress(machineContext);
 * }
 * ```
 * 
 * 注意事项：
 * - 此函数主要供内部使用
 * - 应用层应使用具体的初始化函数：
 *   - kssc_initWithMachineContext(): 从机器上下文创建游标
 *   - kssc_initWithBacktrace(): 从 backtrace 数组创建游标
 *   - kssc_initSelfThread(): 创建当前线程游标
 * - 初始化后，游标处于重置状态（currentDepth = 0）
 * - 需要调用 advanceCursor 前进到第一帧
 * 
 * 设计模式：
 * - 模板方法模式：定义初始化骨架，子类提供具体实现
 * - 策略模式：通过函数指针实现不同的遍历策略
 */
void kssc_initCursor(KSStackCursor *cursor, void (*resetCursor)(KSStackCursor *), bool (*advanceCursor)(KSStackCursor *)) {
    // 设置符号化函数（统一实现）
    cursor->symbolicate = kssymbolicator_symbolicate;
    
    // 设置前进函数（自定义或默认）
    // 如果为 NULL，使用 g_advanceCursor（会警告）
    cursor->advanceCursor = advanceCursor != NULL ? advanceCursor : g_advanceCursor;
    
    // 设置重置函数（自定义或默认）
    // 如果为 NULL，使用 kssc_resetCursor
    cursor->resetCursor = resetCursor != NULL ? resetCursor : kssc_resetCursor;
    
    // 立即调用重置函数，清空初始状态
    cursor->resetCursor(cursor);
}
