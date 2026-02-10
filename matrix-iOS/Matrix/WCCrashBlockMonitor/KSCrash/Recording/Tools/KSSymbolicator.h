//
//  KSSymbolicator.h
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
 * KSSymbolicator.h - 运行时符号化工具
 * ============================================================================
 * 
 * 核心功能：
 * - 将虚拟内存地址转换为可读的符号信息（函数名、镜像名等）
 * - 处理不同 CPU 架构的指令地址标签问题
 * - 处理返回地址与调用地址的差异
 * 
 * 符号化原理：
 * 1. 运行时符号化：使用 dladdr() 查询动态链接器信息
 *    - 优点：实时、无需额外文件
 *    - 缺点：只能获取导出符号（exported symbols）
 *    - Stripped binary 无法符号化
 * 
 * 2. 离线符号化：使用 atos + dSYM 文件
 *    - 优点：完整符号信息，包含文件名和行号
 *    - 缺点：需要匹配 UUID 的 dSYM 文件
 *    - 需要在服务端或开发机执行
 * 
 * 关键概念：
 * 
 * 1. 返回地址 vs 调用地址：
 *    - 堆栈中保存的是返回地址（函数调用后的下一条指令）
 *    - 符号化需要调用地址（函数调用指令本身）
 *    - 通常返回地址 - 1 = 调用地址
 * 
 * 2. 指令地址标签（ARM 架构）：
 *    - ARMv7 (32位): 最低位表示 Thumb 模式（1）或 ARM 模式（0）
 *    - ARM64: 指令 4 字节对齐，最低 2 位应为 0
 *    - x86_64: 可变长度指令，所有位都有效
 * 
 * 3. ASLR（地址空间随机化）：
 *    - 每次启动，镜像加载到不同的基地址
 *    - 符号化公式：offset = address - imageAddress
 *    - 离线符号化需要知道 imageAddress
 * 
 * 使用场景：
 * - 崩溃报告生成
 * - 卡顿堆栈分析
 * - CPU 耗电堆栈分析
 * - 任何需要将地址转换为可读信息的场景
 * ============================================================================
 */

#ifndef KSSymbolicator_h
#define KSSymbolicator_h

/**
 * 去除指令地址的标签位（De-tagging）
 * 
 * 背景：
 * - 不同 CPU 架构对指令地址有不同的编码规则
 * - 某些架构使用地址的低位作为模式标志或对齐标记
 * - 符号化前需要去除这些标签，获取真实的指令地址
 * 
 * 架构说明：
 * 
 * 1. ARMv7 (32位 ARM)：
 *    - 最低位（bit 0）区分指令模式：
 *      - 0: ARM 模式（4 字节指令）
 *      - 1: Thumb 模式（2 字节指令，节省空间）
 *    - 操作：A & ~(1UL) 即清除最低位
 *    - 示例：0x102a3c4d9 -> 0x102a3c4d8
 * 
 * 2. ARM64 (64位 ARM)：
 *    - 所有指令都是 4 字节对齐（32位宽度）
 *    - 最低 2 位（bit 0-1）应该始终为 0
 *    - 如果不为 0，说明有标签或指针认证（PAC, Pointer Authentication Code）
 *    - 操作：A & ~(3UL) 即清除最低 2 位
 *    - 示例：0x102a3c4db -> 0x102a3c4d8
 * 
 * 3. x86_64 / i386 (Intel)：
 *    - 指令是可变长度（1-15 字节）
 *    - 地址所有位都有效，不存在标签位
 *    - 操作：不做任何处理
 * 
 * 为什么需要去标签？
 * - dladdr() 等符号查询函数需要真实的指令地址
 * - 带标签的地址可能无法正确匹配符号表
 * - 偏移量计算会出错
 * 
 * 示例：
 * ```c
 * uintptr_t addr = 0x102a3c4d9;  // Thumb 模式地址（最低位=1）
 * uintptr_t clean = DETAG_INSTRUCTION_ADDRESS(addr);  // 0x102a3c4d8
 * 
 * Dl_info info;
 * dladdr((void*)clean, &info);  // 使用干净的地址查询
 * ```
 */
#if defined(__arm__)
#define DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(1UL))
#elif defined(__arm64__)
#define DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(3UL))
#else
#define DETAG_INSTRUCTION_ADDRESS(A) (A)
#endif

/**
 * 从返回地址推导调用指令地址
 * 
 * 核心问题：
 * - 堆栈回溯时获取的是**返回地址**（Return Address）
 * - 返回地址 = 函数调用指令的**下一条指令**
 * - 符号化时需要**调用指令地址**（Call Instruction Address）
 * - 大多数情况：调用地址 = 返回地址 - 1
 * 
 * 为什么需要这个转换？
 * 
 * 问题场景：
 * ```
 * 函数 A:
 *   0x102a3c4d0: mov x0, #1
 *   0x102a3c4d4: bl functionB     <- 调用指令
 *   0x102a3c4d8: add x1, x2, x3   <- 返回地址（下一条指令）
 * 
 * 函数 B:
 *   0x102a3c500: ...
 * ```
 * 
 * 堆栈中保存的是 0x102a3c4d8（返回地址）
 * 但符号化应该查询 0x102a3c4d4（调用指令）
 * 
 * 为什么返回地址和调用地址可能属于不同符号？
 * 
 * 1. 尾调用优化（Tail Call Optimization）：
 *    ```
 *    funcA: 0x100 - 0x1ff
 *    funcB: 0x200 - 0x2ff
 *    
 *    funcA 的最后一条指令（0x1fc）调用 funcB
 *    返回地址是 0x200（恰好是 funcB 的起始地址！）
 *    如果用返回地址符号化，会显示在 funcB 中
 *    但实际调用发生在 funcA 中
 *    ```
 * 
 * 2. 内联汇编边界：
 *    - 调用指令可能在内联汇编块的末尾
 *    - 返回地址在下一个代码块（可能是另一个函数）
 * 
 * 3. 跨模块边界：
 *    - 调用指令在 libA 的末尾
 *    - 返回地址在 libB 的开头
 * 
 * 操作步骤：
 * 1. 先去除标签位（DETAG_INSTRUCTION_ADDRESS）
 * 2. 再减 1（退回到调用指令）
 * 
 * 示例：
 * ```c
 * // 堆栈中获取的返回地址
 * uintptr_t returnAddr = 0x102a3c4d9;  // 带 Thumb 标签
 * 
 * // 推导调用地址
 * uintptr_t callAddr = CALL_INSTRUCTION_FROM_RETURN_ADDRESS(returnAddr);
 * // = DETAG_INSTRUCTION_ADDRESS(0x102a3c4d9) - 1
 * // = 0x102a3c4d8 - 1
 * // = 0x102a3c4d7
 * 
 * // 用调用地址查询符号
 * Dl_info info;
 * dladdr((void*)callAddr, &info);
 * ```
 * 
 * 特殊情况：
 * - 对于第一帧（PC 寄存器），不需要此转换
 * - PC 本身就是当前执行的指令地址，不是返回地址
 * - 只有 LR（Link Register）和堆栈上的地址才是返回地址
 * 
 * 性能考虑：
 * - 这是一个宏，编译时展开，零运行时开销
 * - 位运算和减法都是单周期指令
 */
#define CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A) (DETAG_INSTRUCTION_ADDRESS((A)) - 1)

#include "KSStackCursor.h"
#include <stdbool.h>
#include "KSDynamicLinker.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 符号化堆栈游标的当前地址
 * 
 * 功能：
 * - 将游标当前帧的虚拟内存地址转换为符号信息
 * - 填充游标的 stackEntry 结构体
 * 
 * 符号化流程：
 * 1. 获取返回地址：cursor->stackEntry.address
 * 2. 转换为调用地址：CALL_INSTRUCTION_FROM_RETURN_ADDRESS
 * 3. 调用 dladdr()：查询动态链接器信息
 * 4. 填充符号信息：
 *    - imageAddress: 镜像加载基址
 *    - imageName: 镜像文件名
 *    - symbolAddress: 符号起始地址
 *    - symbolName: 符号名称（函数名）
 * 
 * dladdr() 返回的信息（Dl_info 结构）：
 * ```c
 * typedef struct {
 *     const char *dli_fname;   // 镜像文件路径
 *     void       *dli_fbase;   // 镜像加载基址（ASLR 后）
 *     const char *dli_sname;   // 最接近的符号名称
 *     void       *dli_saddr;   // 符号起始地址
 * } Dl_info;
 * ```
 * 
 * 符号名称格式示例：
 * - C 函数：`main`, `printf`
 * - ObjC 方法：`-[ViewController viewDidLoad]`, `+[NSString stringWithFormat:]`
 * - Swift 函数：`$s4MyApp10ViewControllerC11viewDidLoadyyF` (mangled)
 * - Block：`__27-[MyClass asyncOperation]_block_invoke`
 * - C++：mangled name (需要 demangle)
 * 
 * 限制：
 * 1. 只能符号化导出符号（exported symbols）
 *    - Public API、ObjC 方法、Swift public 函数
 *    - 不包括 private/internal 函数（除非保留调试符号）
 * 
 * 2. Stripped binary 无法符号化
 *    - Release 构建通常会 strip 符号表
 *    - 此时只能获取镜像信息，无法获取函数名
 * 
 * 3. 系统库符号可能缺失
 *    - iOS 系统库已 strip，无法符号化
 *    - 只能显示镜像名（如 UIKitCore）
 * 
 * 性能：
 * - dladdr() 调用开销：约 2-5μs
 * - 使用缓存版本 ksdl_dladdr_use_cache 优化
 * - 建议：仅在需要时符号化（如生成报告）
 * 
 * @param cursor 要符号化的堆栈游标
 *               - 输入：cursor->stackEntry.address（返回地址）
 *               - 输出：填充 imageAddress, imageName, symbolAddress, symbolName
 * 
 * @return 成功返回 true，失败返回 false
 *         - true: 至少找到了镜像信息
 *         - false: 地址无效，无法确定所属镜像
 * 
 * 使用示例：
 * ```c
 * KSStackCursor cursor;
 * kssc_initWithMachineContext(&cursor, maxEntries, machineContext);
 * 
 * while (cursor.advanceCursor(&cursor)) {
 *     // 符号化当前帧
 *     if (cursor.symbolicate(&cursor)) {
 *         printf("0x%lx: %s (%s)\n",
 *                cursor.stackEntry.address,
 *                cursor.stackEntry.symbolName ?: "???",
 *                cursor.stackEntry.imageName ?: "???"
 *         );
 *     }
 * }
 * ```
 * 
 * 与 atos 离线符号化对比：
 * 
 * | 特性 | 运行时（dladdr） | 离线（atos） |
 * |------|-----------------|-------------|
 * | 时机 | 实时 | 事后 |
 * | 符号 | 仅导出符号 | 完整符号 |
 * | 文件名/行号 | ❌ | ✅ |
 * | 需要 dSYM | ❌ | ✅ |
 * | Strip 影响 | ✅ 受影响 | ❌ 不受影响 |
 * | 性能 | 2-5μs/次 | N/A（离线） |
 */
bool kssymbolicator_symbolicate(KSStackCursor *cursor);

/**
 * 获取指定堆栈地址的符号起始地址
 * 
 * 功能：
 * - 查询给定地址对应的符号起始地址（函数入口地址）
 * - 不返回符号名称，只返回地址
 * - 轻量级版本，性能比完整符号化略好
 * 
 * 用途：
 * 1. 计算偏移量：stackAddress - symbolAddress = 函数内偏移
 * 2. 地址去重：多个返回地址可能属于同一个符号
 * 3. 热点分析：统计哪些函数被频繁采样
 * 
 * @param stackAddress 堆栈地址（返回地址）
 *                     - 会自动转换为调用地址
 *                     - 会自动去除标签位
 * 
 * @return 符号起始地址（函数入口）
 *         - 成功：返回符号地址（dli_saddr）
 *         - 失败：返回 0（无法确定所属符号）
 * 
 * 示例：
 * ```c
 * uintptr_t returnAddr = 0x102a3c4d8;
 * uintptr_t symbolAddr = kssymbolicate_symboladdress(returnAddr);
 * // symbolAddr = 0x102a3c4b0 (函数入口)
 * 
 * int offset = returnAddr - symbolAddr;
 * // offset = 0x28 (40 字节，约 10 条 ARM64 指令)
 * 
 * printf("Crash at offset +%d in function\n", offset);
 * // 输出: Crash at offset +40 in function
 * ```
 * 
 * 性能优化建议：
 * - 如果只需要符号地址，使用此函数而不是完整符号化
 * - 批量查询时，使用缓存机制避免重复查询
 * - 对于热点路径，考虑预先查询并缓存结果
 */
uintptr_t kssymbolicate_symboladdress(uintptr_t stackAddress);

#ifdef __cplusplus
}
#endif

#endif // KSSymbolicator_h
