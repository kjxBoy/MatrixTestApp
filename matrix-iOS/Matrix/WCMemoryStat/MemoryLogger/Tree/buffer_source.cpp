/*
 * Tencent is pleased to support the open source community by making wechat-matrix available.
 * Copyright (C) 2022 THL A29 Limited, a Tencent company. All rights reserved.
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

/**
 * buffer_source.cpp - 共享内存池实现
 * 
 * ============================================================================
 * 功能概述
 * ============================================================================
 * 
 * 实现了高性能的共享内存池，用于堆栈缓存的快速分配：
 * 
 * 1. 块分配（Block Allocation）
 *    - 每次从 memory_pool_file 分配 1MB 的大块
 *    - 在块内使用 bump allocator 快速分配小对象
 * 
 * 2. Bump Allocator
 *    - 维护当前块的指针（s_alloc_ptr）和偏移量（s_alloc_index）
 *    - 分配只需要增加偏移量，极快（~0.1 微秒）
 *    - 不支持单独释放（只能整体释放）
 * 
 * 3. 16 字节对齐
 *    - 所有分配都对齐到 16 字节边界
 *    - 提高缓存性能
 * 
 * ============================================================================
 * 技术原理
 * ============================================================================
 * 
 * 内存布局：
 * ┌──────────────────────────────────────────────────────────┐
 * │ file_memory.dat                                          │
 * ├──────────────────────────────────────────────────────────┤
 * │ Block 0 (1MB)                                            │
 * │ ┌────────────────────────────────────────────────────┐   │
 * │ │ Alloc 1 (100 bytes) | Alloc 2 (200 bytes) | ...    │   │
 * │ └────────────────────────────────────────────────────┘   │
 * ├──────────────────────────────────────────────────────────┤
 * │ Block 1 (1MB)                                            │
 * │ ┌────────────────────────────────────────────────────┐   │
 * │ │ Alloc N (150 bytes) | Alloc N+1 (300 bytes) | ...  │   │
 * │ └────────────────────────────────────────────────────┘   │
 * └──────────────────────────────────────────────────────────┘
 * 
 * 分配流程：
 * ┌──────────────────────────────────────────┐
 * │ 1. 检查当前块是否有足够空间              │
 * │    - if (s_alloc_index + size >= 1MB)    │
 * │                                          │
 * │ 2. 如果不够，从 s_pool 分配新块          │
 * │    - s_alloc_ptr = s_pool->malloc(1MB)   │
 * │    - s_alloc_index = 0                   │
 * │                                          │
 * │ 3. 从当前块分配                          │
 * │    - ret = s_alloc_ptr + s_alloc_index   │
 * │    - s_alloc_index += size               │
 * │    - 对齐到 16 字节                       │
 * └──────────────────────────────────────────┘
 * 
 * ============================================================================
 * 性能特性
 * ============================================================================
 * 
 * 分配速度：
 * - 块内分配：~0.1 微秒（只需增加偏移量）
 * - 跨块分配：~50-100 微秒（需要 mmap）
 * 
 * 内存开销：
 * - 每个块 1MB
 * - 最后一个块可能有浪费（碎片）
 * - 对齐损失：最多 15 字节/次分配
 * 
 * 使用场景：
 * - 堆栈信息的临时缓存
 * - 大量小对象的快速分配
 * - 不需要单独释放的场景
 * 
 * ============================================================================
 */

#include "buffer_source.h"

#pragma mark -
#pragma mark Defines

/**
 * 每个块的大小：1MB
 * 
 * 说明：
 * - 每次从 s_pool 分配 1MB 的块
 * - 块内使用 bump allocator 快速分配
 * - 块用完后分配新块
 */
#define MALLOC_SIZE (1 << 20)

#pragma mark -
#pragma mark Constants/Globals

/**
 * 全局内存池
 * 
 * 说明：
 * - 管理 file_memory.dat 文件
 * - 通过 memory_pool_file 实现增量分配
 * - 所有块都映射到同一个文件
 */
static memory_pool_file *s_pool = NULL;

/**
 * 当前块的起始地址
 * 
 * 说明：
 * - 指向当前正在使用的 1MB 块
 * - 从 s_pool->malloc(1MB) 获取
 */
static void *s_alloc_ptr;

/**
 * 当前块的分配偏移量
 * 
 * 说明：
 * - 范围：[0, MALLOC_SIZE)
 * - 下次分配从 s_alloc_ptr + s_alloc_index 开始
 * - 分配后增加并对齐到 16 字节
 */
static size_t s_alloc_index;

#pragma mark -
#pragma mark Functions

/**
 * 初始化共享内存池
 * 
 * @param dir 目录路径
 * @return true 成功，false 失败
 * 
 * 初始化流程：
 * 1. 检查是否已初始化（s_pool != NULL）
 * 2. 删除旧的 file_memory.dat
 * 3. 创建新的 memory_pool_file
 * 4. 初始化全局变量：
 *    - s_alloc_ptr = NULL（等待首次分配）
 *    - s_alloc_index = MALLOC_SIZE（强制首次分配新块）
 * 
 * 说明：
 * - 在 enable_memory_logging() 中调用
 * - 只能调用一次（重复调用返回 false）
 * - 删除旧文件确保从干净状态开始
 */
bool shared_memory_pool_file_init(const char *dir) {
    // 检查是否已初始化
    if (s_pool != NULL) {
        return false;
    }

    // 删除旧文件
    remove_file(dir, "file_memory.dat");
    
    // 创建新的内存池
    s_pool = new memory_pool_file(dir, "file_memory.dat");
    
    // 初始化全局变量
    s_alloc_ptr = NULL;
    s_alloc_index = MALLOC_SIZE;  // 设置为 MALLOC_SIZE 强制首次分配
    
    return s_pool != NULL;
}

/**
 * 从共享内存池分配内存
 * 
 * @param size 分配的大小（字节）
 * @return 分配的内存指针，失败会 abort()
 * 
 * 分配流程（Bump Allocator）：
 * ┌──────────────────────────────────────────┐
 * │ 1. 检查当前块是否有足够空间              │
 * │    if (s_alloc_index + size >= 1MB)      │
 * │                                          │
 * │ 2. 如果不够，分配新块                    │
 * │    - s_alloc_ptr = s_pool->malloc(1MB)   │
 * │    - s_alloc_index = 0                   │
 * │    - 失败会 abort()                      │
 * │                                          │
 * │ 3. 从当前块分配                          │
 * │    - ret = s_alloc_ptr + s_alloc_index   │
 * │                                          │
 * │ 4. 更新偏移量                            │
 * │    - s_alloc_index += size               │
 * │                                          │
 * │ 5. 对齐到 16 字节边界                    │
 * │    - s_alloc_index = ((index+15)>>4)<<4  │
 * └──────────────────────────────────────────┘
 * 
 * 示例：
 * ```
 * // 首次分配 100 字节
 * void *p1 = shared_memory_pool_file_alloc(100);
 * // s_alloc_index: 0 → 112 (100 对齐到 16)
 * 
 * // 第二次分配 200 字节
 * void *p2 = shared_memory_pool_file_alloc(200);
 * // s_alloc_index: 112 → 320 (112+200 对齐到 16)
 * 
 * // 分配超过剩余空间
 * void *p3 = shared_memory_pool_file_alloc(1MB);
 * // 分配新块，s_alloc_index 重置为 0
 * ```
 * 
 * 性能：
 * - 块内分配：~0.1 微秒
 * - 跨块分配：~50-100 微秒
 * 
 * 注意：
 * - 失败会 abort()（内存不足是致命错误）
 * - 不支持释放（只能整体释放）
 * - 16 字节对齐提高缓存性能
 */
void *shared_memory_pool_file_alloc(size_t size) {
    // 1. 检查当前块是否有足够空间
    if (s_alloc_index + size >= MALLOC_SIZE) {
        // 2. 当前块不够，分配新块
        s_alloc_ptr = s_pool->malloc(MALLOC_SIZE);
        if (s_alloc_ptr == NULL) {
            abort();  // 分配失败是致命错误
        }
        s_alloc_index = 0;  // 重置偏移量
    }

    // 3. 从当前块分配
    void *ret = (void *)((uintptr_t)s_alloc_ptr + s_alloc_index);
    
    // 4. 更新偏移量
    s_alloc_index += size;
    
    // 5. 对齐到 16 字节边界
    // (index + 15) >> 4 << 4
    // 例如：100 → 112, 200 → 208, 201 → 208
    s_alloc_index = (((s_alloc_index + 15) >> 4) << 4);
    
    return ret;
}
