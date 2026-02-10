//
//  KSStackCursor.h
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
 * KSStackCursor.h - 堆栈游标（Stack Cursor）
 * ============================================================================
 * 
 * 核心概念：
 * - 堆栈游标是一个迭代器，用于遍历线程的调用栈
 * - 类似于数据库游标，可以逐帧前进、重置、读取当前信息
 * - 支持不同的实现方式（Mach 上下文、Backtrace、C++ 异常等）
 * 
 * 设计思路：
 * 1. 统一接口：不同的堆栈采集方式使用统一的游标接口
 * 2. 懒加载符号化：只在需要时才进行符号化（性能优化）
 * 3. 状态机模式：维护当前深度和停止状态
 * 4. 函数指针：支持多态（不同类型的游标有不同的实现）
 * 
 * 使用流程：
 * ```c
 * KSStackCursor cursor;
 * kssc_initWithMachineContext(&cursor, maxEntries, machineContext);
 * 
 * while (cursor.advanceCursor(&cursor)) {
 *     // 读取当前帧信息
 *     printf("Address: 0x%lx\n", cursor.stackEntry.address);
 *     
 *     // 可选：符号化
 *     if (cursor.symbolicate(&cursor)) {
 *         printf("Symbol: %s\n", cursor.stackEntry.symbolName);
 *     }
 * }
 * ```
 * 
 * 游标类型（实现）：
 * - KSStackCursor_MachineContext: 从机器上下文（寄存器）回溯
 * - KSStackCursor_Backtrace: 从 backtrace() 结果创建
 * - KSStackCursor_SelfThread: 当前线程自身堆栈
 * ============================================================================
 */

#ifndef KSStackCursor_h
#define KSStackCursor_h

#include "KSMachineContext.h"

#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 游标上下文缓冲区大小
 * 
 * 说明：
 * - 用于存储不同类型游标的私有数据
 * - 100 个指针大小的空间（800 字节在 64 位系统）
 * - 足够存储机器上下文、帧指针、栈指针等信息
 */
#define KSSC_CONTEXT_SIZE 100

/**
 * 堆栈溢出阈值
 * 
 * 说明：
 * - 当堆栈深度达到 150 层时，认为可能发生栈溢出
 * - 正常的调用栈深度很少超过 50 层
 * - 如果达到此阈值，游标会放弃遍历（设置 hasGivenUp = true）
 * 
 * 栈溢出的常见原因：
 * - 无限递归
 * - 递归深度过大
 * - 栈损坏导致 FP 链断裂
 */
#define KSSC_STACK_OVERFLOW_THRESHOLD 150

/**
 * 堆栈游标结构体
 * 
 * 这是堆栈回溯的核心数据结构！
 * 包含当前堆栈帧的所有信息和控制方法。
 */
typedef struct KSStackCursor {
    // ========================================================================
    // 当前堆栈帧信息（stackEntry）
    // ========================================================================
    struct {
        /**
         * 当前堆栈帧的指令地址（虚拟内存地址）
         * 
         * 说明：
         * - 这是函数调用后的返回地址（Return Address）
         * - 对于第一帧，是 PC 寄存器的值（当前执行地址）
         * - 通过这个地址可以进行符号化，找到对应的函数名
         * 
         * 示例：
         * - 0x0000000102a3c4d8 (真机地址)
         * - 0x000000010f8b1234 (模拟器地址)
         */
        uintptr_t address;

        /**
         * 当前地址所在的二进制镜像名称
         * 
         * 说明：
         * - 二进制镜像 = 动态库、可执行文件、Framework
         * - 通过 dladdr() 查询得到
         * - 可能为 NULL（无法确定所属镜像）
         * 
         * 示例：
         * - "MyApp" (主程序)
         * - "UIKitCore" (系统库)
         * - "libswiftCore.dylib" (Swift 运行时)
         * - "Matrix" (自定义 Framework)
         */
        const char *imageName;

        /**
         * 当前地址所在二进制镜像的加载起始地址（ASLR 后的地址）
         * 
         * 说明：
         * - ASLR (Address Space Layout Randomization): 地址空间随机化
         * - 每次启动，镜像加载到不同的基地址
         * - 计算偏移地址 = address - imageAddress
         * - 符号化时需要用偏移地址
         * 
         * 示例：
         * - 0x0000000102a00000 (某次启动的地址)
         * - 0x0000000104b00000 (另一次启动的地址)
         * 
         * 用途：
         * - 离线符号化：atos -o MyApp.dSYM -arch arm64 -l 0x102a00000 0x102a3c4d8
         */
        uintptr_t imageAddress;

        /**
         * 最接近当前地址的符号名称（函数名）
         * 
         * 说明：
         * - 通过 dladdr() 或 dSYM 查询得到
         * - 可能为 NULL（无符号信息，如 stripped binary）
         * - C 函数：直接函数名
         * - ObjC 方法：-[ClassName methodName:] 或 +[ClassName classMethod]
         * - Swift 函数：mangled name (如 $s4MyApp10ViewControllerC11viewDidLoadyyF)
         * - Block：__BlockClassName_block_invoke
         * 
         * 示例：
         * - "main"
         * - "-[ViewController viewDidLoad]"
         * - "__27-[MyClass asyncOperation]_block_invoke"
         * - "specialized Array.init(repeating:count:)"
         */
        const char *symbolName;

        /**
         * 最接近符号的起始地址
         * 
         * 说明：
         * - 函数的入口地址（第一条指令）
         * - address - symbolAddress = 函数内的偏移量
         * - 可用于判断崩溃/卡顿发生在函数的哪个位置
         * 
         * 示例：
         * - address = 0x102a3c4d8
         * - symbolAddress = 0x102a3c4b0
         * - 偏移 = 0x28 (40 字节，大约 10 条 ARM64 指令)
         */
        uintptr_t symbolAddress;
    } stackEntry;
    
    // ========================================================================
    // 游标状态信息（state）
    // ========================================================================
    struct {
        /**
         * 当前堆栈深度（从 1 开始）
         * 
         * 说明：
         * - 1: 第一帧（最内层函数，崩溃/卡顿发生的地方）
         * - 2: 第二帧（调用者）
         * - ...
         * - N: 第 N 帧（通常最后一帧是 main 或线程入口）
         * 
         * 示例调用栈：
         * 0: 0x102a3c4d8  MyApp  -[ViewController heavyTask]  (depth=1)
         * 1: 0x102a3c890  MyApp  -[ViewController viewDidLoad]  (depth=2)
         * 2: 0x1a8b2c3f0  UIKitCore  -[UIViewController loadViewIfRequired]  (depth=3)
         */
        int currentDepth;

        /**
         * 游标是否已放弃遍历
         * 
         * 设置为 true 的情况：
         * 1. 达到最大深度限制（如 KSSC_STACK_OVERFLOW_THRESHOLD = 150）
         * 2. 遇到无效的帧指针（FP 损坏）
         * 3. FP 指向非法内存地址
         * 4. 栈帧链断裂
         * 
         * 用途：
         * - 检测栈溢出：isStackOverflow = hasGivenUp && (currentDepth >= THRESHOLD)
         * - 避免无限循环
         */
        bool hasGivenUp;
    } state;

    // ========================================================================
    // 函数指针（多态方法）
    // ========================================================================
    
    /**
     * 重置游标到初始状态
     * 
     * 作用：
     * - 将 currentDepth 重置为 0
     * - 将 hasGivenUp 重置为 false
     * - 清空 stackEntry 的所有字段
     * 
     * 使用场景：
     * - 需要重新遍历同一个堆栈
     * - 多次分析同一个崩溃现场
     */
    void (*resetCursor)(struct KSStackCursor *);

    /**
     * 前进到下一个堆栈帧
     * 
     * 返回值：
     * - true: 成功前进到下一帧
     * - false: 已到达栈底 或 发生错误
     * 
     * 实现原理（以 ARM64 为例）：
     * 1. 读取当前 FP (Frame Pointer, x29) 指向的内存
     * 2. FP[0] = 上一帧的 FP（链表指针）
     * 3. FP[1] = 上一帧的 LR（返回地址）
     * 4. 更新 stackEntry.address = FP[1]
     * 5. 更新 FP = FP[0]（链表遍历）
     * 6. currentDepth++
     * 
     * 堆栈帧布局（ARM64）：
     * ```
     * High Address
     *   +------------------+
     *   | Return Address   | <-- FP[1] (LR)
     *   +------------------+
     *   | Previous FP      | <-- FP[0] (链表)
     *   +------------------+ <-- Current FP (x29)
     *   | Local Variables  |
     *   +------------------+
     * Low Address
     * ```
     * 
     * 停止条件：
     * - FP == 0 或 FP == NULL（到达栈底）
     * - FP 指向非法内存
     * - 达到最大深度限制
     */
    bool (*advanceCursor)(struct KSStackCursor *);

    /**
     * 符号化当前地址
     * 
     * 作用：
     * - 填充 stackEntry 的符号信息字段：
     *   - imageName
     *   - imageAddress
     *   - symbolName
     *   - symbolAddress
     * 
     * 返回值：
     * - true: 符号化成功（至少找到 imageName）
     * - false: 符号化失败（无法确定所属镜像）
     * 
     * 实现方式：
     * 1. 运行时符号化：dladdr(address, &info)
     *    - 优点：实时、无需 dSYM
     *    - 缺点：仅获取导出符号，Stripped binary 无法符号化
     * 
     * 2. 离线符号化：atos + dSYM
     *    - 优点：完整符号信息，包括文件名行号
     *    - 缺点：需要匹配 UUID 的 dSYM 文件
     * 
     * 性能考虑：
     * - dladdr() 每次调用 ~2-5μs
     * - 建议：仅在需要时调用（如生成崩溃报告）
     * - Matrix 卡顿检测：采集时不符号化，上报时才符号化
     */
    bool (*symbolicate)(struct KSStackCursor *);

    // ========================================================================
    // 内部上下文（context）
    // ========================================================================
    
    /**
     * 游标的私有数据存储区
     * 
     * 说明：
     * - 不同类型的游标存储不同的数据
     * - 大小：KSSC_CONTEXT_SIZE = 100 个指针（800 字节）
     * 
     * 不同游标类型存储的数据：
     * 
     * 1. KSStackCursor_MachineContext:
     *    - KSMachineContext*: 机器上下文指针
     *    - uintptr_t: 当前 FP
     *    - uintptr_t: 当前 PC
     *    - int: 最大深度限制
     * 
     * 2. KSStackCursor_Backtrace:
     *    - uintptr_t[]: backtrace 地址数组
     *    - int: 数组长度
     *    - int: 当前索引
     * 
     * 3. KSStackCursor_SelfThread:
     *    - thread_t: 线程 ID
     *    - KSMachineContext: 机器上下文副本
     * 
     * 使用示例：
     * ```c
     * // 初始化时存储数据
     * cursor->context[0] = machineContext;
     * cursor->context[1] = (void*)(uintptr_t)maxDepth;
     * 
     * // 使用时读取数据
     * KSMachineContext* ctx = (KSMachineContext*)cursor->context[0];
     * int maxDepth = (int)(uintptr_t)cursor->context[1];
     * ```
     */
    void *context[KSSC_CONTEXT_SIZE];
} KSStackCursor;

/**
 * 通用堆栈游标初始化函数
 * 
 * 说明：
 * - 这是所有游标类型的基础初始化函数
 * - 子类型游标（如 MachineContext、Backtrace）会调用此函数完成基础初始化
 * - 然后在 context[] 中存储自己的私有数据
 * 
 * @param cursor 要初始化的游标
 * @param resetCursor 重置函数指针（NULL = 使用默认的 kssc_resetCursor）
 * @param advanceCursor 前进函数指针（NULL = 使用默认，总是返回 false 并警告）
 * 
 * 初始化流程：
 * 1. 设置 symbolicate 函数指针（使用 kssymbolicator_symbolicate）
 * 2. 设置 advanceCursor 函数指针（自定义或默认）
 * 3. 设置 resetCursor 函数指针（自定义或默认）
 * 4. 调用 resetCursor 清空状态
 * 
 * 使用示例：
 * ```c
 * void myResetCursor(KSStackCursor* cursor) {
 *     kssc_resetCursor(cursor);  // 调用基础重置
 *     // 重置私有数据...
 * }
 * 
 * bool myAdvanceCursor(KSStackCursor* cursor) {
 *     // 读取私有数据
 *     MyContext* ctx = (MyContext*)cursor->context[0];
 *     // 前进逻辑...
 *     return true;
 * }
 * 
 * KSStackCursor cursor;
 * kssc_initCursor(&cursor, myResetCursor, myAdvanceCursor);
 * ```
 * 
 * 注意：
 * - 此函数主要供内部使用
 * - 应用层应使用具体的初始化函数：
 *   - kssc_initWithMachineContext()
 *   - kssc_initWithBacktrace()
 *   - kssc_initSelfThread()
 */
void kssc_initCursor(KSStackCursor *cursor, void (*resetCursor)(KSStackCursor *), bool (*advanceCursor)(KSStackCursor *));

/**
 * 重置游标到初始状态
 * 
 * 作用：
 * - 清空 stackEntry 的所有字段（address、imageName 等）
 * - 将 currentDepth 重置为 0
 * - 将 hasGivenUp 重置为 false
 * 
 * 警告：
 * - 这是内部方法！
 * - 应用层应调用 cursor->resetCursor(cursor)，而不是直接调用此函数
 * - 子类型游标可能有自定义的 resetCursor 实现
 * 
 * @param cursor 要重置的游标
 * 
 * 使用场景：
 * - 重新遍历同一个堆栈
 * - 作为自定义 resetCursor 的基础实现
 */
void kssc_resetCursor(KSStackCursor *cursor);

#ifdef __cplusplus
}
#endif

#endif // KSStackCursor_h
