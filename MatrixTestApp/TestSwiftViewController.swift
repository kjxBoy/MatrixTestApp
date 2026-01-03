//
//  TestSwiftViewController.swift
//  MatrixTestApp
//
//  测试 Swift 代码的堆栈回溯
//

import UIKit

class TestSwiftViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Swift 堆栈测试"
        view.backgroundColor = .white
        
        setupButtons()
    }
    
    private func setupButtons() {
        // ========================================
        // 测试按钮1: Swift 递归函数（耗 CPU）
        // ========================================
        let recursionBtn = UIButton(type: .system)
        recursionBtn.frame = CGRect(x: 50, y: 100, width: 300, height: 50)
        recursionBtn.setTitle("🔢 测试 Swift 递归（耗电）", for: .normal)
        recursionBtn.backgroundColor = .systemBlue
        recursionBtn.setTitleColor(.white, for: .normal)
        recursionBtn.layer.cornerRadius = 8
        recursionBtn.addTarget(self, action: #selector(testSwiftRecursion), for: .touchUpInside)
        view.addSubview(recursionBtn)
        
        // ========================================
        // 测试按钮2: Swift 闭包嵌套（卡顿）
        // ========================================
        let closureBtn = UIButton(type: .system)
        closureBtn.frame = CGRect(x: 50, y: 170, width: 300, height: 50)
        closureBtn.setTitle("🎯 测试 Swift 闭包嵌套（卡顿）", for: .normal)
        closureBtn.backgroundColor = .systemGreen
        closureBtn.setTitleColor(.white, for: .normal)
        closureBtn.layer.cornerRadius = 8
        closureBtn.addTarget(self, action: #selector(testSwiftClosures), for: .touchUpInside)
        view.addSubview(closureBtn)
        
        // ========================================
        // 测试按钮3: Swift 泛型函数
        // ========================================
        let genericBtn = UIButton(type: .system)
        genericBtn.frame = CGRect(x: 50, y: 240, width: 300, height: 50)
        genericBtn.setTitle("🧬 测试 Swift 泛型（耗电）", for: .normal)
        genericBtn.backgroundColor = .systemOrange
        genericBtn.setTitleColor(.white, for: .normal)
        genericBtn.layer.cornerRadius = 8
        genericBtn.addTarget(self, action: #selector(testSwiftGenerics), for: .touchUpInside)
        view.addSubview(genericBtn)
        
        // ========================================
        // 测试按钮4: Swift 异步任务
        // ========================================
        let asyncBtn = UIButton(type: .system)
        asyncBtn.frame = CGRect(x: 50, y: 310, width: 300, height: 50)
        asyncBtn.setTitle("⚡ 测试 Swift 多线程（耗电）", for: .normal)
        asyncBtn.backgroundColor = .systemRed
        asyncBtn.setTitleColor(.white, for: .normal)
        asyncBtn.layer.cornerRadius = 8
        asyncBtn.addTarget(self, action: #selector(testSwiftAsync), for: .touchUpInside)
        view.addSubview(asyncBtn)
        
        // 提示文字
        let label = UILabel(frame: CGRect(x: 20, y: 400, width: view.bounds.width - 40, height: 100))
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .gray
        label.text = """
        💡 这些测试将触发 Matrix 的卡顿/耗电监控
        Swift 函数的堆栈会被正确捕获
        但函数名需要通过 dSYM 符号化才能识别
        """
        view.addSubview(label)
    }
    
    // ============================================================================
    // MARK: - 测试1: Swift 递归函数（模拟斐波那契数列）
    // ============================================================================
    // 期望堆栈：
    // Thread 0:
    // 0  libsystem_kernel.dylib  mach_msg_trap
    // 1  MatrixTestApp           $s15MatrixTestApp0aB5SwiftViewControllerC9fibonacciyS2iF
    //                            ↑ Swift mangled 名称
    // 2  MatrixTestApp           $s15MatrixTestApp0aB5SwiftViewControllerC9fibonacciyS2iF
    // 3  MatrixTestApp           $s15MatrixTestApp0aB5SwiftViewControllerC19testSwiftRecursionyyF
    //
    // 符号化后：
    // 1  MatrixTestApp  TestSwiftViewController.fibonacci(_:) -> Int
    // 2  MatrixTestApp  TestSwiftViewController.fibonacci(_:) -> Int
    // 3  MatrixTestApp  TestSwiftViewController.testSwiftRecursion()
    // ============================================================================
    @objc private func testSwiftRecursion() {
        print("⚡ 开始 Swift 递归测试（预计 60 秒）")
        
        // 在子线程执行，持续 60 秒以触发耗电监控
        DispatchQueue.global(qos: .userInitiated).async {
            let endTime = Date().addingTimeInterval(60)
            while Date() < endTime {
                // 递归计算斐波那契数（非常耗 CPU）
                let result = self.fibonacci(35)  // 35 层递归
                print("📊 计算结果: \(result)")
            }
            
            print("✅ Swift 递归测试完成")
        }
    }
    
    // 斐波那契递归函数（纯 Swift）
    private func fibonacci(_ n: Int) -> Int {
        if n <= 1 {
            return n
        }
        // 递归调用：堆栈会被 Matrix 捕获
        return fibonacci(n - 1) + fibonacci(n - 2)
    }
    
    // ============================================================================
    // MARK: - 测试2: Swift 闭包嵌套（模拟复杂的回调链）
    // ============================================================================
    // 期望堆栈：
    // Thread 0:
    // 0  MatrixTestApp  closure #3 in closure #2 in closure #1 in testSwiftClosures()
    // 1  MatrixTestApp  closure #2 in closure #1 in testSwiftClosures()
    // 2  MatrixTestApp  closure #1 in testSwiftClosures()
    // 3  MatrixTestApp  testSwiftClosures()
    // ============================================================================
    @objc private func testSwiftClosures() {
        print("⚡ 开始 Swift 闭包嵌套测试")
        
        // 闭包层级1
        let level1Closure = { [weak self] in
            guard let self = self else { return }
            print("📦 闭包层级 1")
            
            // 闭包层级2
            let level2Closure = {
                print("📦 闭包层级 2")
                
                // 闭包层级3：主线程阻塞 4 秒（触发卡顿监控）
                let level3Closure = {
                    print("📦 闭包层级 3 - 开始主线程卡顿")
                    Thread.sleep(forTimeInterval: 4.0)  // 卡顿 4 秒
                    print("📦 闭包层级 3 - 结束")
                }
                
                // 在主线程执行（触发卡顿）
                DispatchQueue.main.async {
                    level3Closure()
                }
            }
            
            level2Closure()
        }
        
        // 延迟执行
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            level1Closure()
        }
    }
    
    // ============================================================================
    // MARK: - 测试3: Swift 泛型函数
    // ============================================================================
    // Swift 泛型会生成特化的代码，堆栈中会显示类型信息
    // 期望堆栈：
    // 0  MatrixTestApp  genericSort<A>(_:) [with A = Swift.Int]
    // 1  MatrixTestApp  testSwiftGenerics()
    // ============================================================================
    @objc private func testSwiftGenerics() {
        print("⚡ 开始 Swift 泛型测试")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let endTime = Date().addingTimeInterval(60)
            while Date() < endTime {
                // 大数组排序（耗 CPU）
                var array = (0..<100000).map { _ in Int.random(in: 0...1000000) }
                self.genericSort(&array)
                print("📊 泛型排序完成，数组大小: \(array.count)")
            }
            
            print("✅ Swift 泛型测试完成")
        }
    }
    
    // 泛型冒泡排序（故意低效以消耗 CPU）
    private func genericSort<T: Comparable>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        
        for i in 0..<array.count {
            for j in 0..<(array.count - i - 1) {
                if array[j] > array[j + 1] {
                    array.swapAt(j, j + 1)
                }
            }
        }
    }
    
    // ============================================================================
    // MARK: - 测试4: Swift 多线程异步任务
    // ============================================================================
    // 模拟多个 Swift 线程同时高负载工作
    // 期望堆栈：多个线程都有独立的 Swift 堆栈
    // ============================================================================
    @objc private func testSwiftAsync() {
        print("⚡ 开始 Swift 多线程测试（10 个线程）")
        
        // 创建 10 个高优先级线程，每个都执行耗时任务
        for threadIndex in 0..<10 {
            DispatchQueue.global(qos: .userInitiated).async {
                self.asyncHeavyWork(threadId: threadIndex)
            }
        }
    }
    
    private func asyncHeavyWork(threadId: Int) {
        print("🔥 线程 \(threadId) 开始工作")
        
        let endTime = Date().addingTimeInterval(70)  // 70 秒
        while Date() < endTime {
            // 模拟复杂计算
            let result = self.complexCalculation(iterations: 1000000)
            print("📊 线程 \(threadId) 计算结果: \(result)")
            
            // 避免 100% 占用
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("✅ 线程 \(threadId) 工作完成")
    }
    
    // 复杂数学计算（纯 Swift）
    private func complexCalculation(iterations: Int) -> Double {
        var result: Double = 0.0
        for i in 0..<iterations {
            result += sqrt(Double(i)) * sin(Double(i)) * cos(Double(i))
        }
        return result
    }
}

// ============================================================================
// MARK: - Swift 扩展（测试扩展方法的堆栈）
// ============================================================================
extension TestSwiftViewController {
    // 扩展方法也会出现在堆栈中
    // mangled 名称: $s15MatrixTestApp0aB5SwiftViewControllerC9extensionE13extensionWork7messageySS_tF
    func extensionWork(message: String) {
        print("🧩 Extension 方法: \(message)")
        Thread.sleep(forTimeInterval: 5.0)  // 卡顿 5 秒
    }
}

