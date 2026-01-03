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

#ifndef WCBlockTypeDef_h
#define WCBlockTypeDef_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, EFilterType) {
    EFilterType_None = 0,
    EFilterType_Meaningless = 1, // the adress count of the stack is too little
    EFilterType_Annealing = 2, // the Annealing algorithm, filter the continuous same stack
    EFilterType_TrigerByTooMuch = 3, // filter the stack that appear too much one day
};

//// Define the type of the lag
//typedef NS_ENUM(NSUInteger, EDumpType) {
//    EDumpType_Unlag = 2000,                                 // 无卡顿
//    EDumpType_MainThreadBlock = 2001,                       // 主线程卡顿（运行时）
//    EDumpType_BackgroundMainThreadBlock = 2002, // background main thread block
//    EDumpType_CPUBlock = 2003, // CPU too high
//    //EDumpType_FrameDropBlock = 2004,             // frame drop too much,no use currently
//    EDumpType_SelfDefinedDump = 2005, // no use currently
//    //EDumpType_B2FBlock = 2006,                   // no use currently
//    EDumpType_LaunchBlock = 2007, // main thread block during the launch of the app
//    //EDumpType_CPUIntervalHigh = 2008,            // CPU too high within a time period
//    EDumpType_BlockThreadTooMuch = 2009, // main thread block and the thread is too much. (more than 64 threads)
//    EDumpType_BlockAndBeKilled = 2010, // main thread block and killed by the system
//    //EDumpType_JSStack = 2011,                    // no use currently
//    EDumpType_PowerConsume = 2011, // battery cost stack report
//    EDumpType_DiskIO = 2013, // disk io too much
//    EDumpType_FPS = 2014, // FPS
//    EDumpType_Test = 10000,
//};


// 定义卡顿 / 性能问题的类型
typedef NS_ENUM(NSUInteger, EDumpType) {
    EDumpType_Unlag = 2000,
    // 无卡顿 / 无性能问题

    EDumpType_MainThreadBlock = 2001,
    // 主线程卡顿（运行过程中发生）

    EDumpType_BackgroundMainThreadBlock = 2002,
    // App 进入后台后，主线程发生卡顿

    EDumpType_CPUBlock = 2003,
    // CPU 占用过高导致的卡顿

    // EDumpType_FrameDropBlock = 2004,
    // 掉帧过多（当前未使用）

    EDumpType_SelfDefinedDump = 2005,
    // 自定义 dump 类型（当前未使用）

    // EDumpType_B2FBlock = 2006,
    // 后台切前台卡顿（当前未使用）

    EDumpType_LaunchBlock = 2007,
    // App 启动阶段主线程卡顿

    // EDumpType_CPUIntervalHigh = 2008,
    // 某一时间区间内 CPU 持续过高（未使用）

    EDumpType_BlockThreadTooMuch = 2009,
    // 主线程卡顿 + 线程数量过多（超过 64 个线程）

    EDumpType_BlockAndBeKilled = 2010,
    // 主线程卡顿并最终被系统杀死（Watchdog / OOM 等）

    // EDumpType_JSStack = 2011,
    // JS 调用栈（未使用）

    EDumpType_PowerConsume = 2011,
    // 功耗问题（电量消耗过高的调用栈上报）

    EDumpType_DiskIO = 2013,
    // 磁盘 I/O 过高

    EDumpType_FPS = 2014,
    // FPS 过低 / 帧率问题

    EDumpType_Test = 10000,
    // 测试类型
};


#endif /* WCBlockTypeDef_h */
