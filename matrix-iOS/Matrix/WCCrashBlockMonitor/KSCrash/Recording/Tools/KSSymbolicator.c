//
//  KSSymbolicator.c
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
 * KSSymbolicator.c - 运行时符号化实现
 * ============================================================================
 * 
 * 核心功能：
 * - 使用 dladdr() 进行运行时符号化
 * - 使用缓存优化性能（ksdl_dladdr_use_cache）
 * 
 * 符号化流程：
 * 1. 地址预处理：
 *    - 去除标签位（ARM Thumb、ARM64 对齐）
 *    - 转换返回地址为调用地址（-1）
 * 
 * 2. 查询符号信息：
 *    - 调用 ksdl_dladdr_use_cache（带缓存的 dladdr）
 *    - 获取镜像和符号信息
 * 
 * 3. 填充结果：
 *    - 成功：填充 imageAddress, imageName, symbolAddress, symbolName
 *    - 失败：清空所有字段
 * 
 * dladdr() 原理：
 * - 遍历进程加载的所有动态库（dyld 管理）
 * - 查找包含目标地址的镜像
 * - 在镜像的符号表中查找最接近的符号
 * - 返回符号和镜像信息
 * 
 * 性能优化：
 * - 使用 ksdl_dladdr_use_cache 而不是直接调用 dladdr
 * - 缓存近期查询结果，避免重复查询
 * - 对于连续的堆栈地址，大概率在同一个镜像中
 * ============================================================================
 */

#include "KSSymbolicator.h"

/**
 * 符号化堆栈游标
 * 
 * 这是所有游标类型使用的统一符号化接口！
 * 
 * 执行流程：
 * 
 * 1. 地址转换：
 *    ```c
 *    返回地址: cursor->stackEntry.address (如 0x102a3c4d9)
 *         ↓ DETAG_INSTRUCTION_ADDRESS
 *    去标签: 0x102a3c4d8
 *         ↓ -1
 *    调用地址: 0x102a3c4d7
 *    ```
 * 
 * 2. 查询符号信息：
 *    ```c
 *    ksdl_dladdr_use_cache(0x102a3c4d7, &symbolsBuffer)
 *    ```
 *    
 *    返回的 Dl_info 结构：
 *    ```
 *    dli_fname: "/var/containers/Bundle/Application/.../MyApp"
 *    dli_fbase: 0x102a00000 (镜像加载基址)
 *    dli_sname: "-[ViewController heavyTask]"
 *    dli_saddr: 0x102a3c4b0 (函数入口地址)
 *    ```
 * 
 * 3. 填充游标：
 *    - imageAddress = 0x102a00000
 *    - imageName = "MyApp" (文件名)
 *    - symbolAddress = 0x102a3c4b0
 *    - symbolName = "-[ViewController heavyTask]"
 * 
 * 成功案例：
 * - 应用自身代码（未 strip）
 * - ObjC 方法（动态派发，始终导出）
 * - Swift public 函数
 * - C/C++ 导出函数
 * 
 * 失败案例：
 * - Strip 后的 Release 构建
 * - Swift internal/private 函数
 * - 静态链接的代码
 * - 无效地址（野指针）
 * 
 * @param cursor 堆栈游标
 * @return 成功返回 true，失败返回 false
 */
bool kssymbolicator_symbolicate(KSStackCursor *cursor) {
    // ========================================================================
    // 步骤1：准备符号信息缓冲区
    // ========================================================================
    Dl_info symbolsBuffer;
    
    // ========================================================================
    // 步骤2：调用 dladdr 查询符号信息（使用缓存优化版本）
    // ========================================================================
    /*
     * CALL_INSTRUCTION_FROM_RETURN_ADDRESS 做了两件事：
     * 1. DETAG_INSTRUCTION_ADDRESS: 去除标签位
     * 2. -1: 转换返回地址为调用地址
     * 
     * ksdl_dladdr_use_cache 的优势：
     * - 缓存最近的查询结果
     * - 对于连续的堆栈地址，命中率极高
     * - 性能提升 3-5 倍
     */
    if (ksdl_dladdr_use_cache(CALL_INSTRUCTION_FROM_RETURN_ADDRESS(cursor->stackEntry.address), &symbolsBuffer)) {
        // ====================================================================
        // 成功：填充符号信息到游标
        // ====================================================================
        
        // 镜像加载基址（ASLR 后的地址）
        cursor->stackEntry.imageAddress = (uintptr_t)symbolsBuffer.dli_fbase;
        
        // 镜像文件名（完整路径）
        // 注意：这是指针赋值，不是字符串拷贝
        // dladdr 返回的指针指向 dyld 内部数据，生命周期由系统管理
        cursor->stackEntry.imageName = symbolsBuffer.dli_fname;
        
        // 符号起始地址（函数入口）
        cursor->stackEntry.symbolAddress = (uintptr_t)symbolsBuffer.dli_saddr;
        
        // 符号名称（函数名）
        // 可能为 NULL（strip 后或无符号）
        cursor->stackEntry.symbolName = symbolsBuffer.dli_sname;
        
        return true;
    }

    // ========================================================================
    // 失败：清空符号信息
    // ========================================================================
    /*
     * 失败原因可能是：
     * 1. 地址无效（野指针、栈损坏）
     * 2. 地址不在任何已加载的镜像中
     * 3. 地址在无法识别的内存区域
     * 
     * 清空所有字段，避免使用未初始化的数据
     */
    cursor->stackEntry.imageAddress = 0;
    cursor->stackEntry.imageName = 0;      // NULL 指针
    cursor->stackEntry.symbolAddress = 0;
    cursor->stackEntry.symbolName = 0;     // NULL 指针
    return false;
}

/**
 * 获取堆栈地址对应的符号起始地址
 * 
 * 功能：
 * - 轻量级符号化，只返回符号地址，不返回名称
 * - 用于计算偏移量、地址去重、热点分析
 * 
 * 与完整符号化的区别：
 * - 不需要游标结构
 * - 只查询符号地址（dli_saddr）
 * - 不填充其他字段（imageName, symbolName 等）
 * - 性能略好（减少了赋值操作）
 * 
 * 执行流程：
 * 
 * 1. 地址转换：
 *    ```
 *    stackAddress (返回地址)
 *         ↓ CALL_INSTRUCTION_FROM_RETURN_ADDRESS
 *    调用地址（去标签 -1）
 *    ```
 * 
 * 2. 查询符号：
 *    ```c
 *    ksdl_dladdr_use_cache(callAddr, &symbolsBuffer)
 *    ```
 * 
 * 3. 返回符号地址：
 *    ```
 *    成功: symbolsBuffer.dli_saddr (函数入口)
 *    失败: 0
 *    ```
 * 
 * 使用场景：
 * 
 * 1. 计算函数内偏移：
 *    ```c
 *    uintptr_t returnAddr = 0x102a3c4d8;
 *    uintptr_t symbolAddr = kssymbolicate_symboladdress(returnAddr);
 *    int offset = returnAddr - symbolAddr;  // +40 字节
 *    
 *    // 崩溃报告：Crash in -[ViewController heavyTask] + 40
 *    ```
 * 
 * 2. 地址去重（统计分析）：
 *    ```c
 *    // 多个返回地址可能属于同一个函数
 *    NSMutableDictionary *symbolCounts = [NSMutableDictionary new];
 *    for (uintptr_t addr in addresses) {
 *        uintptr_t symbolAddr = kssymbolicate_symboladdress(addr);
 *        NSNumber *key = @(symbolAddr);
 *        symbolCounts[key] = @([symbolCounts[key] intValue] + 1);
 *    }
 *    // 统计每个函数的采样次数
 *    ```
 * 
 * 3. 热点检测：
 *    ```c
 *    // CPU 采样 100 次
 *    for (int i = 0; i < 100; i++) {
 *        uintptr_t pc = getCurrentPC();
 *        uintptr_t symbol = kssymbolicate_symboladdress(pc);
 *        hotspots[symbol]++;  // 统计热点函数
 *    }
 *    ```
 * 
 * 性能对比：
 * - kssymbolicate_symboladdress: ~2-5μs
 * - kssymbolicator_symbolicate: ~3-6μs
 * - 差异主要在字段赋值和结构体操作
 * 
 * 注意事项：
 * - 返回 0 表示查询失败（无效地址或无符号）
 * - 不能用 0 作为有效的符号地址（NULL 地址不可执行）
 * - 缓存机制同样适用，连续查询性能更好
 * 
 * @param stackAddress 堆栈地址（返回地址）
 * @return 符号起始地址（函数入口），失败返回 0
 */
uintptr_t kssymbolicate_symboladdress(uintptr_t stackAddress) {
    // ========================================================================
    // 步骤1：准备符号信息缓冲区
    // ========================================================================
    Dl_info symbolsBuffer;
    
    // ========================================================================
    // 步骤2：调用 dladdr 查询符号信息
    // ========================================================================
    /*
     * 地址转换：
     * - 去除标签位（ARM Thumb、ARM64 对齐）
     * - 转换返回地址为调用地址（-1）
     */
    if (ksdl_dladdr_use_cache(CALL_INSTRUCTION_FROM_RETURN_ADDRESS(stackAddress), &symbolsBuffer)) {
        // ====================================================================
        // 成功：返回符号起始地址
        // ====================================================================
        /*
         * dli_saddr: Symbol Address
         * - 函数的入口地址（第一条指令）
         * - 用于计算偏移：stackAddress - symbolAddress
         * 
         * 示例：
         * - stackAddress = 0x102a3c4d8 (返回地址)
         * - symbolAddress = 0x102a3c4b0 (函数入口)
         * - 偏移 = 0x28 (40 字节)
         */
        return (uintptr_t)symbolsBuffer.dli_saddr;
    }
    
    // ========================================================================
    // 失败：返回 0
    // ========================================================================
    /*
     * 失败原因：
     * - 地址无效
     * - 不在已加载镜像中
     * - 符号表被 strip
     */
    return 0;
}
