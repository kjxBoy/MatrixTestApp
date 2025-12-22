//
//  KSMachineContext.c
//
//  Created by Karl Stenerud on 2016-12-02.
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

#include "KSMachineContext_Apple.h"
#include "KSMachineContext.h"
#include "KSSystemCapabilities.h"
#include "KSCPU.h"
#include "KSCPU_Apple.h"
#include "KSStackCursor_MachineContext.h"

#include <pthread.h>
#include <mach/mach.h>
#include <sys/ucontext.h>
#include <sys/_types/_ucontext64.h>

//#define KSLogger_LocalLevel TRACE
#include "KSLogger.h"

#ifdef __arm64__
#define UC_MCONTEXT uc_mcontext64
typedef ucontext64_t SignalUserContext;
#else
#define UC_MCONTEXT uc_mcontext
typedef ucontext_t SignalUserContext;
#endif

static KSThread g_reservedThreads[10];
static int g_reservedThreadsMaxIndex = sizeof(g_reservedThreads) / sizeof(g_reservedThreads[0]) - 1;
static int g_reservedThreadsCount = 0;
static thread_act_array_t g_suspendedThreads = NULL;
static mach_msg_type_number_t g_suspendedThreadsCount = 0;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

static inline bool isStackOverflow(const KSMachineContext *const context) {
    KSStackCursor stackCursor;
    kssc_initWithMachineContext(&stackCursor, KSSC_STACK_OVERFLOW_THRESHOLD, context);
    while (stackCursor.advanceCursor(&stackCursor)) {
    }
    return stackCursor.state.hasGivenUp;
}

static inline bool getThreadList(KSMachineContext *context) {
    const task_t thisTask = mach_task_self();
    KSLOG_DEBUG("Getting thread list");
    kern_return_t kr;
    thread_act_array_t threads;
    mach_msg_type_number_t actualThreadCount;

    if ((kr = task_threads(thisTask, &threads, &actualThreadCount)) != KERN_SUCCESS) {
        KSLOG_ERROR("task_threads: %s", mach_error_string(kr));
        return false;
    }
    KSLOG_TRACE("Got %d threads", context->threadCount);
    int threadCount = (int)actualThreadCount;
    int maxThreadCount = sizeof(context->allThreads) / sizeof(context->allThreads[0]);
    if (threadCount > maxThreadCount) {
        KSLOG_ERROR("Thread count %d is higher than maximum of %d", threadCount, maxThreadCount);
        threadCount = maxThreadCount;
    }
    for (int i = 0; i < threadCount; i++) {
        context->allThreads[i] = threads[i];
    }
    context->threadCount = threadCount;

    for (mach_msg_type_number_t i = 0; i < actualThreadCount; i++) {
        mach_port_deallocate(thisTask, context->allThreads[i]);
    }
    vm_deallocate(thisTask, (vm_address_t)threads, sizeof(thread_t) * actualThreadCount);

    return true;
}

int ksmc_contextSize() {
    return sizeof(KSMachineContext);
}

KSThread ksmc_getThreadFromContext(const KSMachineContext *const context) {
    return context->thisThread;
}

/**
 * ============================================================================
 * 函数：ksmc_getContextForThread
 * ============================================================================
 * 
 * 功能：获取指定线程的机器上下文（寄存器状态）
 * 
 * 这是获取线程堆栈的关键步骤！
 * 通过 Mach 内核 API 获取线程的寄存器快照，包括：
 * - PC (Program Counter): 当前执行的指令地址
 * - FP (Frame Pointer, x29): 帧指针，用于遍历调用栈
 * - SP (Stack Pointer, x31): 栈指针
 * - LR (Link Register, x30): 链接寄存器（返回地址）
 * - x0-x28: 通用寄存器
 * 
 * @param thread 目标线程（必须已被 thread_suspend 挂起）
 * @param destinationContext 输出参数，存储机器上下文
 * @param isCrashedContext 是否是崩溃上下文（崩溃时需要额外信息）
 * @return 成功返回 true
 */
bool ksmc_getContextForThread(KSThread thread, KSMachineContext *destinationContext, bool isCrashedContext) {
    // ========================================================================
    // 日志：记录函数调用信息
    // ========================================================================
    KSLOG_DEBUG("Fill thread 0x%x context into %p. is crashed = %d", thread, destinationContext, isCrashedContext);
    
    // ========================================================================
    // 步骤1：初始化目标上下文（清零）
    // ========================================================================
    // 确保所有字段都是干净的状态
    memset(destinationContext, 0, sizeof(*destinationContext));
    
    // ========================================================================
    // 步骤2：设置基本属性
    // ========================================================================
    
    // 保存线程ID
    destinationContext->thisThread = (thread_t)thread;
    
    // 判断是否是当前线程
    // 注意：如果是当前线程，无法通过 thread_get_state 获取准确的寄存器状态
    //      因为当前线程的寄存器正在被使用（执行此函数）
    destinationContext->isCurrentThread = thread == ksthread_self();
    
    // 是否是崩溃上下文
    // 崩溃时需要收集更多信息（如所有线程列表、栈溢出检测）
    destinationContext->isCrashedContext = isCrashedContext;
    
    // 是否是信号上下文
    // false: 此处通过线程API获取，不是通过信号处理器
    // 如果是信号上下文，应使用 ksmc_getContextForSignal 函数
    destinationContext->isSignalContext = false;
    
    // ========================================================================
    // 步骤3：获取 CPU 状态（寄存器）
    // ========================================================================
    /*
     * ksmc_canHaveCPUState 判断是否可以获取 CPU 状态：
     * 
     * 返回 true 的条件：
     * - 不是当前线程 OR 是信号上下文
     * 
     * 返回 false 的条件：
     * - 是当前线程 AND 不是信号上下文
     * 
     * 为什么当前线程无法获取？
     * - 当前线程的寄存器正在被使用（执行此函数）
     * - FP 指向当前函数的栈帧，不是目标位置
     * - PC 是此函数的指令地址，不是卡顿点
     * - 获取到的状态不准确，没有意义
     * 
     * 例外：信号上下文
     * - 信号处理器会保存触发信号时的寄存器状态
     * - 这个状态是准确的（信号发生瞬间的快照）
     * - 可以用于堆栈回溯
     */
    if (ksmc_canHaveCPUState(destinationContext)) {
        /*
         * kscpu_getState 的作用：
         * 
         * 1. 调用 thread_get_state 系统调用：
         *    kern_return_t thread_get_state(
         *        thread_act_t thread,              // 目标线程
         *        thread_state_flavor_t flavor,     // 状态类型
         *        thread_state_t state,             // 输出缓冲区
         *        mach_msg_type_number_t *count     // 缓冲区大小
         *    );
         * 
         * 2. 获取的寄存器（ARM64）：
         *    - 通用寄存器: x0-x28
         *    - 帧指针 (FP): x29
         *    - 链接寄存器 (LR): x30
         *    - 栈指针 (SP): x31
         *    - 程序计数器 (PC): 当前指令地址
         *    - 程序状态寄存器 (CPSR): 条件标志位等
         * 
         * 3. 数据保存位置：
         *    destinationContext->machineContext
         *    这是一个 _STRUCT_MCONTEXT 结构，包含所有寄存器
         * 
         * 4. 前提条件：
         *    - 目标线程必须已被 thread_suspend 挂起
         *    - 否则会返回 KERN_FAILURE
         * 
         * 5. 性能：
         *    - 系统调用开销: ~3-5μs
         *    - 数据复制: ~1-2μs
         *    - 总计: ~5-10μs
         */
        kscpu_getState(destinationContext);
    }
    
    // ========================================================================
    // 步骤4：如果是崩溃上下文，获取额外信息
    // ========================================================================
    /*
     * 崩溃时需要更完整的现场信息，用于生成崩溃报告
     */
    if (ksmc_isCrashedContext(destinationContext)) {
        // --------------------------------------------------------------------
        // 4.1 检测是否是栈溢出
        // --------------------------------------------------------------------
        /*
         * isStackOverflow 的实现：
         * 1. 初始化堆栈游标
         * 2. 遍历堆栈，直到达到 KSSC_STACK_OVERFLOW_THRESHOLD（通常 200-300 层）
         * 3. 如果达到阈值仍未到达栈底，判定为栈溢出
         * 
         * 栈溢出的常见原因：
         * - 无限递归
         * - 递归深度过大
         * - 栈空间配置过小
         * 
         * 检测意义：
         * - 崩溃报告中标注是否栈溢出
         * - 帮助开发者快速定位问题类型
         */
        destinationContext->isStackOverflow = isStackOverflow(destinationContext);
        
        // --------------------------------------------------------------------
        // 4.2 获取所有线程列表
        // --------------------------------------------------------------------
        /*
         * getThreadList 的作用：
         * 1. 调用 task_threads 获取当前进程的所有线程
         * 2. 保存到 destinationContext->allThreads[]
         * 3. 记录线程数量到 destinationContext->threadCount
         * 
         * 用途：
         * - 崩溃报告中包含所有线程的堆栈
         * - 帮助分析线程间的相互关系
         * - 检测死锁、竞态条件等问题
         * 
         * 注意：
         * - 仅在崩溃时调用（性能考虑）
         * - 正常的堆栈采集不需要所有线程信息
         */
        getThreadList(destinationContext);
    }
    
    KSLOG_TRACE("Context retrieved.");
    return true;
}

bool ksmc_getContextForSignal(void *signalUserContext, KSMachineContext *destinationContext) {
    KSLOG_DEBUG("Get context from signal user context and put into %p.", destinationContext);
    _STRUCT_MCONTEXT *sourceContext = ((SignalUserContext *)signalUserContext)->UC_MCONTEXT;
    memcpy(&destinationContext->machineContext, sourceContext, sizeof(destinationContext->machineContext));
    destinationContext->thisThread = (thread_t)ksthread_self();
    destinationContext->isCrashedContext = true;
    destinationContext->isSignalContext = true;
    destinationContext->isStackOverflow = isStackOverflow(destinationContext);
    getThreadList(destinationContext);
    KSLOG_TRACE("Context retrieved.");
    return true;
}

void ksmc_addReservedThread(KSThread thread) {
    int nextIndex = g_reservedThreadsCount;
    if (nextIndex > g_reservedThreadsMaxIndex) {
        KSLOG_ERROR("Too many reserved threads (%d). Max is %d", nextIndex, g_reservedThreadsMaxIndex);
        return;
    }
    g_reservedThreads[g_reservedThreadsCount++] = thread;
}

#if KSCRASH_HAS_THREADS_API
static inline bool isThreadInList(thread_t thread, KSThread *list, int listCount) {
    for (int i = 0; i < listCount; i++) {
        if (list[i] == (KSThread)thread) {
            return true;
        }
    }
    return false;
}
#endif

void ksmc_suspendEnvironment() {
#if KSCRASH_HAS_THREADS_API
    KSLOG_DEBUG("Suspending environment.");
    kern_return_t kr;
    const task_t thisTask = mach_task_self();
    const thread_t thisThread = (thread_t)ksthread_self();

    if (g_suspendedThreads != NULL) {
        return;
    }

    pthread_mutex_lock(&g_mutex);

    if ((kr = task_threads(thisTask, &g_suspendedThreads, &g_suspendedThreadsCount)) != KERN_SUCCESS) {
        KSLOG_ERROR("task_threads: %s", mach_error_string(kr));
        pthread_mutex_unlock(&g_mutex);
        return;
    }

    for (mach_msg_type_number_t i = 0; i < g_suspendedThreadsCount; i++) {
        thread_t thread = g_suspendedThreads[i];
        if (thread != thisThread && !isThreadInList(thread, g_reservedThreads, g_reservedThreadsCount)) {
            if ((kr = thread_suspend(thread)) != KERN_SUCCESS) {
                // Record the error and keep going.
                KSLOG_ERROR("thread_suspend (%08x): %s", thread, mach_error_string(kr));
            }
        }
    }

    pthread_mutex_unlock(&g_mutex);

    KSLOG_DEBUG("Suspend complete.");
#endif
}

void ksmc_resumeEnvironment() {
#if KSCRASH_HAS_THREADS_API
    KSLOG_DEBUG("Resuming environment.");
    kern_return_t kr;
    const task_t thisTask = mach_task_self();
    const thread_t thisThread = (thread_t)ksthread_self();

    if (g_suspendedThreads == NULL || g_suspendedThreadsCount == 0) {
        KSLOG_ERROR("we should call ksmc_suspendEnvironment() first");
        return;
    }

    pthread_mutex_lock(&g_mutex);

    for (mach_msg_type_number_t i = 0; i < g_suspendedThreadsCount; i++) {
        thread_t thread = g_suspendedThreads[i];
        if (thread != thisThread && !isThreadInList(thread, g_reservedThreads, g_reservedThreadsCount)) {
            if ((kr = thread_resume(thread)) != KERN_SUCCESS) {
                // Record the error and keep going.
                KSLOG_ERROR("thread_resume (%08x): %s", thread, mach_error_string(kr));
            }
        }
    }

    for (mach_msg_type_number_t i = 0; i < g_suspendedThreadsCount; i++) {
        mach_port_deallocate(thisTask, g_suspendedThreads[i]);
    }
    vm_deallocate(thisTask, (vm_address_t)g_suspendedThreads, sizeof(thread_t) * g_suspendedThreadsCount);
    g_suspendedThreads = NULL;
    g_suspendedThreadsCount = 0;

    pthread_mutex_unlock(&g_mutex);

    KSLOG_DEBUG("Resume complete.");
#endif
}

int ksmc_getThreadCount(const KSMachineContext *const context) {
    return context->threadCount;
}

KSThread ksmc_getThreadAtIndex(const KSMachineContext *const context, int index) {
    return context->allThreads[index];
}

int ksmc_indexOfThread(const KSMachineContext *const context, KSThread thread) {
    KSLOG_TRACE("check thread vs %d threads", context->threadCount);
    for (int i = 0; i < (int)context->threadCount; i++) {
        KSLOG_TRACE("%d: %x vs %x", i, thread, context->allThreads[i]);
        if (context->allThreads[i] == thread) {
            return i;
        }
    }
    return -1;
}

bool ksmc_isCrashedContext(const KSMachineContext *const context) {
    return context->isCrashedContext;
}

static inline bool isContextForCurrentThread(const KSMachineContext *const context) {
    return context->isCurrentThread;
}

static inline bool isSignalContext(const KSMachineContext *const context) {
    return context->isSignalContext;
}

bool ksmc_canHaveCPUState(const KSMachineContext *const context) {
    return !isContextForCurrentThread(context) || isSignalContext(context);
}

bool ksmc_hasValidExceptionRegisters(const KSMachineContext *const context) {
    return ksmc_canHaveCPUState(context) && ksmc_isCrashedContext(context);
}

void ksmc_getCpuUsage(struct KSMachineContext *destinationContext) {
    const task_t thisTask = mach_task_self();
    kern_return_t kr;
    thread_act_array_t threads;
    mach_msg_type_number_t actualThreadCount;

    if ((kr = task_threads(thisTask, &threads, &actualThreadCount)) != KERN_SUCCESS) {
        KSLOG_ERROR("task_threads: %s", mach_error_string(kr));
        return;
    }
    KSLOG_TRACE("Got %d threads", context->threadCount);
    int threadCount = (int)actualThreadCount;
    int maxThreadCount = sizeof(destinationContext->allThreads) / sizeof(destinationContext->allThreads[0]);
    if (threadCount > maxThreadCount) {
        KSLOG_ERROR("Thread count %d is higher than maximum of %d", threadCount, maxThreadCount);
        threadCount = maxThreadCount;
    }
    for (int i = 0; i < threadCount; i++) {
        destinationContext->allThreads[i] = threads[i];

        thread_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            destinationContext->cpuUsage[i] = 0;
            continue;
        }

        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            destinationContext->cpuUsage[i] = basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
        } else {
            destinationContext->cpuUsage[i] = 0;
        }
    }
    destinationContext->threadCount = threadCount;

    for (mach_msg_type_number_t i = 0; i < actualThreadCount; i++) {
        mach_port_deallocate(thisTask, destinationContext->allThreads[i]);
    }
    vm_deallocate(thisTask, (vm_address_t)threads, sizeof(thread_t) * actualThreadCount);
}

void ksmc_setCpuUsage(struct KSMachineContext *destinationContext, struct KSMachineContext *fromContext) {
    int count = destinationContext->threadCount;
    int count_cpu = fromContext->threadCount;

    for (int i = 0; i < count; ++i) {
        KSThread thread0 = destinationContext->allThreads[i];
        destinationContext->cpuUsage[i] = 0;

        for (int j = 0; j < count_cpu; ++j) {
            KSThread thread1 = fromContext->allThreads[j];

            if (thread0 == thread1) {
                destinationContext->cpuUsage[i] = fromContext->cpuUsage[j];
                break;
            }
        }
    }
}

float ksmc_getThreadCpuUsageByIndex(const struct KSMachineContext *const context, int index) {
    return context->cpuUsage[index];
}
