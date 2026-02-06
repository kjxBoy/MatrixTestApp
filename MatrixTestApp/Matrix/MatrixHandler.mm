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

#import "MatrixHandler.h"
#import <Matrix/WCCrashBlockFileHandler.h>
#import <Matrix/Matrix.h>
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "TextViewController.h"

void kscrash_crashCallback(const KSCrashReportWriter *writer)
{
    writer->beginObject(writer, "WeChat");
    writer->addUIntegerElement(writer, "uin", 21002);
    writer->endContainer(writer);
}

@interface MatrixHandler () <WCCrashBlockMonitorDelegate, MatrixAdapterDelegate, MatrixPluginListenerDelegate>
{
    WCCrashBlockMonitorPlugin *m_cbPlugin;
    WCMemoryStatPlugin *m_msPlugin;
}

// 日志上报相关
- (void)uploadReportToServer:(MatrixIssue *)issue;
- (void)uploadFileToServer:(NSString *)filePath withTitle:(NSString *)title;

@end

@implementation MatrixHandler

+ (MatrixHandler *)sharedInstance
{
    static MatrixHandler *g_handler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_handler = [[MatrixHandler alloc] init];
    });
    
    return g_handler;
}

/**
 * 初始化并启动 Matrix 监控框架
 * 
 * 功能：
 * 1. 配置崩溃和卡顿监控插件（WCCrashBlockMonitorPlugin）
 * 2. 配置内存监控插件（WCMemoryStatPlugin）
 * 3. 启动所有监控功能
 */
- (void)installMatrix
{
    // ============================================================================
    // 第一步：配置 Matrix 适配器（用于接收 Matrix 的日志输出）
    // ============================================================================
    [MatrixAdapter sharedInstance].delegate = self;
    
    Matrix *matrix = [Matrix sharedInstance];

    // ============================================================================
    // 第二步：创建插件构建器
    // ============================================================================
    MatrixBuilder *curBuilder = [[MatrixBuilder alloc] init];
    curBuilder.pluginListener = self;  // 设置监听器，接收插件上报的问题
    
    // ============================================================================
    // 第三步：配置崩溃和卡顿监控插件
    // ============================================================================
    WCCrashBlockMonitorConfig *crashBlockConfig = [[WCCrashBlockMonitorConfig alloc] init];
    crashBlockConfig.enableCrash = YES;              // 启用崩溃监控
    crashBlockConfig.enableBlockMonitor = YES;       // 启用卡顿监控
    crashBlockConfig.blockMonitorDelegate = self;    // 设置卡顿监控代理
    crashBlockConfig.onAppendAdditionalInfoCallBack = kscrash_crashCallback;  // 崩溃时的附加信息回调
    crashBlockConfig.reportStrategy = EWCCrashBlockReportStrategy_All;        // 上报策略：全部上报
    
    // 配置卡顿监控的详细参数
    WCBlockMonitorConfiguration *blockMonitorConfig = [WCBlockMonitorConfiguration defaultConfig];
    blockMonitorConfig.bMainThreadHandle = YES;              // 监控主线程
    blockMonitorConfig.bFilterSameStack = YES;               // 过滤相同堆栈
    blockMonitorConfig.triggerToBeFilteredCount = 10;        // 相同堆栈超过10次才触发过滤
    blockMonitorConfig.bGetPowerConsumeStack = YES;          // 获取耗电堆栈
    crashBlockConfig.blockMonitorConfiguration = blockMonitorConfig;
    
    // 创建崩溃和卡顿监控插件
    WCCrashBlockMonitorPlugin *crashBlockPlugin = [[WCCrashBlockMonitorPlugin alloc] init];
    crashBlockPlugin.pluginConfig = crashBlockConfig;
    [curBuilder addPlugin:crashBlockPlugin];
    
    // ============================================================================
    // 第四步：配置内存监控插件 ⭐ 核心
    // ============================================================================
    WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];
    memoryStatPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];  // 使用默认配置
    // 默认配置：
    // - skipMinMallocSize = PAGE_SIZE (16KB) - 小于此值的分配不记录堆栈
    // - skipMaxStackDepth = 8 - 堆栈前8层包含App代码时记录
    // - dumpCallStacks = 1 - dump所有对象的调用堆栈
    // - reportStrategy = Auto - 自动检测和上报FOOM
    [curBuilder addPlugin:memoryStatPlugin];
    
    // ============================================================================
    // 第五步：将插件添加到 Matrix 并启动
    // ============================================================================
    [matrix addMatrixBuilder:curBuilder];
    
    // 启动插件（开始监控）
    [crashBlockPlugin start];
    [memoryStatPlugin start];  // ⭐ 启动内存监控，会调用 C++ 层的 enable_memory_logging()
    
    // 保存插件引用，供外部访问
    m_cbPlugin = crashBlockPlugin;
    m_msPlugin = memoryStatPlugin;
}

- (WCCrashBlockMonitorPlugin *)getCrashBlockPlugin;
{
    return m_cbPlugin;
}

- (WCMemoryStatPlugin *)getMemoryStatPlugin
{
    return m_msPlugin;
}

- (NSString *)getLagLogPath
{
    // 构造日志路径: Library/Caches/Matrix/CrashBlock
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachePath = [paths firstObject];
    NSString *matrixPath = [cachePath stringByAppendingPathComponent:@"Matrix"];
    NSString *crashBlockPath = [matrixPath stringByAppendingPathComponent:@"CrashBlock"];
    return crashBlockPath;
}

// ============================================================================
#pragma mark - MatrixPluginListenerDelegate
// ============================================================================

/**
 * Matrix 插件上报问题的回调
 * 
 * 功能：
 * 1. 解析问题类型（崩溃/卡顿/OOM）
 * 2. 自动上报到符号化服务器
 * 3. 在 App 内展示问题详情
 * 
 * @param issue Matrix问题对象，包含问题类型、数据等信息
 */
- (void)onReportIssue:(MatrixIssue *)issue
{
    NSLog(@"📊 [Matrix] 获取到问题报告: %@", issue);
    
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    TextViewController *textVC = nil;
    
    NSString *currentTilte = @"未知";
    
    // ============================================================================
    // 第一步：判断问题类型并设置标题
    // ============================================================================
    
    // 1. 崩溃和卡顿问题
    if ([issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        if (issue.reportType == EMCrashBlockReportType_Lag) {
            // 卡顿问题 - 解析具体的卡顿类型
            NSMutableString *lagTitle = [@"卡顿" mutableCopy];
            if (issue.customInfo != nil) {
                NSString *dumpTypeDes = @"";
                NSNumber *dumpType = [issue.customInfo objectForKey:@g_crash_block_monitor_custom_dump_type];
                
                // 根据 dump 类型确定具体的卡顿原因
                switch (EDumpType(dumpType.integerValue)) {
                    case EDumpType_MainThreadBlock:
                        dumpTypeDes = @"前台主线程阻塞";
                        break;
                    case EDumpType_BackgroundMainThreadBlock:
                        dumpTypeDes = @"后台主线程阻塞";
                        break;
                    case EDumpType_CPUBlock:
                        dumpTypeDes = @"CPU 占用过高";
                        break;
                    case EDumpType_PowerConsume:
                        dumpTypeDes = @"耗电调用树";
                        break;
                    case EDumpType_LaunchBlock:
                        dumpTypeDes = @"启动时主线程阻塞";
                        break;
                    case EDumpType_BlockThreadTooMuch:
                        dumpTypeDes = @"阻塞且线程过多";
                        break;
                    case EDumpType_BlockAndBeKilled:
                        dumpTypeDes = @"被杀死前的主线程阻塞";
                        break;
                    default:
                        dumpTypeDes = [NSString stringWithFormat:@"%d", [dumpType intValue]];
                        break;
                }
                [lagTitle appendFormat:@" [%@]", dumpTypeDes];
            }
            currentTilte = [lagTitle copy];
        }
        if (issue.reportType == EMCrashBlockReportType_Crash) {
            currentTilte = @"崩溃";
        }
    }
    
    // 2. 内存溢出问题（OOM/FOOM）⭐
    if ([issue.issueTag isEqualToString:[WCMemoryStatPlugin getTag]]) {
        currentTilte = @"内存溢出信息";
        NSLog(@"📊 [Matrix] 检测到 OOM 报告");
    }
    
    // ============================================================================
    // 第二步：自动上报到服务器 🚀
    // ============================================================================
    // 上报到符号化服务器，进行堆栈符号化和分析
    [self uploadReportToServer:issue];
    
    // ============================================================================
    // 第三步：在 App 内展示问题详情
    // ============================================================================
    if (issue.dataType == EMatrixIssueDataType_Data) {
        // 数据在内存中（issue.issueData）
        NSString *dataString = [[NSString alloc] initWithData:issue.issueData encoding:NSUTF8StringEncoding];
        textVC = [[TextViewController alloc] initWithString:dataString withTitle:currentTilte];
    } else {
        // 数据在文件中（issue.filePath）
        textVC = [[TextViewController alloc] initWithFilePath:issue.filePath withTitle:currentTilte];
    }
    [appDelegate.navigationController pushViewController:textVC animated:YES];
    
    // ============================================================================
    // 第四步：通知 Matrix 问题已处理完成
    // ============================================================================
    [[Matrix sharedInstance] reportIssueComplete:issue success:YES];
    // 注意：调用此方法后，Matrix 会删除本地的问题数据文件
}

// ============================================================================
#pragma mark - WCCrashBlockMonitorDelegate
// ============================================================================

- (void)onCrashBlockMonitorBeginDump:(EDumpType)dumpType blockTime:(uint64_t)blockTime
{
    
}

- (void)onCrashBlockMonitorEnterNextCheckWithDumpType:(EDumpType)dumpType
{
    if (dumpType != EDumpType_MainThreadBlock || dumpType != EDumpType_BackgroundMainThreadBlock) {
    }
}

- (void)onCrashBlockMonitorDumpType:(EDumpType)dumpType filter:(EFilterType)filterType
{
    NSLog(@"已过滤的转储类型:%u, 过滤类型: %u", (uint32_t)dumpType, (uint32_t)filterType);
}

- (void)onCrashBlockMonitorDumpFilter:(EDumpType)dumpType
{
    
}

- (NSDictionary *)onCrashBlockMonitorGetCustomUserInfoForDumpType:(EDumpType)dumpType
{
    return nil;
}

// ============================================================================
#pragma mark - MatrixAdapterDelegate
// ============================================================================

- (BOOL)matrixShouldLog:(MXLogLevel)level
{
    return YES;
}

- (void)matrixLog:(MXLogLevel)logLevel
           module:(const char *)module
             file:(const char *)file
             line:(int)line
         funcName:(const char *)funcName
          message:(NSString *)message
{
    NSLog(@"%@:%@:%@:%@",
          [NSString stringWithUTF8String:module],[NSString stringWithUTF8String:file],[NSString stringWithUTF8String:funcName], message);
}

// ============================================================================
#pragma mark - 日志上报到服务器
// ============================================================================

/**
 * 上报问题到符号化服务器
 * 
 * 流程：
 * 1. 识别问题类型（lag/crash/oom）
 * 2. 读取报告数据
 * 3. 解析并上传到服务器
 * 
 * 服务器功能：
 * - 接收原始报告（带地址的堆栈）
 * - 使用 dSYM 进行符号化
 * - 生成可读的符号化报告
 * 
 * @param issue Matrix问题对象
 */
- (void)uploadReportToServer:(MatrixIssue *)issue
{
    NSString *reportType = @"unknown";
    
    // ============================================================================
    // 第一步：识别问题类型
    // ============================================================================
    
    if ([issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        // 崩溃和卡顿监控插件的报告
        if (issue.reportType == EMCrashBlockReportType_Lag) {
            reportType = @"lag";    // 卡顿报告
        } else if (issue.reportType == EMCrashBlockReportType_Crash) {
            reportType = @"crash";  // 崩溃报告
        }
    } else if ([issue.issueTag isEqualToString:[WCMemoryStatPlugin getTag]]) {
        // 内存监控插件的报告 ⭐
        reportType = @"oom";
        NSLog(@"📊 [Matrix] 检测到内存溢出报告，准备上报");
        // OOM 报告格式：
        // {
        //   "head": {protocol_ver, phone, os_ver, launch_time, ...},
        //   "items": [{name, size, count, stacks: [...]}]
        // }
    } else {
        // 未知类型，不上报
        NSLog(@"⚠️  [Matrix] 未知的问题类型: %@", issue.issueTag);
        return;
    }
    
    // ============================================================================
    // 第二步：获取报告数据
    // ============================================================================
    
    NSData *reportData = nil;
    
    if (issue.dataType == EMatrixIssueDataType_Data) {
        // 数据在内存中
        reportData = issue.issueData;
    } else if (issue.filePath) {
        // 数据在文件中
        reportData = [NSData dataWithContentsOfFile:issue.filePath];
    }
    
    if (!reportData || reportData.length == 0) {
        NSLog(@"❌ [Matrix] 日志上报失败：无效的报告数据");
        return;
    }
    
    // ============================================================================
    // 第三步：解析并上传
    // ============================================================================
    // 某些报告可能是数组格式（多个报告打包在一起）
    // 需要拆开逐个上传，以便服务端分别符号化
    [self parseAndUploadReports:reportData reportType:reportType];
}

/**
 * 解析报告数据并逐个上传
 * 
 * 为什么要拆分上传？
 * - 某些报告（如卡顿）可能包含多个事件，打包成数组
 * - 服务端需要分别符号化每个事件
 * - 拆分后便于管理和查看
 * 
 * @param reportData 原始报告数据（JSON格式）
 * @param reportType 报告类型（lag/crash/oom）
 */
- (void)parseAndUploadReports:(NSData *)reportData reportType:(NSString *)reportType
{
    // ============================================================================
    // 在后台线程处理，避免阻塞主线程
    // ============================================================================
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:reportData options:0 error:&error];
        
        if (error || !jsonObject) {
            NSLog(@"❌ [Matrix] JSON 解析失败: %@", error.localizedDescription);
            return;
        }
        
        NSArray *reportsArray = nil;
        
        // ============================================================================
        // 第一步：判断数据格式（数组 or 字典）
        // ============================================================================
        
        if ([jsonObject isKindOfClass:[NSArray class]]) {
            // 格式1: 数组 - 多个报告
            // 例如：[{report1}, {report2}, {report3}]
            reportsArray = (NSArray *)jsonObject;
            NSLog(@"📦 [Matrix] 检测到数组格式，共 %lu 个报告", (unsigned long)reportsArray.count);
        } else if ([jsonObject isKindOfClass:[NSDictionary class]]) {
            // 格式2: 字典 - 单个报告
            // 例如：{head: {...}, items: [...]}
            // 包装成数组，统一处理
            reportsArray = @[jsonObject];
            NSLog(@"📦 [Matrix] 检测到字典格式，转换为包含 1 个报告的数组");
        } else {
            NSLog(@"❌ [Matrix] 未知的 JSON 格式");
            return;
        }
        
        // ============================================================================
        // 第二步：遍历数组，逐个上传
        // ============================================================================
        
        for (NSInteger i = 0; i < reportsArray.count; i++) {
            id reportItem = reportsArray[i];
            
            // 验证每个报告项是字典
            if (![reportItem isKindOfClass:[NSDictionary class]]) {
                NSLog(@"⚠️  [Matrix] 跳过第 %ld 个报告：不是字典格式", (long)(i + 1));
                continue;
            }
            
            // 将字典转换为 JSON 数据（美化格式，便于阅读）
            NSError *serializationError = nil;
            NSData *singleReportData = [NSJSONSerialization dataWithJSONObject:reportItem 
                                                                       options:NSJSONWritingPrettyPrinted 
                                                                         error:&serializationError];
            
            if (serializationError || !singleReportData) {
                NSLog(@"❌ [Matrix] 第 %ld 个报告序列化失败: %@", (long)(i + 1), serializationError.localizedDescription);
                continue;
            }
            
            // 生成唯一文件名
            // 格式：{type}_report_{index}_{timestamp}.json
            // 例如：oom_report_1_1704268800.json
            NSString *fileName = [NSString stringWithFormat:@"%@_report_%ld_%@.json", 
                                 reportType, 
                                 (long)(i + 1), 
                                 @((long)[[NSDate date] timeIntervalSince1970])];
            
            NSLog(@"📤 [Matrix] 上传第 %ld/%lu 个报告: %@", (long)(i + 1), (unsigned long)reportsArray.count, fileName);
            
            // 执行上传
            [self performUploadWithData:singleReportData fileName:fileName reportType:reportType];
            
            // 避免请求过快，给服务器一点处理时间
            if (i < reportsArray.count - 1) {
                [NSThread sleepForTimeInterval:0.5];
            }
        }
        
        NSLog(@"✅ [Matrix] 所有报告上传完成：共 %lu 个", (unsigned long)reportsArray.count);
    });
}

/**
 * 执行实际的文件上传
 * 
 * 使用 multipart/form-data 格式上传文件到符号化服务器
 * 
 * 服务器端点：POST /api/report/upload
 * 
 * 响应格式：
 * {
 *   "message": "报告上传成功",
 *   "report_id": "1704268800123456789",
 *   "filename": "oom_report_1_1704268800.json"
 * }
 * 
 * @param reportData 报告的 JSON 数据
 * @param fileName 文件名
 * @param reportType 报告类型（用于日志）
 */
- (void)performUploadWithData:(NSData *)reportData fileName:(NSString *)fileName reportType:(NSString *)reportType
{
    // ============================================================================
    // 第一步：确定服务器地址
    // ============================================================================
    
    NSString *serverHost = @"http://localhost:8080";
    
#if TARGET_OS_SIMULATOR
    // 模拟器：使用 localhost
    serverHost = @"http://localhost:8080";
#else
    // 真机：需要使用 Mac 的局域网 IP
    // 方式1: 从 Info.plist 读取配置
    serverHost = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MatrixServerURL"];
    
    // 方式2: 使用默认值（需要根据实际网络修改）
    if (!serverHost) {
        serverHost = @"http://192.168.1.100:8080";
        NSLog(@"⚠️  [Matrix] 使用默认服务器地址: %@", serverHost);
        NSLog(@"   提示: 可在 Info.plist 中配置 MatrixServerURL 键");
    }
#endif
    
    NSString *uploadURL = [serverHost stringByAppendingString:@"/api/report/upload"];
    
    NSLog(@"📤 [Matrix] 开始上报日志到服务器: %@", uploadURL);
    NSLog(@"   文件名: %@", fileName);
    NSLog(@"   大小: %.2f KB", reportData.length / 1024.0);
    
    // ============================================================================
    // 第二步：构建 multipart/form-data 请求
    // ============================================================================
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadURL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    
    // 生成唯一的分隔符（boundary）
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    
    // 构建请求体
    NSMutableData *body = [NSMutableData data];
    
    // 添加文件数据部分
    // multipart/form-data 格式：
    // --boundary
    // Content-Disposition: form-data; name="file"; filename="xxx.json"
    // Content-Type: application/json
    //
    // {JSON数据}
    // --boundary--
    
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", fileName] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: application/json\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:reportData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    
    // 结束标记
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    request.HTTPBody = body;
    
    // ============================================================================
    // 第三步：发送请求
    // ============================================================================
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        
        // 处理网络错误
        if (error) {
            NSLog(@"❌ [Matrix] 日志上报失败: %@", error.localizedDescription);
            NSLog(@"   提示: 请确保符号化服务正在运行");
            NSLog(@"   启动命令: cd matrix-symbolicate-server && ./start.sh");
            return;
        }
        
        // 处理 HTTP 响应
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 200) {
            NSLog(@"✅ [Matrix] 日志上报成功！");
            
            // 解析服务器响应
            if (data) {
                NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *reportId = result[@"report_id"];
                if (reportId) {
                    NSLog(@"   📋 报告 ID: %@", reportId);
                    NSLog(@"   🌐 查看地址: %@/#reports", serverHost);
                    NSLog(@"   💡 符号化将在服务端自动进行");
                    NSLog(@"   💡 上传对应的 dSYM 文件后即可查看符号化结果");
                }
            }
        } else {
            NSLog(@"❌ [Matrix] 日志上报失败: HTTP %ld", (long)httpResponse.statusCode);
            if (data) {
                NSString *responseStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSLog(@"   响应: %@", responseStr);
            }
        }
    }];
    
    [task resume];
}

- (void)uploadFileToServer:(NSString *)filePath withTitle:(NSString *)title
{
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSLog(@"❌ 文件不存在: %@", filePath);
        return;
    }
    
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    NSString *fileName = [filePath lastPathComponent];
    
    [self performUploadWithData:fileData fileName:fileName reportType:title ?: @"manual"];
}

@end
