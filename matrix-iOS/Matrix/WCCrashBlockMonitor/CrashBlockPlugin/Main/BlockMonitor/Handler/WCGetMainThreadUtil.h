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

#import <Foundation/Foundation.h>

/**
 * 堆栈回溯的最大深度
 * 设置为300层，用于限制获取堆栈时的最大帧数，避免内存溢出
 */
#define WXGBackTraceMaxEntries 300

/**
 * 主线程堆栈获取工具类
 * 用于获取iOS应用主线程的调用堆栈信息，主要用于卡顿监控和性能分析
 * 通过Mach内核API实现线程挂起、堆栈回溯等功能
 */
@interface WCGetMainThreadUtil : NSObject

/**
 * 获取当前主线程的调用堆栈（使用默认最大深度）
 *
 * @param saveResultBlock 回调block，用于接收堆栈中每一帧的程序计数器(PC)地址
 *                        每获取到一帧堆栈信息，就会调用一次该block
 */
+ (void)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock;

/**
 * 获取当前主线程的调用堆栈（指定最大深度）
 *
 * @param saveResultBlock 回调block，用于接收堆栈中每一帧的程序计数器(PC)地址
 * @param maxEntries 允许获取的最大堆栈帧数，避免堆栈过深导致的性能问题
 * @return 实际获取到的堆栈帧数
 */
+ (int)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock withMaxEntries:(NSUInteger)maxEntries;

/**
 * 获取当前主线程的调用堆栈（指定最大深度并返回线程总数）
 *
 * @param saveResultBlock 回调block，用于接收堆栈中每一帧的程序计数器(PC)地址/Users/momo/Desktop/MatrixTestApp/matrix-iOS/Matrix/WCCrashBlockMonitor/CrashBlockPlugin/Main/WCCrashBlockMonitorDelegate.h
 * @param maxEntries 允许获取的最大堆栈帧数
 * @param retThreadCount 输出参数，返回当前任务的线程总数
 * @return 实际获取到的堆栈帧数，如果获取失败则返回0
 */
+ (int)getCurrentMainThreadStack:(void (^)(NSUInteger pc))saveResultBlock
                  withMaxEntries:(NSUInteger)maxEntries
                 withThreadCount:(NSUInteger &)retThreadCount;

@end
