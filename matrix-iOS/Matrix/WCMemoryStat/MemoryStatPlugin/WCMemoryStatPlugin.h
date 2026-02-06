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
 * WCMemoryStatPlugin.h - Matrix 内存统计插件公开接口
 * 
 * ============================================================================
 * 功能概述
 * ============================================================================
 * 
 * WCMemoryStatPlugin 是 Matrix 框架的内存监控插件，主要功能包括：
 * 
 * 1. FOOM (Foreground Out Of Memory) 检测
 *    - 实时记录内存分配到本地数据库
 *    - 自动检测并上报前台 OOM 问题
 * 
 * 2. 内存分配监控
 *    - 拦截 malloc/free 调用
 *    - 记录堆栈信息
 *    - 异步持久化到磁盘
 * 
 * 3. 内存快照
 *    - 支持手动触发内存 dump
 *    - 实时分析内存分布
 * 
 * ============================================================================
 * 快速开始
 * ============================================================================
 * 
 * // 1. 创建并配置插件
 * WCMemoryStatPlugin *memPlugin = [[WCMemoryStatPlugin alloc] init];
 * memPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
 * memPlugin.delegate = self;  // 实现 WCMemoryStatPluginDelegate
 * 
 * // 2. 安装到 Matrix
 * Matrix *matrix = [Matrix sharedInstance];
 * [matrix addPlugin:memPlugin];
 * 
 * // 3. 启动监控（通常在 applicationDidFinishLaunching 之后）
 * [memPlugin start];
 * 
 * // 4. （可选）手动上报
 * MemoryRecordInfo *lastRecord = [memPlugin recordOfLastRun];
 * if (lastRecord) {
 *     [memPlugin uploadReport:lastRecord withCustomInfo:@{@"user_id": @"12345"}];
 * }
 * 
 * // 5. （可选）实时内存快照
 * [memPlugin memoryDumpAndGenerateReportData:@"manual_dump" 
 *                                 customInfo:nil 
 *                                   callback:^(NSData *data) {
 *     // 处理快照数据
 * }];
 * 
 * ============================================================================
 * 注意事项
 * ============================================================================
 * 
 * 1. 性能影响：
 *    - 监控会拦截所有 malloc/free 调用，有一定性能开销
 *    - 建议在生产环境采样监控（如只监控 10% 用户）
 * 
 * 2. 磁盘空间：
 *    - 每次运行会生成约 10-50MB 的数据文件
 *    - 建议定期清理已上报的记录
 * 
 * 3. 调试环境：
 *    - 被调试器附加时不会启动（isBeingDebugged）
 *    - 测试时请使用真机 + Release 配置 + 不附加调试器
 * 
 * 4. 私有 API：
 *    - 使用 malloc_logger（准私有 API）
 *    - 已在微信等大型 App 中验证可以通过审核
 * 
 * ============================================================================
 */

#import "Matrix.h"

#import "WCMemoryStatConfig.h"
#import "WCMemoryStatModel.h"
#import "memory_stat_err_code.h"

@class WCMemoryStatPlugin;

// ============================================================================
#pragma mark - WCMemoryStatPluginDelegate
// ============================================================================

/**
 * WCMemoryStatPlugin 代理协议
 * 
 * 用于接收插件事件通知和提供自定义信息
 */
@protocol WCMemoryStatPluginDelegate <NSObject>

/**
 * 当插件发生错误时调用
 * 
 * @param plugin 插件实例
 * @param errCode 错误码，定义在 memory_stat_err_code.h
 * 
 * 常见错误码：
 * - MS_ERRC_SUCCESS (0): 成功
 * - MS_ERRC_OPEN_FILE_FAILED: 打开文件失败（可能是权限问题或磁盘空间不足）
 * - MS_ERRC_INIT_FAILED: 初始化失败
 * - MS_ERRC_MMAP_FAILED: 内存映射失败
 * - MS_ERRC_INVALID_PARAM: 无效参数
 * 
 * 使用示例：
 * - (void)onMemoryStatPlugin:(WCMemoryStatPlugin *)plugin hasError:(int)errCode {
 *     NSLog(@"❌ 内存监控错误: %d", errCode);
 *     if (errCode == MS_ERRC_OPEN_FILE_FAILED) {
 *         // 检查磁盘空间
 *     }
 * }
 */
- (void)onMemoryStatPlugin:(WCMemoryStatPlugin *)plugin hasError:(int)errCode;

/**
 * 获取自定义信息（用于添加到报告中）
 * 
 * @param plugin 插件实例
 * @return 自定义信息字典，将被添加到 OOM 报告的 customInfo 字段
 * 
 * 说明：
 * - 此方法在生成报告时调用
 * - 可以添加业务相关的上下文信息
 * - 所有值都会被转换为字符串
 * 
 * 使用示例：
 * - (NSDictionary *)onMemoryStatPluginGetCustomInfo:(WCMemoryStatPlugin *)plugin {
 *     return @{
 *         @"user_id": @"12345",
 *         @"page": @"home",
 *         @"memory_level": @(self.currentMemoryLevel),
 *         @"custom_tag": @"test_group_A"
 *     };
 * }
 */
- (NSDictionary *)onMemoryStatPluginGetCustomInfo:(WCMemoryStatPlugin *)plugin;

@end

// ============================================================================
#pragma mark - WCMemoryStatPlugin
// ============================================================================

/**
 * Matrix 内存统计插件
 * 
 * ============================================================================
 * 核心功能
 * ============================================================================
 * 
 * 1. 自动 FOOM 检测和上报
 *    - 实时记录内存分配到本地数据库
 *    - App 下次启动时自动检测是否发生 FOOM
 *    - 自动生成并上报 OOM 报告到服务器
 * 
 * 2. 内存分配监控
 *    - 通过 malloc_logger 拦截 malloc/free 调用
 *    - 记录分配地址、大小、堆栈、时间戳
 *    - 异步写入磁盘，最小化性能影响
 * 
 * 3. 手动内存快照
 *    - 支持随时触发 memory dump
 *    - 不等待 OOM，立即导出当前内存分布
 *    - 可用于调试和问题分析
 * 
 * 4. 历史记录管理
 *    - 查询所有历史记录
 *    - 手动上报历史记录
 *    - 清理已上报的记录
 * 
 * ============================================================================
 * 生命周期
 * ============================================================================
 * 
 * init → start (启动监控) → (运行中) → stop (停止监控) → destroy
 *          ↓
 *     enable_memory_logging
 *          ↓
 *     拦截 malloc/free
 *          ↓
 *     写入数据库
 *          ↓
 *     (发生 FOOM)
 *          ↓
 *     (下次启动)
 *          ↓
 *     检测 FOOM
 *          ↓
 *     自动上报
 * 
 * ============================================================================
 * 使用场景
 * ============================================================================
 * 
 * 场景 1：自动 OOM 监控（推荐）
 * ```objc
 * // AppDelegate.m
 * - (BOOL)application:(UIApplication *)application 
 *     didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
 *     
 *     WCMemoryStatPlugin *memPlugin = [[WCMemoryStatPlugin alloc] init];
 *     memPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
 *     memPlugin.delegate = self;
 *     
 *     [[Matrix sharedInstance] addPlugin:memPlugin];
 *     [memPlugin start];  // 自动检测和上报
 *     
 *     return YES;
 * }
 * ```
 * 
 * 场景 2：手动控制上报时机
 * ```objc
 * WCMemoryStatConfig *config = [WCMemoryStatConfig defaultConfiguration];
 * config.reportStrategy = EWCMemStatReportStrategy_Manual;  // 手动上报
 * memPlugin.pluginConfig = config;
 * [memPlugin start];
 * 
 * // 在合适的时机（如 WiFi 环境）手动上报
 * MemoryRecordInfo *record = [memPlugin recordOfLastRun];
 * if (record) {
 *     [memPlugin uploadReport:record withCustomInfo:@{@"scene": @"wifi"}];
 * }
 * ```
 * 
 * 场景 3：实时内存分析
 * ```objc
 * // 内存警告时触发内存快照
 * - (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
 *     [memPlugin memoryDumpAndGenerateReportData:@"memory_warning" 
 *                                     customInfo:nil 
 *                                       callback:^(NSData *data) {
 *         // 分析当前内存分布
 *         NSLog(@"Memory snapshot: %@", data);
 *     }];
 * }
 * ```
 * 
 * ============================================================================
 * 性能影响
 * ============================================================================
 * 
 * CPU 开销：
 * - malloc/free 拦截：每次分配增加约 0.5-2 微秒
 * - 堆栈回溯：每次分配增加约 10-50 微秒（取决于堆栈深度）
 * - 异步写入：后台线程，不阻塞主线程
 * 
 * 内存开销：
 * - 环形缓冲区：约 2-5 MB
 * - 堆栈缓存：约 1-3 MB
 * - inter_zone：约 1-2 MB
 * - 总计：约 5-10 MB
 * 
 * 磁盘开销：
 * - 每次运行约 10-50 MB（取决于分配次数）
 * - 建议定期清理
 * 
 * 优化建议：
 * - 生产环境采样监控（如 10% 用户）
 * - 使用 skip_min_malloc_size 过滤小分配
 * - 使用 skip_max_stack_depth 过滤浅堆栈
 * 
 * ============================================================================
 */
@interface WCMemoryStatPlugin : MatrixPlugin

/**
 * 插件配置
 * 
 * 说明：
 * - 必须在 start 之前设置
 * - 如果不设置，会使用默认配置
 * - 配置项包括：上报策略、过滤规则、堆栈深度等
 * 
 * 示例：
 * WCMemoryStatConfig *config = [WCMemoryStatConfig defaultConfiguration];
 * config.skipMinMallocSize = 30;     // 跳过小于 30 字节的分配
 * config.skipMaxStackDepth = 3;      // 跳过堆栈深度小于 3 的分配
 * config.reportStrategy = EWCMemStatReportStrategy_Auto;  // 自动上报
 * memPlugin.pluginConfig = config;
 */
@property (nonatomic, strong) WCMemoryStatConfig *pluginConfig;

/**
 * 插件代理
 * 
 * 说明：
 * - 用于接收错误通知
 * - 提供自定义信息（添加到报告中）
 * - 弱引用，避免循环引用
 */
@property (nonatomic, weak) id<WCMemoryStatPluginDelegate> delegate;

// ============================================================================
#pragma mark - Report（报告管理）
// ============================================================================

/**
 * 手动上报内存记录
 * 
 * @param record 要上报的记录（通常是 recordOfLastRun 或 recordByLaunchTime: 获取的）
 * @param customInfo 自定义信息字典，会添加到报告的 customInfo 字段
 * @return MatrixIssue 对象，如果失败返回 nil
 * 
 * 使用场景：
 * - reportStrategy 设置为 Manual 时，由业务方主动调用
 * - 可以选择合适的时机上报（如 WiFi 环境、后台空闲时）
 * - 可以添加更丰富的业务上下文信息
 * 
 * 工作流程：
 * 1. 从数据库读取内存分配记录
 * 2. 聚合数据（按堆栈分组，统计总大小）
 * 3. 生成 JSON 格式的报告
 * 4. 创建 MatrixIssue 对象
 * 5. 通过 MatrixHandler 上传到服务器
 * 
 * 使用示例：
 * ```objc
 * // 检查是否有 OOM 记录
 * MemoryRecordInfo *lastRecord = [memPlugin recordOfLastRun];
 * if (lastRecord) {
 *     // 在 WiFi 环境下上报
 *     if ([self isWiFiConnected]) {
 *         NSDictionary *customInfo = @{
 *             @"user_id": @"12345",
 *             @"page": @"home",
 *             @"network": @"wifi"
 *         };
 *         MatrixIssue *issue = [memPlugin uploadReport:lastRecord 
 *                                         withCustomInfo:customInfo];
 *         if (issue) {
 *             NSLog(@"✅ 上报成功");
 *         }
 *     }
 * }
 * ```
 * 
 * 注意事项：
 * - 上报操作有一定耗时（读取数据库、聚合数据），建议在后台线程调用
 * - 上报成功后需要手动调用 deleteRecord: 清理记录
 * - customInfo 中的所有值都会被转换为字符串
 */
- (MatrixIssue *)uploadReport:(MemoryRecordInfo *)record withCustomInfo:(NSDictionary *)customInfo;

/**
 * 实时生成内存快照并导出报告
 * 
 * @param issue 问题描述字符串（会作为 foom_scene 字段）
 * @param customInfo 自定义信息字典
 * @param callback 回调 block，在后台线程执行，接收生成的报告数据（JSON 格式）
 * 
 * 使用场景：
 * - 手动触发内存快照（调试、测试）
 * - 内存警告时主动导出当前状态
 * - 不等待 OOM，立即分析内存分布
 * - 性能问题排查
 * 
 * 与 uploadReport 的区别：
 * ┌──────────────────┬─────────────────┬──────────────────┐
 * │ 方法             │ 数据来源         │ 使用场景          │
 * ├──────────────────┼─────────────────┼──────────────────┤
 * │ uploadReport     │ 历史记录（磁盘） │ OOM 事后分析      │
 * │ memoryDump...    │ 当前记录（内存） │ 实时状态分析      │
 * └──────────────────┴─────────────────┴──────────────────┘
 * 
 * 工作流程：
 * 1. 检查 m_currRecord（必须正在监控）
 * 2. 准备报告参数（设备信息、时间戳等）
 * 3. 调用 C++ 层的 memory_dump() 函数
 * 4. memory_dump() 在后台线程生成报告
 * 5. 通过 memory_dump_callback() 回调返回数据
 * 6. 执行 callback block，将数据传回业务层
 * 
 * 使用示例：
 * ```objc
 * // 场景 1：内存警告时触发快照
 * - (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
 *     [memPlugin memoryDumpAndGenerateReportData:@"memory_warning" 
 *                                     customInfo:@{@"level": @"critical"} 
 *                                       callback:^(NSData *data) {
 *         // 在后台线程执行
 *         NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data 
 *                                                               options:0 
 *                                                                 error:nil];
 *         NSLog(@"📊 内存快照: %@", report);
 *         
 *         // 可以保存到本地或上传到服务器
 *         [self saveMemorySnapshot:data];
 *     }];
 * }
 * 
 * // 场景 2：手动分析按钮
 * - (IBAction)onAnalyzeMemoryButtonTapped:(id)sender {
 *     [memPlugin memoryDumpAndGenerateReportData:@"manual_analysis" 
 *                                     customInfo:nil 
 *                                       callback:^(NSData *data) {
 *         dispatch_async(dispatch_get_main_queue(), ^{
 *             // 展示分析结果
 *             [self showMemoryAnalysisResult:data];
 *         });
 *     }];
 * }
 * ```
 * 
 * 注意事项：
 * - 必须在 start() 之后调用（m_currRecord 不能为 nil）
 * - 生成报告有一定耗时（约 100-500ms），不要频繁调用
 * - callback 在后台线程执行，更新 UI 需要切换到主线程
 * - 不会自动上报，需要业务方决定是否上传
 */
- (void)memoryDumpAndGenerateReportData:(NSString *)issue customInfo:(NSDictionary *)customInfo callback:(void (^)(NSData *))callback;

// ============================================================================
#pragma mark - Record（记录管理）
// ============================================================================

/**
 * 获取所有内存记录列表
 * 
 * @return MemoryRecordInfo 数组，按时间倒序排列（最新的在前）
 * 
 * 说明：
 * - 从本地数据库读取所有记录
 * - 每条记录对应一次 App 运行
 * - 包含启动时间、系统版本、UUID 等元数据
 * - 不包含详细的分配数据（需要调用 uploadReport 时才会读取）
 * 
 * 使用示例：
 * ```objc
 * NSArray *records = [memPlugin recordList];
 * NSLog(@"📋 共有 %lu 条记录", records.count);
 * 
 * for (MemoryRecordInfo *record in records) {
 *     NSLog(@"记录 ID: %@, 启动时间: %@", 
 *           record.recordID, 
 *           [NSDate dateWithTimeIntervalSince1970:record.launchTime]);
 * }
 * ```
 */
- (NSArray *)recordList;

/**
 * 获取上次运行的记录
 * 
 * @return 上次的 MemoryRecordInfo，如果没有返回 nil
 * 
 * 说明：
 * - 如果上次是 FOOM，这条记录包含了导致 OOM 的内存分配信息
 * - 在 init 中自动加载
 * - deplayTryReportOOMInfo 会自动上报这条记录（如果是 FOOM）
 * - 上报成功后建议删除
 * 
 * 使用示例：
 * ```objc
 * MemoryRecordInfo *lastRecord = [memPlugin recordOfLastRun];
 * if (lastRecord) {
 *     if ([lastRecord.userScene isEqualToString:@"foreground"]) {
 *         NSLog(@"⚠️ 上次运行发生了前台 OOM");
 *         // 手动上报
 *         [memPlugin uploadReport:lastRecord withCustomInfo:nil];
 *     }
 * }
 * ```
 */
- (MemoryRecordInfo *)recordOfLastRun;

/**
 * 根据启动时间查询记录
 * 
 * @param launchTime App 启动时间戳（秒），由 MatrixAppRebootAnalyzer 提供
 * @return 对应的 MemoryRecordInfo，如果没有返回 nil
 * 
 * 说明：
 * - launchTime 是记录的唯一标识
 * - 可以查询任意历史记录
 * - 用于实现自定义的记录管理策略
 * 
 * 使用示例：
 * ```objc
 * // 查询特定时间的记录
 * uint64_t targetTime = 1704067200;  // 2024-01-01 00:00:00
 * MemoryRecordInfo *record = [memPlugin recordByLaunchTime:targetTime];
 * if (record) {
 *     NSLog(@"找到记录: %@", record.recordID);
 * }
 * ```
 */
- (MemoryRecordInfo *)recordByLaunchTime:(uint64_t)launchTime;

/**
 * 删除指定的内存记录
 * 
 * @param record 要删除的记录
 * 
 * 说明：
 * - 会删除数据库中的元数据
 * - 会删除磁盘上的数据文件：
 *   · allocation_event_db.dat（分配事件）
 *   · stack_frames_db.dat（堆栈信息）
 * - 释放磁盘空间（每条记录约 10-50 MB）
 * - 通常在上报成功后调用
 * 
 * 使用示例：
 * ```objc
 * // 上报成功后删除记录
 * MatrixIssue *issue = [memPlugin uploadReport:record withCustomInfo:nil];
 * if (issue) {
 *     [memPlugin deleteRecord:record];
 *     NSLog(@"✅ 记录已上报并删除");
 * }
 * 
 * // 或者删除过期记录（如 7 天前的）
 * NSArray *records = [memPlugin recordList];
 * uint64_t now = [[NSDate date] timeIntervalSince1970];
 * for (MemoryRecordInfo *record in records) {
 *     if (now - record.launchTime > 7 * 24 * 3600) {
 *         [memPlugin deleteRecord:record];
 *         NSLog(@"🗑️ 删除过期记录: %@", record.recordID);
 *     }
 * }
 * ```
 */
- (void)deleteRecord:(MemoryRecordInfo *)record;

/**
 * 删除所有内存记录
 * 
 * 说明：
 * - 清空本地数据库
 * - 删除所有数据文件
 * - 释放磁盘空间
 * - 不可恢复，请谨慎使用
 * 
 * 使用场景：
 * - 用户主动清理缓存
 * - 磁盘空间不足
 * - 重置调试状态
 * 
 * 使用示例：
 * ```objc
 * // 清理缓存
 * - (IBAction)onClearCacheButtonTapped:(id)sender {
 *     UIAlertController *alert = [UIAlertController 
 *         alertControllerWithTitle:@"确认" 
 *         message:@"是否删除所有内存记录？此操作不可恢复。" 
 *         preferredStyle:UIAlertControllerStyleAlert];
 *     
 *     [alert addAction:[UIAlertAction actionWithTitle:@"删除" 
 *                                               style:UIAlertActionStyleDestructive 
 *                                             handler:^(UIAlertAction *action) {
 *         [memPlugin deleteAllRecords];
 *         NSLog(@"🗑️ 已删除所有记录");
 *     }]];
 *     
 *     [alert addAction:[UIAlertAction actionWithTitle:@"取消" 
 *                                               style:UIAlertActionStyleCancel 
 *                                             handler:nil]];
 *     
 *     [self presentViewController:alert animated:YES completion:nil];
 * }
 * ```
 */
- (void)deleteAllRecords;

/**
 * 获取插件自身使用的内存大小
 * 
 * @return 内存大小（字节）
 * 
 * 说明：
 * - 统计的是 inter_zone 分配的内存
 * - inter_zone 是 Matrix 内部分配器，用于分配插件自身的数据结构
 * - 不包括监控的业务代码分配的内存
 * - 可用于评估插件的内存开销
 * 
 * 典型值：
 * - 启动后：约 5-10 MB
 * - 运行中：约 5-15 MB（取决于分配活跃度）
 * - 峰值：约 10-20 MB
 * 
 * 使用示例：
 * ```objc
 * // 监控插件的内存占用
 * - (void)checkPluginMemoryUsage {
 *     size_t memUsed = [memPlugin pluginMemoryUsed];
 *     NSLog(@"📊 插件内存占用: %.2f MB", memUsed / 1024.0 / 1024.0);
 *     
 *     if (memUsed > 20 * 1024 * 1024) {  // 超过 20 MB
 *         NSLog(@"⚠️ 插件内存占用过高");
 *     }
 * }
 * ```
 */
- (size_t)pluginMemoryUsed;

@end
