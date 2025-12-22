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

- (void)installMatrix
{
    // Get Matrix's log
    [MatrixAdapter sharedInstance].delegate = self;
    
    Matrix *matrix = [Matrix sharedInstance];

    MatrixBuilder *curBuilder = [[MatrixBuilder alloc] init];
    curBuilder.pluginListener = self;
    
    WCCrashBlockMonitorConfig *crashBlockConfig = [[WCCrashBlockMonitorConfig alloc] init];
    crashBlockConfig.enableCrash = YES;
    crashBlockConfig.enableBlockMonitor = YES;
    crashBlockConfig.blockMonitorDelegate = self;
    crashBlockConfig.onAppendAdditionalInfoCallBack = kscrash_crashCallback;
    crashBlockConfig.reportStrategy = EWCCrashBlockReportStrategy_All;
    
    WCBlockMonitorConfiguration *blockMonitorConfig = [WCBlockMonitorConfiguration defaultConfig];
    blockMonitorConfig.bMainThreadHandle = YES;
    blockMonitorConfig.bFilterSameStack = YES;
    blockMonitorConfig.triggerToBeFilteredCount = 10;
    blockMonitorConfig.bGetPowerConsumeStack = YES;
    crashBlockConfig.blockMonitorConfiguration = blockMonitorConfig;
    
    WCCrashBlockMonitorPlugin *crashBlockPlugin = [[WCCrashBlockMonitorPlugin alloc] init];
    crashBlockPlugin.pluginConfig = crashBlockConfig;
    [curBuilder addPlugin:crashBlockPlugin];
    
    WCMemoryStatPlugin *memoryStatPlugin = [[WCMemoryStatPlugin alloc] init];
    memoryStatPlugin.pluginConfig = [WCMemoryStatConfig defaultConfiguration];
    [curBuilder addPlugin:memoryStatPlugin];
    
    [matrix addMatrixBuilder:curBuilder];
    
    [crashBlockPlugin start];
    [memoryStatPlugin start];
    
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

- (void)onReportIssue:(MatrixIssue *)issue
{
    NSLog(@"获取问题: %@", issue);
    
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    TextViewController *textVC = nil;
    
    NSString *currentTilte = @"未知";
    
    if ([issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        if (issue.reportType == EMCrashBlockReportType_Lag) {
            NSMutableString *lagTitle = [@"卡顿" mutableCopy];
            if (issue.customInfo != nil) {
                NSString *dumpTypeDes = @"";
                NSNumber *dumpType = [issue.customInfo objectForKey:@g_crash_block_monitor_custom_dump_type];
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
    
    if ([issue.issueTag isEqualToString:[WCMemoryStatPlugin getTag]]) {
        currentTilte = @"内存溢出信息";
    }
    
    // 🚀 自动上报到服务器
    [self uploadReportToServer:issue];
    
    if (issue.dataType == EMatrixIssueDataType_Data) {
        NSString *dataString = [[NSString alloc] initWithData:issue.issueData encoding:NSUTF8StringEncoding];
        textVC = [[TextViewController alloc] initWithString:dataString withTitle:currentTilte];
    } else {
        textVC = [[TextViewController alloc] initWithFilePath:issue.filePath withTitle:currentTilte];
    }
    [appDelegate.navigationController pushViewController:textVC animated:YES];
    
    [[Matrix sharedInstance] reportIssueComplete:issue success:YES];
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

- (void)uploadReportToServer:(MatrixIssue *)issue
{
    // 只上报卡顿和崩溃日志
    if (![issue.issueTag isEqualToString:[WCCrashBlockMonitorPlugin getTag]]) {
        return;
    }
    
    NSString *reportType = @"unknown";
    if (issue.reportType == EMCrashBlockReportType_Lag) {
        reportType = @"lag";
    } else if (issue.reportType == EMCrashBlockReportType_Crash) {
        reportType = @"crash";
    }
    
    // 获取报告数据
    NSData *reportData = nil;
    
    if (issue.dataType == EMatrixIssueDataType_Data) {
        reportData = issue.issueData;
    } else if (issue.filePath) {
        reportData = [NSData dataWithContentsOfFile:issue.filePath];
    }
    
    if (!reportData || reportData.length == 0) {
        NSLog(@"❌ 日志上报失败：无效的报告数据");
        return;
    }
    
    // 🔄 解析并遍历数组，逐个上传
    [self parseAndUploadReports:reportData reportType:reportType];
}

- (void)parseAndUploadReports:(NSData *)reportData reportType:(NSString *)reportType
{
    // 在后台处理
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:reportData options:0 error:&error];
        
        if (error || !jsonObject) {
            NSLog(@"❌ JSON 解析失败: %@", error.localizedDescription);
            return;
        }
        
        NSArray *reportsArray = nil;
        
        // 判断是数组还是字典
        if ([jsonObject isKindOfClass:[NSArray class]]) {
            reportsArray = (NSArray *)jsonObject;
            NSLog(@"📦 检测到数组格式，共 %lu 个报告", (unsigned long)reportsArray.count);
        } else if ([jsonObject isKindOfClass:[NSDictionary class]]) {
            // 如果是单个字典，包装成数组
            reportsArray = @[jsonObject];
            NSLog(@"📦 检测到字典格式，转换为包含 1 个报告的数组");
        } else {
            NSLog(@"❌ 未知的 JSON 格式");
            return;
        }
        
        // 遍历数组，逐个上传
        for (NSInteger i = 0; i < reportsArray.count; i++) {
            id reportItem = reportsArray[i];
            
            if (![reportItem isKindOfClass:[NSDictionary class]]) {
                NSLog(@"⚠️  跳过第 %ld 个报告：不是字典格式", (long)(i + 1));
                continue;
            }
            
            // 将字典转换为 JSON 数据
            NSError *serializationError = nil;
            NSData *singleReportData = [NSJSONSerialization dataWithJSONObject:reportItem 
                                                                       options:NSJSONWritingPrettyPrinted 
                                                                         error:&serializationError];
            
            if (serializationError || !singleReportData) {
                NSLog(@"❌ 第 %ld 个报告序列化失败: %@", (long)(i + 1), serializationError.localizedDescription);
                continue;
            }
            
            // 生成文件名
            NSString *fileName = [NSString stringWithFormat:@"%@_report_%ld_%@.json", 
                                 reportType, 
                                 (long)(i + 1), 
                                 @((long)[[NSDate date] timeIntervalSince1970])];
            
            NSLog(@"📤 上传第 %ld/%lu 个报告: %@", (long)(i + 1), (unsigned long)reportsArray.count, fileName);
            
            // 上传单个报告
            [self performUploadWithData:singleReportData fileName:fileName reportType:reportType];
            
            // 避免请求过快，稍微延迟
            if (i < reportsArray.count - 1) {
                [NSThread sleepForTimeInterval:0.5];
            }
        }
        
        NSLog(@"✅ 所有报告上传完成：共 %lu 个", (unsigned long)reportsArray.count);
    });
}

- (void)performUploadWithData:(NSData *)reportData fileName:(NSString *)fileName reportType:(NSString *)reportType
{
    // 服务器地址（默认本地）
    // 注意：如果是真机测试，需要改为 Mac 的 IP 地址
    NSString *serverHost = @"http://localhost:8080";
    
    // 如果是模拟器，检测是否能连接到本地服务器
    // 如果是真机，需要使用 Mac 的 IP 地址，例如: http://192.168.1.100:8080
#if TARGET_OS_SIMULATOR
    serverHost = @"http://localhost:8080";
#else
    // 真机环境，尝试使用常见的局域网地址
    // 实际使用时，建议在 Info.plist 中配置服务器地址
    serverHost = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MatrixServerURL"];
    if (!serverHost) {
        serverHost = @"http://192.168.1.100:8080"; // 默认值，需要根据实际修改
    }
#endif
    
    NSString *uploadURL = [serverHost stringByAppendingString:@"/api/report/upload"];
    
    NSLog(@"📤 开始上报日志到服务器: %@", uploadURL);
    NSLog(@"   文件名: %@", fileName);
    NSLog(@"   大小: %.2f KB", reportData.length / 1024.0);
    
    // 构建 multipart/form-data 请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadURL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    
    // 生成分隔符
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    
    // 构建请求体
    NSMutableData *body = [NSMutableData data];
    
    // 添加文件数据
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", fileName] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: application/json\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:reportData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    
    // 结束标记
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    request.HTTPBody = body;
    
    // 发送请求
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"❌ 日志上报失败: %@", error.localizedDescription);
            NSLog(@"   提示: 请确保符号化服务正在运行 (./start.sh)");
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 200) {
            NSLog(@"✅ 日志上报成功！");
            
            // 解析响应
            if (data) {
                NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *reportId = result[@"report_id"];
                if (reportId) {
                    NSLog(@"   报告 ID: %@", reportId);
                    NSLog(@"   查看地址: %@/#reports", serverHost);
                    NSLog(@"   💡 符号化将在服务端自动进行");
                }
            }
        } else {
            NSLog(@"❌ 日志上报失败: HTTP %ld", (long)httpResponse.statusCode);
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
