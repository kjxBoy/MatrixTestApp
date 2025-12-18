/*
 * Tencent is pleased to support the open source community by making wechat-matrix available.
 * Copyright (C) 2019 THL A29 Limited, a Tencent company. All rights reserved.
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

#import "WCGetMainThreadUtil.h"
#import <mach/mach_types.h>      // Mach内核类型定义
#import <mach/mach_init.h>       // Mach初始化相关函数
#import <mach/thread_act.h>      // 线程操作相关API（挂起、恢复等）
#import <mach/task.h>            // 任务(进程)操作相关API
#import <mach/mach_port.h>       // Mach端口管理
#import <mach/vm_map.h>          // 虚拟内存管理
#import "KSStackCursor_SelfThread.h"  // KSCrash框架的堆栈游标工具
#import "KSThread.h"                  // KSCrash框架的线程工具

@interface WCGetMainThreadUtil ()
@end

@implementation WCGetMainThreadUtil

/**
 * 获取主线程堆栈的简化版本
 * 使用默认的最大堆栈深度(300层)
 */
+ (void)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock {
    [WCGetMainThreadUtil getCurrentMainThreadStack:saveResultBlock withMaxEntries:WXGBackTraceMaxEntries];
}

/**
 * 获取主线程堆栈，指定最大深度
 * 内部调用完整版本的方法，线程数通过临时变量接收但不返回给调用者
 */
+ (int)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock withMaxEntries:(NSUInteger)maxEntries {
    NSUInteger tmpThreadCount;
    return [WCGetMainThreadUtil getCurrentMainThreadStack:saveResultBlock withMaxEntries:maxEntries withThreadCount:tmpThreadCount];
}

/**
 * 获取主线程堆栈的完整实现
 * 通过Mach内核API获取主线程堆栈，并通过回调返回每一帧的地址
 *
 * 实现步骤：
 * 1. 获取当前任务的所有线程
 * 2. 获取主线程（默认为第一个线程threads[0]）
 * 3. 检查是否在主线程中调用，如果是则跳过（避免死锁）
 * 4. 挂起主线程
 * 5. 获取主线程的堆栈回溯
 * 6. 通过回调返回堆栈信息
 * 7. 恢复主线程
 * 8. 清理资源
 */
+ (int)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock
                  withMaxEntries:(NSUInteger)maxEntries
                 withThreadCount:(NSUInteger &)retThreadCount {
    // 获取当前任务（进程）
    const task_t thisTask = mach_task_self();
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;

    // 获取当前任务的所有线程列表
    if (task_threads(thisTask, &threads, &thread_count) != KERN_SUCCESS) {
        return 0;  // 获取线程列表失败，返回0
    }

    // 主线程通常是第一个线程
    thread_t mainThread = threads[0];
    int backTraceLength = 0;  // 实际获取到的堆栈帧数
    uintptr_t backtraceBuffer[maxEntries];  // 堆栈缓冲区，存储各帧的地址

    // 获取当前线程
    KSThread currentThread = ksthread_self();
    // 如果当前就在主线程中调用，直接跳转到清理代码，避免死锁
    if (mainThread == currentThread) {
        goto cleanup;
    }

    // 挂起主线程，以便获取其堆栈信息
    if (thread_suspend(mainThread) != KERN_SUCCESS) {
        goto cleanup;  // 挂起失败，跳转到清理代码
    }

    // 使用KSCrash的工具函数获取主线程的堆栈回溯
    backTraceLength = kssc_backtraceCurrentThread(mainThread, backtraceBuffer, (int)maxEntries);

    // 遍历堆栈，通过回调返回每一帧的程序计数器(PC)地址
    for (int i = 0; i < backTraceLength; i++) {
        NSUInteger pc = backtraceBuffer[i];
        
        NSLog(@"kjx -- %lx", pc);
        
        saveResultBlock(pc);  // 调用回调，传递PC地址
    }
    // 返回线程总数
    retThreadCount = thread_count;

    // 恢复主线程的执行
    thread_resume(mainThread);

cleanup:
    // 清理资源：释放所有线程端口
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        mach_port_deallocate(thisTask, threads[i]);
    }
    // 释放线程列表占用的虚拟内存
    vm_deallocate(thisTask, (vm_address_t)threads, sizeof(thread_t) * thread_count);

    return backTraceLength;  // 返回实际获取到的堆栈帧数
}

@end
