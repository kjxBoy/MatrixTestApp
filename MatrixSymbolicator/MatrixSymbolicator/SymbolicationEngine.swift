//
//  SymbolicationEngine.swift
//  MatrixSymbolicator
//
//  符号化引擎 - 核心业务逻辑
//

import Foundation

// MARK: - 数据模型

struct SymbolicatedReport {
    let originalReport: [String: Any]
    let threads: [SymbolicatedThread]
    let statistics: SymbolicationStatistics
    let formattedText: String
}

struct SymbolicatedThread {
    let index: Int
    let name: String?
    let crashed: Bool
    let frames: [SymbolicatedFrame]
    let hasAppCode: Bool
}

struct SymbolicatedFrame {
    let address: UInt64
    let objectName: String?
    let symbolName: String?
    let symbolicatedName: String?
    let fileName: String?
    let lineNumber: Int?
    let isAppCode: Bool
    let language: String?
}

struct SymbolicationStatistics {
    let totalThreads: Int
    let totalFrames: Int
    let symbolicatedFrames: Int
    let swiftSymbols: Int
    let objcSymbols: Int
    let appCodeFrames: Int
    let successRate: Double
}

// MARK: - 符号化引擎

actor SymbolicationEngine {
    
    // MARK: - 主入口
    
    func symbolicate(reportURL: URL, dsymURL: URL) async throws -> SymbolicatedReport {
        print("🔍 开始符号化...")
        print("   dSYM: \(dsymURL.lastPathComponent)")
        print("   Report: \(reportURL.lastPathComponent)")
        
        // 1. 解压 dSYM
        let binaryPath = try await extractDsym(dsymURL)
        print("✅ dSYM 已解压: \(binaryPath)")
        
        // 2. 读取报告
        let data = try Data(contentsOf: reportURL)
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SymbolicationError.invalidReportFormat
        }
        
        // 3. 获取架构和加载地址
        let arch = extractArchitecture(from: report)
        let loadAddress = try extractLoadAddress(from: report, dsymPath: binaryPath)
        
        print("   架构: \(arch)")
        print("   加载地址: 0x\(String(loadAddress, radix: 16))")
        
        // 4. 符号化线程
        let threads = try await symbolicateThreads(
            report: report,
            binaryPath: binaryPath,
            loadAddress: loadAddress,
            architecture: arch
        )
        
        // 5. 统计信息
        let stats = calculateStatistics(threads: threads)
        
        // 6. 格式化输出
        let formatted = formatReport(report: report, threads: threads, stats: stats)
        
        print("✅ 符号化完成!")
        print("   总帧数: \(stats.totalFrames)")
        print("   符号化: \(stats.symbolicatedFrames)")
        print("   成功率: \(String(format: "%.1f%%", stats.successRate))")
        
        return SymbolicatedReport(
            originalReport: report,
            threads: threads,
            statistics: stats,
            formattedText: formatted
        )
    }
    
    // MARK: - dSYM 处理
    
    func extractDsymUUID(from url: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        
        // 如果是 .zip 文件，需要先解压
        var targetPath = url.path
        if url.pathExtension == "zip" {
            targetPath = try await extractDsym(url)
        }
        
        process.arguments = ["--uuid", targetPath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw SymbolicationError.failedToExtractUUID
        }
        
        // 解析: UUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (arm64)
        let pattern = "UUID: ([A-F0-9-]+)"
        let regex = try NSRegularExpression(pattern: pattern)
        let nsString = output as NSString
        
        if let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: nsString.length)) {
            return nsString.substring(with: match.range(at: 1))
        }
        
        throw SymbolicationError.failedToExtractUUID
    }
    
    private func extractDsym(_ url: URL) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixSymbolicator_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", url.path, "-d", tempDir.path]
        
        try process.run()
        process.waitUntilExit()
        
        // 查找 DWARF 文件
        let enumerator = FileManager.default.enumerator(atPath: tempDir.path)
        while let file = enumerator?.nextObject() as? String {
            if file.contains("DWARF/") && !file.contains(".plist") {
                return tempDir.path + "/" + file
            }
        }
        
        throw SymbolicationError.dsymNotFound
    }
    
    // MARK: - 报告解析
    
    private func extractArchitecture(from report: [String: Any]) -> String {
        if let system = report["system"] as? [String: Any],
           let cpuArch = system["cpu_arch"] as? String {
            if cpuArch.lowercased().contains("x86") {
                return "x86_64"
            }
        }
        return "arm64"
    }
    
    private func extractLoadAddress(from report: [String: Any], dsymPath: String) throws -> UInt64 {
        guard let binaryImages = report["binary_images"] as? [[String: Any]] else {
            return 0
        }
        
        for image in binaryImages {
            if let name = image["name"] as? String,
               (name.contains("MatrixTestApp") || name.contains(".app/")),
               let addr = image["image_addr"] as? NSNumber {
                return addr.uint64Value
            }
        }
        
        return 0
    }
    
    // MARK: - 符号化
    
    private func symbolicateThreads(
        report: [String: Any],
        binaryPath: String,
        loadAddress: UInt64,
        architecture: String
    ) async throws -> [SymbolicatedThread] {
        
        var result: [SymbolicatedThread] = []
        
        // 检查报告类型
        if let crash = report["crash"] as? [String: Any],
           let threads = crash["threads"] as? [[String: Any]] {
            // 卡顿报告
            for threadData in threads {
                let thread = try await symbolicateThread(
                    threadData: threadData,
                    binaryPath: binaryPath,
                    loadAddress: loadAddress,
                    architecture: architecture
                )
                result.append(thread)
            }
        }
        
        return result
    }
    
    private func symbolicateThread(
        threadData: [String: Any],
        binaryPath: String,
        loadAddress: UInt64,
        architecture: String
    ) async throws -> SymbolicatedThread {
        
        let index = (threadData["index"] as? Int) ?? 0
        let name = threadData["name"] as? String
        let crashed = (threadData["crashed"] as? Bool) ?? false
        
        guard let backtrace = threadData["backtrace"] as? [String: Any],
              let contents = backtrace["contents"] as? [[String: Any]] else {
            return SymbolicatedThread(
                index: index,
                name: name,
                crashed: crashed,
                frames: [],
                hasAppCode: false
            )
        }
        
        var frames: [SymbolicatedFrame] = []
        var hasAppCode = false
        
        for frameData in contents {
            let frame = try await symbolicateFrame(
                frameData: frameData,
                binaryPath: binaryPath,
                loadAddress: loadAddress,
                architecture: architecture
            )
            
            if frame.isAppCode {
                hasAppCode = true
            }
            
            frames.append(frame)
        }
        
        return SymbolicatedThread(
            index: index,
            name: name,
            crashed: crashed,
            frames: frames,
            hasAppCode: hasAppCode
        )
    }
    
    private func symbolicateFrame(
        frameData: [String: Any],
        binaryPath: String,
        loadAddress: UInt64,
        architecture: String
    ) async throws -> SymbolicatedFrame {
        
        let address = (frameData["instruction_addr"] as? NSNumber)?.uint64Value ?? 0
        let objectName = frameData["object_name"] as? String
        let symbolName = frameData["symbol_name"] as? String
        
        // 判断是否需要符号化
        var symbolicatedName: String?
        var fileName: String?
        var lineNumber: Int?
        var isAppCode = false
        var language: String?
        
        if let objName = objectName,
           (objName.contains("MatrixTestApp") || objName == "???" || symbolName == nil || symbolName == "<redacted>") {
            // 需要符号化
            if let result = try? await symbolicateAddress(
                address: address,
                binaryPath: binaryPath,
                loadAddress: loadAddress,
                architecture: architecture
            ) {
                symbolicatedName = result.symbol
                fileName = result.fileName
                lineNumber = result.lineNumber
                language = result.language
                
                if let fn = fileName {
                    isAppCode = !fn.contains("KSCrash") && !fn.contains("WC") && !fn.contains("Matrix")
                }
            }
        }
        
        return SymbolicatedFrame(
            address: address,
            objectName: objectName,
            symbolName: symbolName,
            symbolicatedName: symbolicatedName,
            fileName: fileName,
            lineNumber: lineNumber,
            isAppCode: isAppCode,
            language: language
        )
    }
    
    private func symbolicateAddress(
        address: UInt64,
        binaryPath: String,
        loadAddress: UInt64,
        architecture: String
    ) async throws -> (symbol: String, fileName: String?, lineNumber: Int?, language: String?) {
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        process.arguments = [
            "-arch", architecture,
            "-o", binaryPath,
            "-l", String(format: "0x%llx", loadAddress),
            String(format: "0x%llx", address)
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              !output.hasPrefix("0x") else {
            throw SymbolicationError.symbolicationFailed
        }
        
        // 解析文件名和行号
        let (fileName, lineNumber) = parseFileInfo(from: output)
        
        // 检测语言
        let language = detectLanguage(from: output)
        
        return (output, fileName, lineNumber, language)
    }
    
    // MARK: - 辅助方法
    
    private func parseFileInfo(from symbol: String) -> (String?, Int?) {
        // 匹配 (File.swift:123) 或 (File.mm:45)
        let pattern = "\\(([^)]+\\.(m|mm|swift|c|cpp|cc|cxx|h|hpp)):(\\d+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: symbol, range: NSRange(symbol.startIndex..., in: symbol)) else {
            return (nil, nil)
        }
        
        let nsString = symbol as NSString
        let fileName = nsString.substring(with: match.range(at: 1))
        let lineNum = Int(nsString.substring(with: match.range(at: 3)))
        
        return (fileName, lineNum)
    }
    
    private func detectLanguage(from symbol: String) -> String {
        if symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") || symbol.hasPrefix("_$S") {
            return "Swift"
        }
        if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") {
            return "Objective-C"
        }
        if symbol.hasPrefix("_Z") {
            return "C++"
        }
        return "C"
    }
    
    // MARK: - 统计
    
    private func calculateStatistics(threads: [SymbolicatedThread]) -> SymbolicationStatistics {
        var totalFrames = 0
        var symbolicatedFrames = 0
        var swiftSymbols = 0
        var objcSymbols = 0
        var appCodeFrames = 0
        
        for thread in threads {
            for frame in thread.frames {
                totalFrames += 1
                
                if frame.symbolicatedName != nil {
                    symbolicatedFrames += 1
                }
                
                if let lang = frame.language {
                    switch lang {
                    case "Swift": swiftSymbols += 1
                    case "Objective-C": objcSymbols += 1
                    default: break
                    }
                }
                
                if frame.isAppCode {
                    appCodeFrames += 1
                }
            }
        }
        
        let successRate = totalFrames > 0 ? Double(symbolicatedFrames) / Double(totalFrames) * 100.0 : 0.0
        
        return SymbolicationStatistics(
            totalThreads: threads.count,
            totalFrames: totalFrames,
            symbolicatedFrames: symbolicatedFrames,
            swiftSymbols: swiftSymbols,
            objcSymbols: objcSymbols,
            appCodeFrames: appCodeFrames,
            successRate: successRate
        )
    }
    
    // MARK: - 格式化输出
    
    private func formatReport(
        report: [String: Any],
        threads: [SymbolicatedThread],
        stats: SymbolicationStatistics
    ) -> String {
        var output = ""
        
        // 标题
        output += String(repeating: "=", count: 80) + "\n"
        output += "🔍 Matrix 卡顿报告 - 符号化版本\n"
        output += String(repeating: "=", count: 80) + "\n\n"
        
        // 系统信息
        if let system = report["system"] as? [String: Any] {
            output += "📱 系统信息:\n"
            if let appName = system["CFBundleName"] as? String {
                output += "   应用名称: \(appName)\n"
            }
            if let sysVersion = system["system_version"] as? String {
                output += "   系统版本: iOS \(sysVersion)\n"
            }
            if let machine = system["machine"] as? String {
                output += "   设备型号: \(machine)\n"
            }
            output += "\n"
        }
        
        // 统计信息
        output += "📊 符号化统计:\n"
        output += "   总线程数: \(stats.totalThreads)\n"
        output += "   总帧数: \(stats.totalFrames)\n"
        output += "   符号化帧数: \(stats.symbolicatedFrames)\n"
        output += "   Swift 符号: \(stats.swiftSymbols)\n"
        output += "   ObjC 符号: \(stats.objcSymbols)\n"
        output += "   应用代码帧: \(stats.appCodeFrames)\n"
        output += "   成功率: \(String(format: "%.1f%%", stats.successRate))\n\n"
        
        // 线程信息
        for thread in threads {
            // 跳过没有应用代码的非主线程
            if thread.index != 0 && !thread.crashed && !thread.hasAppCode {
                continue
            }
            
            output += String(repeating: "=", count: 80) + "\n"
            
            let label: String
            if thread.index == 0 || (thread.name?.lowercased().contains("main") ?? false) {
                label = "🎯 主线程"
            } else if thread.crashed {
                label = "⚠️  崩溃线程"
            } else {
                label = "📍 线程 \(thread.index)"
            }
            
            output += "\(label): Thread \(thread.index)\n"
            if let name = thread.name {
                output += "   名称: \(name)\n"
            }
            output += String(repeating: "=", count: 80) + "\n\n"
            
            // 堆栈帧
            for (idx, frame) in thread.frames.enumerated() {
                let marker = frame.isAppCode ? (frame.language == "Swift" ? "🟦" : "🟧") : "  "
                
                if let symbolicated = frame.symbolicatedName {
                    let fileTag = frame.fileName != nil ? " [\(frame.language ?? "")]" : ""
                    output += String(format: "%@ %2d  %-25@ 0x%llx%@\n", marker, idx, frame.objectName ?? "???", frame.address, fileTag)
                    output += "      \(symbolicated)\n"
                } else if let symbol = frame.symbolName, symbol != "<redacted>" {
                    output += String(format: "%@ %2d  %-25@ 0x%llx %@\n", marker, idx, frame.objectName ?? "???", frame.address, symbol)
                } else {
                    output += String(format: "%@ %2d  %-25@ 0x%llx\n", marker, idx, frame.objectName ?? "???", frame.address)
                }
            }
            
            output += "\n"
        }
        
        output += String(repeating: "=", count: 80) + "\n"
        output += "💡 图例说明:\n"
        output += "   🟦 Swift 应用代码\n"
        output += "   🟧 Objective-C 应用代码\n"
        output += "      系统库代码（无标记）\n"
        output += String(repeating: "=", count: 80) + "\n"
        
        return output
    }
}

// MARK: - 错误类型

enum SymbolicationError: LocalizedError {
    case invalidReportFormat
    case dsymNotFound
    case failedToExtractUUID
    case symbolicationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidReportFormat:
            return "无效的报告格式"
        case .dsymNotFound:
            return "未找到 dSYM 文件"
        case .failedToExtractUUID:
            return "无法提取 UUID"
        case .symbolicationFailed:
            return "符号化失败"
        }
    }
}
