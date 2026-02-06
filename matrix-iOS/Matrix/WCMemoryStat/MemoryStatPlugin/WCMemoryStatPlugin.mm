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

/**
 * WCMemoryStatPlugin - Matrix 内存统计插件实现
 * 
 * ============================================================================
 * 核心功能
 * ============================================================================
 * 
 * 1. FOOM (Foreground Out Of Memory) 检测与上报
 *    - 实时记录内存分配事件到本地数据库
 *    - 通过 MatrixAppRebootAnalyzer 检测上次是否 FOOM
 *    - 自动生成并上报 OOM 报告
 * 
 * 2. 内存监控
 *    - 拦截 malloc/free 调用（通过 malloc_logger）
 *    - 记录分配地址、大小、堆栈
 *    - 异步写入磁盘（性能优化）
 * 
 * 3. 实时内存快照
 *    - 支持手动触发 memory dump
 *    - 不等待 OOM，立即导出当前内存状态
 *    - 可用于调试和分析
 * 
 * ============================================================================
 * 完整的 FOOM 检测和上报流程
 * ============================================================================
 * 
 * 【第 N 次运行 - 发生 FOOM】
 * ┌────────────────────────────────────────────────────────────┐
 * │ 1. App 启动                                                 │
 * │ 2. WCMemoryStatPlugin.start 被调用                          │
 * │ 3. enable_memory_logging() 启动监控                         │
 * │    - 设置 malloc_logger = __memory_event_callback           │
 * │    - 启动异步写入线程 __memory_event_writing_thread         │
 * │    - 创建数据库文件：                                        │
 * │      · allocation_event_db.dat（分配事件）                  │
 * │      · stack_frames_db.dat（堆栈信息）                      │
 * │ 4. 用户正常使用 App                                         │
 * │    malloc(100) → malloc_logger 回调 → 写入环形缓冲区 →     │
 * │    → 异步线程取出 → 写入磁盘（5-10ms 延迟）                 │
 * │ 5. 内存持续增长...                                          │
 * │ 6. 💥 内存超限！系统发送 Jetsam 信号                        │
 * │    - App 被强制杀死（无法执行代码）                         │
 * │    - 最后几毫秒的数据可能丢失                               │
 * │    - 但绝大部分数据已持久化到磁盘                           │
 * └────────────────────────────────────────────────────────────┘
 * 
 * 【第 N+1 次运行 - 检测和上报】
 * ┌────────────────────────────────────────────────────────────┐
 * │ 1. App 重新启动                                             │
 * │ 2. MatrixAppRebootAnalyzer 分析上次退出原因：               │
 * │    ✅ 不是 crash（没有 crash 日志）                        │
 * │    ✅ 不是用户杀死（App 在前台运行）                       │
 * │    ✅ 不是系统升级/重启（时间太短）                        │
 * │    ✅ 不是开发者主动退出（没有调用 exit）                  │
 * │    → 结论：是 FOOM！                                       │
 * │ 3. WCMemoryStatPlugin.init 被调用：                         │
 * │    - m_recordManager 加载上次的记录                         │
 * │    - m_lastRecord = 上次的内存记录（包含完整分配历史）      │
 * │    - 补充 userScene = "foreground"                          │
 * │ 4. deplayTryReportOOMInfo 延迟 2 秒后执行：                 │
 * │    - 检测到 lastRebootType == FOOM                          │
 * │    - 从数据库读取分配事件和堆栈                             │
 * │    - 聚合数据（按堆栈分组，统计总大小）                     │
 * │    - 生成 JSON 报告                                         │
 * │    - 创建 MatrixIssue，tag = "MemoryStat"                   │
 * │ 5. MatrixHandler 接收并上传报告到服务器                     │
 * │ 6. 服务器接收、符号化、展示                                 │
 * │ 7. （可选）上报成功后删除本地记录                           │
 * └────────────────────────────────────────────────────────────┘
 * 
 * ============================================================================
 * 关键数据结构
 * ============================================================================
 * 
 * MemoryRecordInfo
 * ├─ launchTime: 启动时间（唯一标识）
 * ├─ systemVersion: 系统版本
 * ├─ appUUID: App UUID
 * ├─ userScene: 用户场景（foreground/background）
 * └─ recordDataPath: 数据文件路径
 *     ├─ allocation_event_db.dat  // 分配事件（地址、大小、堆栈 ID、时间）
 *     └─ stack_frames_db.dat      // 堆栈信息（堆栈 ID → 堆栈帧数组）
 * 
 * MatrixIssue（OOM 报告）
 * ├─ issueTag: "MemoryStat"
 * ├─ issueID: launchTime
 * ├─ dataType: EMatrixIssueDataType_Data
 * └─ issueData: JSON 格式的 OOM 报告
 *     ├─ head: 头部信息（设备、系统、时间）
 *     └─ items: 内存分配项数组（按堆栈分组）
 *         ├─ size: 总大小
 *         ├─ count: 分配次数
 *         └─ stacks: 堆栈信息（多层）
 * 
 * ============================================================================
 * 性能优化策略
 * ============================================================================
 * 
 * 1. 异步写入：
 *    - malloc_logger 回调在主线程执行（必须快速返回）
 *    - 将事件写入环形缓冲区（无锁，微秒级）
 *    - 后台线程异步取出并写入磁盘（5-10ms 延迟）
 * 
 * 2. 过滤策略：
 *    - skip_max_stack_depth: 跳过浅堆栈（< 3 层，通常是内部分配）
 *    - skip_min_malloc_size: 跳过小分配（< 30 字节，减少数据量）
 * 
 * 3. 内部分配隔离：
 *    - inter_zone: Matrix 自己的 malloc_zone
 *    - 避免监控自己（防止递归）
 *    - 通过 thread-local 变量 is_ignore 标记
 * 
 * 4. 调试检测：
 *    - 被调试时不启动（isBeingDebugged）
 *    - 避免严重影响调试性能
 * 
 * ============================================================================
 * 使用示例
 * ============================================================================
 * 
 * // 1. 安装插件
 * WCMemoryStatPlugin *memPlugin = [[WCMemoryStatPlugin alloc] init];
 * memPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
 * [matrix addPlugin:memPlugin];
 * 
 * // 2. 启动监控
 * [memPlugin start];
 * 
 * // 3. （可选）手动触发内存快照
 * [memPlugin memoryDumpAndGenerateReportData:@"manual_dump" 
 *                                 customInfo:@{@"page": @"home"} 
 *                                   callback:^(NSData *data) {
 *     NSLog(@"Memory snapshot: %@", data);
 * }];
 * 
 * // 4. 停止监控
 * [memPlugin stop];
 * 
 * ============================================================================
 * 相关文件
 * ============================================================================
 * 
 * - memory_logging.h/cpp: C++ 层监控实现（malloc_logger、异步写入）
 * - logger_internal.h/cpp: 内部工具（线程管理、内部分配器）
 * - WCMemoryRecordManager: 记录管理（数据库操作）
 * - MatrixAppRebootAnalyzer: 退出原因分析（FOOM 检测）
 * - allocation_event_db.h/cpp: 分配事件数据库
 * - stack_frames_db.h/cpp: 堆栈信息数据库
 * 
 * ============================================================================
 */

#import "WCMemoryStatPlugin.h"
#import "WCMemoryStatConfig.h"
#import "WCMemoryRecordManager.h"
#import "MatrixLogDef.h"
#import "MatrixAppRebootAnalyzer.h"
#import "MatrixDeviceInfo.h"
#import "MatrixPathUtil.h"

#import "memory_logging.h"
#import "logger_internal.h"
#import "dyld_image_info.h"

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#import <objc/runtime.h>

#define g_matrix_memory_stat_plugin_tag "MemoryStat"

// ============================================================================
#pragma mark - Memory dump callback
// ============================================================================

/**
 * 全局回调 block，用于接收 memory_dump 生成的报告数据
 * 
 * 工作流程：
 * 1. memoryDumpAndGenerateReportData:customInfo:callback: 方法设置这个 block
 * 2. memory_dump() C++ 函数在后台线程生成报告
 * 3. 生成完成后调用 memory_dump_callback()
 * 4. memory_dump_callback() 执行这个 block，将数据传回 ObjC 层
 * 5. 执行完毕后置为 nil，避免循环引用
 */
static void (^s_callback)(NSData *) = nil;

/**
 * C 函数回调：接收 memory_dump() 生成的报告数据
 * 
 * @param data 报告数据的 C 字符串指针
 * @param len 数据长度
 * 
 * 说明：
 * - 这是 C++ 层调用的回调函数，需要是 C 函数
 * - 使用 @autoreleasepool 确保内存及时释放
 * - 将 C 数据转换为 NSData 后传递给 ObjC 层的 block
 * - 执行完毕后清空 s_callback，防止内存泄漏
 */
void memory_dump_callback(const char *data, size_t len) {
    @autoreleasepool {
        NSData *reportData = [NSData dataWithBytes:(void *)data length:len];
        s_callback(reportData);
        s_callback = nil;
    }
}

// ============================================================================
#pragma mark - WCMemoryStatPlugin
// ============================================================================

/**
 * WCMemoryStatPlugin 私有扩展
 * 
 * 核心成员变量说明：
 * 
 * m_recordManager：内存记录管理器
 * - 负责持久化存储和管理内存记录
 * - 将记录保存到本地数据库
 * - 提供增删改查接口
 * 
 * m_lastRecord：上次运行的内存记录
 * - 在 init 中从数据库加载
 * - 如果上次是 FOOM，这条记录包含了导致 OOM 的内存分配信息
 * - 用于在启动后上报 OOM 报告
 * 
 * m_currRecord：当前运行的内存记录
 * - 在 start 方法中创建
 * - 正在实时记录本次运行的内存分配
 * - 如果本次发生 FOOM，下次启动时会变成 m_lastRecord
 * 
 * pluginReportQueue：串行队列
 * - 用于处理报告上传
 * - 避免阻塞主线程
 * - 确保报告按顺序上传
 */
@interface WCMemoryStatPlugin () {
    WCMemoryRecordManager *m_recordManager;  // 内存记录管理器

    MemoryRecordInfo *m_lastRecord;  // 上次运行的记录（可能是 OOM 记录）
    MemoryRecordInfo *m_currRecord;  // 当前运行的记录（正在实时写入）
}

@property (nonatomic, strong) dispatch_queue_t pluginReportQueue;  // 报告上传队列

@end

@implementation WCMemoryStatPlugin

@dynamic pluginConfig;

/**
 * 初始化内存统计插件
 * 
 * 初始化流程：
 * 1. 创建记录管理器
 * 2. 加载上次运行的记录（通过启动时间关联）
 * 3. 补充上次运行的用户场景信息（foreground/background）
 * 4. 创建串行队列用于报告上传
 * 5. 延迟检查是否需要上报 OOM
 * 
 * 关键逻辑：
 * - 如果上次是 FOOM，m_lastRecord 会包含内存分配记录
 * - 用户场景由 MatrixAppRebootAnalyzer 分析得出
 * - 延迟上报是为了让 App 先完成启动，避免影响启动性能
 */
- (id)init {
    self = [super init];
    if (self) {
        // 1. 创建记录管理器（负责数据库操作）
        m_recordManager = [[WCMemoryRecordManager alloc] init];
        
        // 2. 加载上次运行的内存记录
        // lastAppLaunchTime：上次 App 启动的时间戳，用作记录的唯一标识
        m_lastRecord = [m_recordManager getRecordByLaunchTime:[MatrixAppRebootAnalyzer lastAppLaunchTime]];
        
        // 3. 补充用户场景信息（foreground/background）
        if (m_lastRecord) {
            // MatrixAppRebootAnalyzer 通过"排除法"判断出上次的场景
            // 如果是 FOOM，会标记为 foreground
            m_lastRecord.userScene = [MatrixAppRebootAnalyzer userSceneOfLastRun];
            [m_recordManager updateRecord:m_lastRecord];
        }

        // 4. 创建串行队列，避免报告上传阻塞主线程
        self.pluginReportQueue = dispatch_queue_create("matrix.memorystat", DISPATCH_QUEUE_SERIAL);

        // 5. 延迟 2 秒后尝试上报 OOM（如果上次是 FOOM）
        [self deplayTryReportOOMInfo];
    }
    return self;
}

// ============================================================================
#pragma mark - Report
// ============================================================================

/**
 * 延迟尝试上报 OOM 信息
 * 
 * 完整的 FOOM 检测和上报流程：
 * 
 * 【第 N 次运行】
 * 1. 用户使用 App，内存持续增长
 * 2. memory_logging 实时记录每次分配到本地数据库
 * 3. 内存超限，系统发送 Jetsam 信号，App 被杀死（FOOM）
 * 4. 最后几毫秒的数据可能丢失，但绝大部分已持久化
 * 
 * 【第 N+1 次运行（当前）】
 * 5. App 重启，MatrixAppRebootAnalyzer 通过"排除法"判断上次是 FOOM
 * 6. WCMemoryStatPlugin.init 加载上次的内存记录
 * 7. 延迟 2 秒后调用此方法
 * 8. 检测到 lastRebootType == MatrixAppRebootTypeAppForegroundOOM
 * 9. 从数据库读取记录，生成 JSON 报告
 * 10. 通过 MatrixIssue 机制上报到服务器
 * 11. 上报成功后删除本地记录
 * 
 * 延迟原因：
 * - 避免影响 App 启动性能
 * - 让主线程有时间完成关键初始化
 * - 给 delegate 准备 customInfo 的机会
 * 
 * 上报策略：
 * - Auto（默认）：自动上报
 * - Manual：手动上报，由业务方调用 uploadReport: 方法
 */
- (void)deplayTryReportOOMInfo {
    // 延迟 2 秒，在主队列执行
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 检查上报策略：如果是手动上报，不自动上报
        if (self.pluginConfig != nil && self.pluginConfig.reportStrategy == EWCMemStatReportStrategy_Manual) {
            return;
        }
        
        // 获取自定义信息（业务方可以添加用户 ID、页面路径等）
        NSDictionary *customInfo = nil;
        if (self.delegate != nil && [self.delegate respondsToSelector:@selector(onMemoryStatPluginGetCustomInfo:)]) {
            customInfo = [self.delegate onMemoryStatPluginGetCustomInfo:self];
        }
        
        // 在后台队列执行上报逻辑
        dispatch_async(self.pluginReportQueue, ^{
            // 🔍 关键判断：上次退出是否是 FOOM
            if ([MatrixAppRebootAnalyzer lastRebootType] == MatrixAppRebootTypeAppForegroundOOM) {
                // 获取上次运行的内存记录
                MemoryRecordInfo *lastInfo = [self recordOfLastRun];
                if (lastInfo != nil) {
                    // 生成 OOM 报告（JSON 格式）
                    NSData *reportData = [lastInfo generateReportDataWithCustomInfo:customInfo];
                    if (reportData != nil) {
                        // 创建 MatrixIssue 对象
                        MatrixIssue *issue = [[MatrixIssue alloc] init];
                        issue.issueTag = [WCMemoryStatPlugin getTag];  // "MemoryStat"
                        issue.issueID = [lastInfo recordID];           // 记录 ID（launch time）
                        issue.dataType = EMatrixIssueDataType_Data;    // 数据类型：NSData
                        issue.issueData = reportData;                  // OOM 报告 JSON
                        
                        MatrixInfo(@"report memory record: %@", issue);
                        
                        // 回到主线程上报（MatrixHandler 会处理）
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self reportIssue:issue];
                        });
                    }
                }
            }
        });
    });
}

/**
 * 手动上报内存记录
 * 
 * @param record 要上报的内存记录（通常是 recordOfLastRun）
 * @param customInfo 自定义信息（用户 ID、页面信息等）
 * @return MatrixIssue 对象，如果失败返回 nil
 * 
 * 使用场景：
 * - reportStrategy 设置为 Manual 时，业务方主动调用
 * - 可以在合适的时机上报（如 WiFi 环境）
 * - 可以添加更丰富的业务上下文信息
 * 
 * 与 deplayTryReportOOMInfo 的区别：
 * - deplayTryReportOOMInfo：自动上报，固定延迟 2 秒
 * - uploadReport：手动上报，由业务方决定时机
 */
- (MatrixIssue *)uploadReport:(MemoryRecordInfo *)record withCustomInfo:(NSDictionary *)customInfo {
    if (record == nil) {
        return nil;
    }

    // 生成 OOM 报告 JSON
    NSData *reportData = [record generateReportDataWithCustomInfo:customInfo];
    if (reportData == nil) {
        return nil;
    }

    // 创建 MatrixIssue
    MatrixIssue *issue = [[MatrixIssue alloc] init];
    issue.issueTag = [WCMemoryStatPlugin getTag];
    issue.issueID = [record recordID];
    issue.dataType = EMatrixIssueDataType_Data;
    issue.issueData = reportData;
    MatrixInfo(@"memory record : %@", issue);
    
    // 上报（会传递给 MatrixHandler）
    [self reportIssue:issue];

    return issue;
}

/**
 * 即时生成内存快照并导出报告（实时 dump）
 * 
 * @param issue 问题描述（如 "manual_dump"、"memory_warning"）
 * @param customInfo 自定义信息字典
 * @param callback 回调 block，接收生成的报告数据
 * 
 * 使用场景：
 * - 手动触发内存快照（测试、调试）
 * - 内存警告时主动导出当前状态
 * - 不等待 OOM，立即分析内存分布
 * 
 * 与 OOM 自动上报的区别：
 * - OOM 上报：读取上次的持久化记录（历史数据）
 * - memoryDump：读取当前正在运行的记录（实时数据）
 * 
 * 工作流程：
 * 1. 检查 m_currRecord（必须正在监控）
 * 2. 准备报告参数（设备信息、时间戳等）
 * 3. 调用 C++ 层的 memory_dump() 函数
 * 4. memory_dump() 在后台线程生成报告
 * 5. 通过 memory_dump_callback() 回调返回数据
 * 6. 执行 callback block，将数据传回业务层
 * 
 * 注意：
 * - 必须在 start() 之后调用（m_currRecord != nil）
 * - 生成报告有一定耗时，不要在主线程等待
 * - callback 在后台线程执行
 */
- (void)memoryDumpAndGenerateReportData:(NSString *)issue customInfo:(NSDictionary *)customInfo callback:(void (^)(NSData *))callback {
    // 检查是否正在监控
    if (m_currRecord == nil) {
        MatrixInfo(@"memstat is not running");
        return;
    }

    // 准备报告参数
    summary_report_param param;
    param.phone = [MatrixDeviceInfo platform].UTF8String;              // 设备型号，如 "iPhone14,2"
    param.os_ver = [MatrixDeviceInfo systemVersion].UTF8String;        // 系统版本，如 "iOS 15.0"
    param.launch_time = [MatrixAppRebootAnalyzer appLaunchTime] * 1000;  // 启动时间（毫秒）
    param.report_time = [[NSDate date] timeIntervalSince1970] * 1000;    // 报告时间（毫秒）
    param.app_uuid = app_uuid();                                       // App UUID（dyld 提供）
    param.foom_scene = issue.UTF8String;                               // 场景描述

    // 转换自定义信息到 C++ map
    for (id key in customInfo) {
        std::string stdKey = [key UTF8String];
        std::string stdVal = [[customInfo[key] description] UTF8String];
        param.customInfo.insert(std::make_pair(stdKey, stdVal));
    }

    // 调用 C++ 层生成报告
    // memory_dump() 会在后台线程读取数据库、聚合数据、生成 JSON
    // 完成后调用 memory_dump_callback(data, len)
    if (memory_dump(memory_dump_callback, param)) {
        // 设置全局回调，等待 C++ 层调用
        s_callback = callback;
    }
}

// ============================================================================
#pragma mark - Record
// ============================================================================

/**
 * 获取所有内存记录列表
 * 
 * @return MemoryRecordInfo 数组
 * 
 * 说明：
 * - 从数据库读取所有记录
 * - 每条记录对应一次 App 运行
 * - 可用于历史记录查看
 */
- (NSArray *)recordList {
    return [m_recordManager recordList];
}

/**
 * 获取上次运行的记录
 * 
 * @return 上次的 MemoryRecordInfo，如果没有返回 nil
 * 
 * 说明：
 * - 如果上次是 FOOM，这条记录包含了导致 OOM 的内存分配信息
 * - 在 init 中加载，deplayTryReportOOMInfo 中上报
 * - 上报成功后会被删除
 */
- (MemoryRecordInfo *)recordOfLastRun {
    return m_lastRecord;
}

/**
 * 根据启动时间查询记录
 * 
 * @param launchTime App 启动时间戳（秒）
 * @return 对应的 MemoryRecordInfo，如果没有返回 nil
 * 
 * 说明：
 * - launchTime 是记录的唯一标识
 * - 由 MatrixAppRebootAnalyzer 提供
 */
- (MemoryRecordInfo *)recordByLaunchTime:(uint64_t)launchTime {
    return [m_recordManager getRecordByLaunchTime:launchTime];
}

/**
 * 删除指定的内存记录
 * 
 * @param record 要删除的记录
 * 
 * 说明：
 * - 会删除数据库中的元数据
 * - 会删除磁盘上的数据文件（allocation_event_db.dat、stack_frames_db.dat）
 * - 通常在上报成功后调用
 */
- (void)deleteRecord:(MemoryRecordInfo *)record {
    [m_recordManager deleteRecord:record];
}

/**
 * 删除所有内存记录
 * 
 * 说明：
 * - 清空数据库
 * - 删除所有数据文件
 * - 释放磁盘空间
 */
- (void)deleteAllRecords {
    [m_recordManager deleteAllRecords];
}

/**
 * 获取插件自身使用的内存大小
 * 
 * @return 内存大小（字节）
 * 
 * 说明：
 * - inter_zone 是 Matrix 内部分配器
 * - 用于分配 Matrix 自身的数据结构
 * - 避免监控自己的分配（防止递归）
 * - 可用于评估插件的性能开销
 */
- (size_t)pluginMemoryUsed {
    return inter_malloc_zone_statistics();
}

// ============================================================================
#pragma mark - Private
// ============================================================================

/**
 * 将当前记录标记为无效并删除
 * 
 * 使用场景：
 * - 启动失败时清理
 * - stop 时清理当前记录
 * 
 * 说明：
 * - 会删除数据库记录
 * - 会删除磁盘数据文件
 * - 置空 m_currRecord
 */
- (void)setCurrentRecordInvalid {
    if (m_currRecord == nil) {
        return;
    }

    [m_recordManager deleteRecord:m_currRecord];
    m_currRecord = nil;
}

/**
 * 上报错误给代理
 * 
 * @param errorCode 错误码（定义在 memory_logging.h）
 * 
 * 错误码示例：
 * - MS_ERRC_SUCCESS: 成功
 * - MS_ERRC_OPEN_FILE_FAILED: 打开文件失败
 * - MS_ERRC_INIT_FAILED: 初始化失败
 */
- (void)reportError:(int)errorCode {
    [self.delegate onMemoryStatPlugin:self hasError:errorCode];
}

// ============================================================================
#pragma mark - MatrixPluginProtocol
// ============================================================================

/**
 * 启动内存监控
 * 
 * 完整的启动流程：
 * 
 * 【前置检查】
 * 1. 检测调试器：被调试时不启动（避免性能影响）
 * 2. 检查重复启动：m_currRecord != nil 说明已启动
 * 3. 调用父类 start（检查插件状态）
 * 
 * 【配置参数】
 * 4. 加载或使用默认配置
 * 5. 设置全局参数：
 *    - skip_max_stack_depth：跳过浅堆栈（如 < 3 层）
 *    - skip_min_malloc_size：跳过小分配（如 < 30 字节）
 *    - dump_call_stacks：是否导出调用栈
 * 
 * 【创建记录】
 * 6. 创建 MemoryRecordInfo
 * 7. 记录启动时间（用作唯一标识）
 * 8. 记录系统版本和 App UUID
 * 
 * 【初始化存储】
 * 9. 创建数据目录（每次启动都是新目录）
 * 10. 清理旧的临时数据
 * 
 * 【启动监控】
 * 11. 调用 enable_memory_logging() 启动 C++ 层监控
 *     - 设置 malloc_logger 回调
 *     - 启动异步写入线程
 *     - 创建数据库文件
 * 12. 成功后插入记录到数据库
 * 13. 失败后清理资源
 * 
 * enable_memory_logging() 会做什么：
 * ┌─────────────────────────────────────────┐
 * │ 1. malloc_logger = __memory_event_callback │ → 拦截 malloc/free
 * │ 2. 启动 __memory_event_writing_thread      │ → 异步写入磁盘
 * │ 3. 创建 allocation_event_db.dat           │ → 存储分配事件
 * │ 4. 创建 stack_frames_db.dat               │ → 存储堆栈信息
 * └─────────────────────────────────────────┘
 * 
 * 之后每次 malloc/free 都会：
 * malloc(100) → malloc_logger 回调 → 写入环形缓冲区 → 异步线程写入磁盘
 * 
 * @return YES 启动成功，NO 启动失败
 */
- (BOOL)start {
    // 1. 检测调试器：调试时不启动（性能影响大）
    if ([MatrixDeviceInfo isBeingDebugged]) {
        MatrixDebug(@"app is being debugged, cannot start memstat");
        return NO;
    }

    // 2. 检查重复启动
    if (m_currRecord != nil) {
        return NO;
    }

    // 3. 调用父类启动逻辑
    if ([super start] == NO) {
        return NO;
    }

    int ret = MS_ERRC_SUCCESS;

    // 4. 加载配置（如果没有则使用默认配置）
    if (self.pluginConfig == nil) {
        self.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
    }

    // 5. 设置全局配置参数（C++ 全局变量）
    if (self.pluginConfig) {
        skip_max_stack_depth = self.pluginConfig.skipMaxStackDepth;    // 跳过浅堆栈（性能优化）
        skip_min_malloc_size = self.pluginConfig.skipMinMallocSize;    // 跳过小分配（减少数据量）
        dump_call_stacks = self.pluginConfig.dumpCallStacks;           // 是否导出堆栈
    }

    // 6. 创建当前记录
    m_currRecord = [[MemoryRecordInfo alloc] init];
    m_currRecord.launchTime = [MatrixAppRebootAnalyzer appLaunchTime];  // 启动时间（唯一标识）
    m_currRecord.systemVersion = [MatrixDeviceInfo systemVersion];      // 系统版本
    m_currRecord.appUUID = @(app_uuid());                                // App UUID

    // 7. 准备数据目录
    NSString *dataPath = [m_currRecord recordDataPath];  // 例如：Library/Caches/Matrix/MemoryStat/Data/1234567890/
    NSString *rootPath = [[MatrixPathUtil memoryStatPluginCachePath] stringByAppendingPathComponent:@"Data"];
    
    // 清理旧数据（如果存在）
    [[NSFileManager defaultManager] removeItemAtPath:dataPath error:nil];
    // 创建新目录
    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];

    // 8. 🚀 启动内存监控（C++ 层）
    // rootPath: 根目录
    // dataPath: 本次记录的数据目录
    if ((ret = enable_memory_logging(rootPath.UTF8String, dataPath.UTF8String)) == MS_ERRC_SUCCESS) {
        // ✅ 成功：插入记录到数据库
        [m_recordManager insertNewRecord:m_currRecord];
        return YES;
    } else {
        // ❌ 失败：清理资源
        MatrixError(@"MemStatPlugin start error: %d", ret);
        disable_memory_logging();  // 停止监控
        [self.delegate onMemoryStatPlugin:self hasError:ret];  // 通知代理
        [[NSFileManager defaultManager] removeItemAtPath:dataPath error:nil];  // 删除目录
        m_currRecord = nil;
        return NO;
    }
}

/**
 * 停止内存监控
 * 
 * 停止流程：
 * 1. 调用父类 stop
 * 2. 删除当前记录（正常停止不保留数据）
 * 3. 调用 disable_memory_logging() 停止 C++ 层监控
 * 
 * disable_memory_logging() 会做什么：
 * ┌──────────────────────────────────┐
 * │ 1. malloc_logger = NULL           │ → 停止拦截
 * │ 2. 停止异步写入线程               │ → 等待队列清空
 * │ 3. 关闭数据库文件                 │ → 刷新缓冲区
 * │ 4. 清理内存                       │ → 释放缓冲区
 * └──────────────────────────────────┘
 * 
 * 注意：
 * - 正常 stop 会删除记录（业务方主动停止，不需要数据）
 * - 如果是 FOOM，不会调用 stop，记录会保留到下次启动
 */
- (void)stop {
    [super stop];
    if (m_currRecord == nil) {
        return;
    }
    
    // 删除当前记录（正常停止不需要保留数据）
    [self deleteRecord:m_currRecord];
    m_currRecord = nil;
    
    // 停止 C++ 层监控
    disable_memory_logging();
}

/**
 * 销毁插件
 * 
 * 在插件生命周期结束时调用
 */
- (void)destroy {
    [super destroy];
}

/**
 * 设置插件监听器
 * 
 * @param pluginListener Matrix 框架的监听器
 * 
 * 说明：
 * - 用于接收插件事件（如 reportIssue）
 * - 由 Matrix 框架管理
 */
- (void)setupPluginListener:(id<MatrixPluginListenerDelegate>)pluginListener {
    [super setupPluginListener:pluginListener];
}

/**
 * 上报问题（内部使用）
 * 
 * @param issue MatrixIssue 对象
 * 
 * 说明：
 * - 由 deplayTryReportOOMInfo 或 uploadReport 调用
 * - 会传递给 MatrixHandler 处理
 * - MatrixHandler 会上传到服务器
 */
- (void)reportIssue:(MatrixIssue *)issue {
    [super reportIssue:issue];
}

/**
 * 上报完成回调
 * 
 * @param issue 上报的问题
 * @param bSuccess 是否成功
 * 
 * 说明：
 * - 由 Matrix 框架在上报完成后调用
 * - 成功时：不做处理（记录由业务方决定是否删除）
 * - 失败时：保留记录，等待下次重试
 * 
 * 注意：
 * - Matrix 开源版本没有实现自动删除成功上报的记录
 * - 业务方需要在确认上报成功后手动调用 deleteRecord
 * - 或者在服务器确认收到后通过推送通知 App 删除
 */
- (void)reportIssueCompleteWithIssue:(MatrixIssue *)issue success:(BOOL)bSuccess {
    if (bSuccess) {
        MatrixInfo(@"report issue success: %@", issue);
    } else {
        MatrixInfo(@"report issue failed: %@", issue);
    }
    
    // 检查是否是内存统计插件的问题
    if ([issue.issueTag isEqualToString:[WCMemoryStatPlugin getTag]]) {
        if (bSuccess) {
            // ✅ 上报成功
            // TODO: 这里可以删除记录，释放磁盘空间
            // [self deleteRecord:...];
        } else {
            // ❌ 上报失败
            MatrixError(@"report issue failed, do not delete, %@", [WCMemoryStatPlugin getTag]);
            // 保留记录，下次启动时可能会重新上报
        }
    } else {
        MatrixInfo(@"the issue is not my duty");
    }
}

/**
 * 获取插件标识
 * 
 * @return 插件 Tag："MemoryStat"
 * 
 * 说明：
 * - 用于 MatrixIssue.issueTag
 * - MatrixHandler 根据 tag 判断问题类型
 * - "MemoryStat" 对应 OOM 报告
 */
+ (NSString *)getTag {
    return @g_matrix_memory_stat_plugin_tag;
}

@end
