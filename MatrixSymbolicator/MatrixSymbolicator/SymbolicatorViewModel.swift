//
//  SymbolicatorViewModel.swift
//  MatrixSymbolicator
//
//  视图模型 - 管理状态和业务逻辑
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
class SymbolicatorViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var dsymFile: URL?
    @Published var dsymUUID: String?
    @Published var reportFile: URL?
    @Published var reportType: String?
    @Published var reportThreadCount: Int?
    
    @Published var isSymbolicating = false
    @Published var errorMessage: String?
    
    @Published var symbolicatedReport: SymbolicatedReport?
    @Published var formattedReport: String?
    
    // MARK: - Computed Properties
    
    var canSymbolicate: Bool {
        dsymFile != nil && reportFile != nil
    }
    
    // MARK: - Private Properties
    
    private let engine = SymbolicationEngine()
    
    // MARK: - File Selection
    
    func selectDsymFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 dSYM 文件"
        panel.allowedContentTypes = [UTType(filenameExtension: "dSYM.zip")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            dsymFile = url
            extractDsymInfo(from: url)
        }
    }
    
    func selectReportFile() {
        let panel = NSOpenPanel()
        panel.title = "选择错误日志"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            reportFile = url
            parseReportInfo(from: url)
        }
    }
    
    // MARK: - Symbolication
    
    func symbolicate() {
        guard let dsym = dsymFile, let report = reportFile else { return }
        
        isSymbolicating = true
        errorMessage = nil
        
        Task {
            do {
                let result = try await engine.symbolicate(reportURL: report, dsymURL: dsym)
                self.symbolicatedReport = result
                self.formattedReport = result.formattedText
                self.isSymbolicating = false
            } catch {
                self.errorMessage = "符号化失败: \(error.localizedDescription)"
                self.isSymbolicating = false
            }
        }
    }
    
    // MARK: - Export & Copy
    
    func copyToClipboard() {
        guard let text = formattedReport else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    func exportReport() {
        guard let report = symbolicatedReport else { return }
        
        let panel = NSSavePanel()
        panel.title = "导出符号化报告"
        panel.nameFieldStringValue = "symbolicated_report.txt"
        panel.allowedContentTypes = [.plainText]
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try report.formattedText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func extractDsymInfo(from url: URL) {
        Task {
            do {
                let uuid = try await engine.extractDsymUUID(from: url)
                self.dsymUUID = uuid
            } catch {
                self.dsymUUID = "无法提取 UUID"
            }
        }
    }
    
    private func parseReportInfo(from url: URL) {
        Task {
            do {
                let data = try Data(contentsOf: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // 解析 dump_type
                    if let dumpType = json["dump_type"] as? Int {
                        self.reportType = getDumpTypeName(dumpType)
                    } else if json["head"] != nil && json["items"] != nil {
                        self.reportType = "内存溢出 (OOM)"
                    } else if json["stack_string"] != nil {
                        self.reportType = "耗电监控"
                    }
                    
                    // 解析线程数
                    if let crash = json["crash"] as? [String: Any],
                       let threads = crash["threads"] as? [[String: Any]] {
                        self.reportThreadCount = threads.count
                    }
                }
            } catch {
                self.reportType = "无法解析"
            }
        }
    }
    
    private func getDumpTypeName(_ type: Int) -> String {
        switch type {
        case 2001: return "主线程卡顿"
        case 2002: return "后台主线程卡顿"
        case 2003: return "CPU 占用过高"
        case 2011: return "耗电监控"
        case 3000: return "内存溢出 (OOM)"
        default: return "类型 \(type)"
        }
    }
}
