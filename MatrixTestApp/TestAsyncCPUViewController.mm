//
//  TestAsyncCPUViewController.mm
//  MatrixTestApp
//
//  异步CPU耗电测试实现
//

#import "TestAsyncCPUViewController.h"
#import <Accelerate/Accelerate.h>

@interface TestAsyncCPUViewController ()

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *scenario1Button;
@property (nonatomic, strong) UIButton *scenario2Button;
@property (nonatomic, strong) UIButton *scenario3Button;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, assign) BOOL isRunning;

@end

@implementation TestAsyncCPUViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"异步CPU耗电测试";
    self.isRunning = NO;
    
    [self setupUI];
}

- (void)setupUI {
    // 标题
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, self.view.bounds.size.width - 40, 80)];
    self.titleLabel.text = @"异步堆栈CPU过高测试\n模拟GCD异步任务耗电";
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.view addSubview:self.titleLabel];
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 200, self.view.bounds.size.width - 40, 60)];
    self.statusLabel.text = @"等待测试...";
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor grayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:self.statusLabel];
    
    // 场景1：单层异步（主线程 -> dispatch_async）
    self.scenario1Button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scenario1Button.frame = CGRectMake(20, 280, self.view.bounds.size.width - 40, 50);
    [self.scenario1Button setTitle:@"场景1: 单层异步CPU密集任务" forState:UIControlStateNormal];
    self.scenario1Button.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
    [self.scenario1Button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.scenario1Button.layer.cornerRadius = 8;
    [self.scenario1Button addTarget:self action:@selector(testScenario1) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.scenario1Button];
    
    // 场景2：多层异步（主线程 -> async -> async）
    self.scenario2Button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scenario2Button.frame = CGRectMake(20, 350, self.view.bounds.size.width - 40, 50);
    [self.scenario2Button setTitle:@"场景2: 多层嵌套异步任务" forState:UIControlStateNormal];
    self.scenario2Button.backgroundColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0];
    [self.scenario2Button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.scenario2Button.layer.cornerRadius = 8;
    [self.scenario2Button addTarget:self action:@selector(testScenario2) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.scenario2Button];
    
    // 场景3：多个并发异步任务
    self.scenario3Button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scenario3Button.frame = CGRectMake(20, 420, self.view.bounds.size.width - 40, 50);
    [self.scenario3Button setTitle:@"场景3: 多个并发异步任务" forState:UIControlStateNormal];
    self.scenario3Button.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.4 alpha:1.0];
    [self.scenario3Button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.scenario3Button.layer.cornerRadius = 8;
    [self.scenario3Button addTarget:self action:@selector(testScenario3) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.scenario3Button];
    
    // 停止按钮
    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.stopButton.frame = CGRectMake(20, 490, self.view.bounds.size.width - 40, 50);
    [self.stopButton setTitle:@"停止所有测试" forState:UIControlStateNormal];
    self.stopButton.backgroundColor = [UIColor redColor];
    [self.stopButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.stopButton.layer.cornerRadius = 8;
    [self.stopButton addTarget:self action:@selector(stopAllTests) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.stopButton];
    
    // 说明文本
    UITextView *descriptionTextView = [[UITextView alloc] initWithFrame:CGRectMake(20, 560, self.view.bounds.size.width - 40, 200)];
    descriptionTextView.text = @"📝 测试说明：\n\n"
                                "• 场景1：模拟ViewController发起异步图像处理\n"
                                "• 场景2：模拟异步任务中再次发起异步任务\n"
                                "• 场景3：模拟多个服务并发执行耗电操作\n\n"
                                "⚠️ 当前限制：\n"
                                "堆栈中只能看到异步线程的执行位置，\n"
                                "无法追溯到发起异步任务的原始调用者。\n\n"
                                "等待60秒后查看Matrix耗电报告。";
    descriptionTextView.font = [UIFont systemFontOfSize:12];
    descriptionTextView.textColor = [UIColor darkGrayColor];
    descriptionTextView.editable = NO;
    descriptionTextView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    descriptionTextView.layer.cornerRadius = 8;
    [self.view addSubview:descriptionTextView];
}

// ============================================================================
#pragma mark - 场景1：单层异步CPU密集任务
// ============================================================================

/**
 * 场景1：主线程通过dispatch_async发起单个异步任务
 * 
 * 调用链：
 * [ViewController testScenario1]  ← 发起者（希望在堆栈中看到）
 *   └─> dispatch_async
 *       └─> [self performHeavyImageProcessing]  ← 执行者（当前只能看到这里）
 * 
 * 期望堆栈：
 * - Thread #X (CPU 85%)
 *   #0 vImageConvolve_ARGB8888 (执行位置)
 *   #1 performHeavyImageProcessing (异步任务)
 *   --- 异步分界线 ---
 *   #2 testScenario1 (发起者) ← 当前看不到
 *   #3 buttonAction (发起者) ← 当前看不到
 */
- (void)testScenario1 {
    if (self.isRunning) {
        [self showAlert:@"测试已在运行中，请先停止"];
        return;
    }
    
    self.isRunning = YES;
    self.statusLabel.text = @"场景1运行中...\n单层异步任务正在消耗CPU";
    NSLog(@"[AsyncCPU] 场景1开始: 主线程=%@", [NSThread currentThread]);
    
    // 主线程发起异步任务
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"[AsyncCPU] 场景1异步线程开始: %@", [NSThread currentThread]);
        
        // 执行CPU密集型任务（持续90秒）
        [self performHeavyImageProcessingWithDuration:90 taskName:@"场景1-图像处理"];
    });
}

// ============================================================================
#pragma mark - 场景2：多层嵌套异步任务
// ============================================================================

/**
 * 场景2：主线程 -> 异步任务1 -> 异步任务2 -> CPU密集操作
 * 
 * 调用链：
 * [ViewController testScenario2]
 *   └─> dispatch_async (第一层)
 *       └─> [self processDataInBackground]
 *           └─> dispatch_async (第二层)
 *               └─> [self performHeavyCalculation]
 * 
 * 期望堆栈：
 * - Thread #X (CPU 90%)
 *   #0 performHeavyCalculation (最内层执行)
 *   --- 异步分界线 ---
 *   #1 processDataInBackground (第一层异步)
 *   --- 异步分界线 ---
 *   #2 testScenario2 (发起者)
 */
- (void)testScenario2 {
    if (self.isRunning) {
        [self showAlert:@"测试已在运行中，请先停止"];
        return;
    }
    
    self.isRunning = YES;
    self.statusLabel.text = @"场景2运行中...\n多层嵌套异步任务";
    NSLog(@"[AsyncCPU] 场景2开始: 主线程=%@", [NSThread currentThread]);
    
    // 第一层异步
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[AsyncCPU] 场景2第一层异步: %@", [NSThread currentThread]);
        [self processDataInBackground];
    });
}

- (void)processDataInBackground {
    // 模拟数据处理
    sleep(2);
    NSLog(@"[AsyncCPU] 场景2准备发起第二层异步...");
    
    // 第二层异步
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"[AsyncCPU] 场景2第二层异步开始: %@", [NSThread currentThread]);
        
        // 执行CPU密集型计算
        [self performHeavyCalculationWithDuration:90 taskName:@"场景2-嵌套计算"];
    });
}

// ============================================================================
#pragma mark - 场景3：多个并发异步任务
// ============================================================================

/**
 * 场景3：主线程同时发起多个异步任务
 * 
 * 调用链：
 * [ViewController testScenario3]
 *   ├─> dispatch_async -> [NetworkService syncData]
 *   ├─> dispatch_async -> [ImageService processImages]
 *   └─> dispatch_async -> [DataService analyzeData]
 * 
 * 期望堆栈：
 * - Thread #X (CPU 30%)
 *   #0 syncData
 *   --- 异步分界线 ---
 *   #1 testScenario3
 * 
 * - Thread #Y (CPU 35%)
 *   #0 processImages
 *   --- 异步分界线 ---
 *   #1 testScenario3
 * 
 * - Thread #Z (CPU 40%)
 *   #0 analyzeData
 *   --- 异步分界线 ---
 *   #1 testScenario3
 */
- (void)testScenario3 {
    if (self.isRunning) {
        [self showAlert:@"测试已在运行中，请先停止"];
        return;
    }
    
    self.isRunning = YES;
    self.statusLabel.text = @"场景3运行中...\n3个并发异步任务正在执行";
    NSLog(@"[AsyncCPU] 场景3开始: 主线程=%@", [NSThread currentThread]);
    
    // 并发任务1：模拟网络数据同步
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[AsyncCPU] 场景3-任务1(NetworkService): %@", [NSThread currentThread]);
        [self simulateNetworkServiceSyncData];
    });
    
    // 并发任务2：模拟图像处理服务
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[AsyncCPU] 场景3-任务2(ImageService): %@", [NSThread currentThread]);
        [self simulateImageServiceProcessing];
    });
    
    // 并发任务3：模拟数据分析服务
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"[AsyncCPU] 场景3-任务3(DataService): %@", [NSThread currentThread]);
        [self simulateDataServiceAnalysis];
    });
}

// 模拟NetworkService的数据同步
- (void)simulateNetworkServiceSyncData {
    [self performHeavyCalculationWithDuration:90 taskName:@"NetworkService.syncData"];
}

// 模拟ImageService的图像处理
- (void)simulateImageServiceProcessing {
    [self performHeavyImageProcessingWithDuration:90 taskName:@"ImageService.processImages"];
}

// 模拟DataService的数据分析
- (void)simulateDataServiceAnalysis {
    [self performHeavyMatrixOperationWithDuration:90 taskName:@"DataService.analyzeData"];
}

// ============================================================================
#pragma mark - CPU密集型操作实现
// ============================================================================

/**
 * CPU密集操作1：图像卷积处理
 * 使用Accelerate框架的vImage进行大量图像处理
 */
- (void)performHeavyImageProcessingWithDuration:(NSTimeInterval)duration taskName:(NSString *)taskName {
    NSLog(@"[AsyncCPU] %@ 开始 (预计运行%.0f秒)", taskName, duration);
    NSDate *startTime = [NSDate date];
    
    // 创建大图像进行处理
    size_t width = 2000;
    size_t height = 2000;
    size_t bytesPerRow = width * 4;
    
    uint8_t *inputBuffer = (uint8_t *)malloc(height * bytesPerRow);
    uint8_t *outputBuffer = (uint8_t *)malloc(height * bytesPerRow);
    
    // 填充随机数据
    for (int i = 0; i < height * bytesPerRow; i++) {
        inputBuffer[i] = arc4random_uniform(256);
    }
    
    vImage_Buffer input = {
        .data = inputBuffer,
        .height = height,
        .width = width,
        .rowBytes = bytesPerRow
    };
    
    vImage_Buffer output = {
        .data = outputBuffer,
        .height = height,
        .width = width,
        .rowBytes = bytesPerRow
    };
    
    // 5x5高斯模糊卷积核
    int16_t kernel[25] = {
        1, 4, 7, 4, 1,
        4, 16, 26, 16, 4,
        7, 26, 41, 26, 7,
        4, 16, 26, 16, 4,
        1, 4, 7, 4, 1
    };
    
    int32_t divisor = 273;
    
    // 持续执行卷积操作
    int iterations = 0;
    while (self.isRunning && [[NSDate date] timeIntervalSinceDate:startTime] < duration) {
        vImageConvolve_ARGB8888(&input, &output, NULL, 0, 0, kernel, 5, 5, divisor, NULL, kvImageNoFlags);
        iterations++;
        
        // 每1000次迭代交换缓冲区
        if (iterations % 1000 == 0) {
            void *temp = input.data;
            input.data = output.data;
            output.data = temp;
            
            NSLog(@"[AsyncCPU] %@ 已执行%d次卷积 (%.1f秒)", 
                  taskName, iterations, [[NSDate date] timeIntervalSinceDate:startTime]);
        }
    }
    
    free(inputBuffer);
    free(outputBuffer);
    
    NSLog(@"[AsyncCPU] %@ 结束 (共执行%d次卷积, 耗时%.1f秒)", 
          taskName, iterations, [[NSDate date] timeIntervalSinceDate:startTime]);
}

/**
 * CPU密集操作2：大数运算
 * 执行大量浮点数计算
 */
- (void)performHeavyCalculationWithDuration:(NSTimeInterval)duration taskName:(NSString *)taskName {
    NSLog(@"[AsyncCPU] %@ 开始 (预计运行%.0f秒)", taskName, duration);
    NSDate *startTime = [NSDate date];
    
    long long iterations = 0;
    double result = 0.0;
    
    while (self.isRunning && [[NSDate date] timeIntervalSinceDate:startTime] < duration) {
        // 执行大量浮点运算
        for (int i = 0; i < 100000; i++) {
            result += sqrt(i) * sin(i) * cos(i);
            result += pow(i, 0.5) * tan(i / 100.0);
            result += log(i + 1) * exp(i / 10000.0);
        }
        iterations++;
        
        if (iterations % 100 == 0) {
            NSLog(@"[AsyncCPU] %@ 已执行%lld轮计算 (%.1f秒)", 
                  taskName, iterations, [[NSDate date] timeIntervalSinceDate:startTime]);
        }
    }
    
    NSLog(@"[AsyncCPU] %@ 结束 (result=%.2f, 耗时%.1f秒)", 
          taskName, result, [[NSDate date] timeIntervalSinceDate:startTime]);
}

/**
 * CPU密集操作3：矩阵运算
 * 使用Accelerate框架进行大矩阵乘法
 */
- (void)performHeavyMatrixOperationWithDuration:(NSTimeInterval)duration taskName:(NSString *)taskName {
    NSLog(@"[AsyncCPU] %@ 开始 (预计运行%.0f秒)", taskName, duration);
    NSDate *startTime = [NSDate date];
    
    int size = 500;
    float *matrixA = (float *)malloc(size * size * sizeof(float));
    float *matrixB = (float *)malloc(size * size * sizeof(float));
    float *matrixC = (float *)malloc(size * size * sizeof(float));
    
    // 初始化矩阵
    for (int i = 0; i < size * size; i++) {
        matrixA[i] = (float)arc4random() / UINT32_MAX;
        matrixB[i] = (float)arc4random() / UINT32_MAX;
    }
    
    int iterations = 0;
    while (self.isRunning && [[NSDate date] timeIntervalSinceDate:startTime] < duration) {
        // 执行矩阵乘法: C = A * B
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                   size, size, size, 1.0f, matrixA, size, matrixB, size, 0.0f, matrixC, size);
        iterations++;
        
        if (iterations % 10 == 0) {
            NSLog(@"[AsyncCPU] %@ 已执行%d次矩阵乘法 (%.1f秒)", 
                  taskName, iterations, [[NSDate date] timeIntervalSinceDate:startTime]);
        }
    }
    
    free(matrixA);
    free(matrixB);
    free(matrixC);
    
    NSLog(@"[AsyncCPU] %@ 结束 (共执行%d次矩阵乘法, 耗时%.1f秒)", 
          taskName, iterations, [[NSDate date] timeIntervalSinceDate:startTime]);
}

// ============================================================================
#pragma mark - 控制方法
// ============================================================================

- (void)stopAllTests {
    self.isRunning = NO;
    self.statusLabel.text = @"所有测试已停止";
    NSLog(@"[AsyncCPU] 用户停止所有测试");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"等待测试...";
    });
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" 
                                                                   message:message 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    self.isRunning = NO;
    NSLog(@"[AsyncCPU] TestAsyncCPUViewController dealloc");
}

@end

