//
//  ContentView.swift
//  MatrixSymbolicator
//
//  Matrix 符号化工具主界面
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = SymbolicatorViewModel()
    
    var body: some View {
        HSplitView {
            // 左侧：上传区域
            VStack(spacing: 20) {
                // 头部
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    
                    Text("Matrix 符号化工具")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("上传 dSYM 和错误日志进行符号化")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 30)
                
                Divider()
                
                // dSYM 文件上传区域
                VStack(alignment: .leading, spacing: 12) {
                    Label("符号表文件 (.dSYM.zip)", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    
                    FileDropZone(
                        title: viewModel.dsymFile?.lastPathComponent ?? "拖拽或点击选择 dSYM.zip",
                        subtitle: viewModel.dsymFile != nil ? "已选择" : "支持 .dSYM.zip 文件",
                        isSelected: viewModel.dsymFile != nil,
                        systemImage: "cube.box"
                    ) {
                        viewModel.selectDsymFile()
                    }
                    
                    if let dsym = viewModel.dsymFile {
                        HStack {
                            Text("UUID:")
                                .foregroundColor(.secondary)
                            Text(viewModel.dsymUUID ?? "提取中...")
                                .font(.system(.caption, design: .monospaced))
                            
                            Spacer()
                            
                            Button(action: { viewModel.dsymFile = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 20)
                
                // 错误日志上传区域
                VStack(alignment: .leading, spacing: 12) {
                    Label("错误日志 (JSON)", systemImage: "doc.text")
                        .font(.headline)
                    
                    FileDropZone(
                        title: viewModel.reportFile?.lastPathComponent ?? "拖拽或点击选择 JSON 文件",
                        subtitle: viewModel.reportFile != nil ? "已选择" : "支持 .json 格式",
                        isSelected: viewModel.reportFile != nil,
                        systemImage: "doc.richtext"
                    ) {
                        viewModel.selectReportFile()
                    }
                    
                    if let report = viewModel.reportFile {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.reportType ?? "解析中...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if let threads = viewModel.reportThreadCount {
                                    Text("\(threads) 个线程")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Button(action: { viewModel.reportFile = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // 符号化按钮
                Button(action: viewModel.symbolicate) {
                    HStack {
                        if viewModel.isSymbolicating {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        
                        Text(viewModel.isSymbolicating ? "符号化中..." : "开始符号化")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSymbolicate || viewModel.isSymbolicating)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                
                // 错误提示
                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
            }
            .frame(width: 380)
            .background(Color(NSColor.controlBackgroundColor))
            
            // 右侧：结果显示
            VStack(spacing: 0) {
                // 工具栏
                HStack {
                    Text("符号化结果")
                        .font(.headline)
                    
                    Spacer()
                    
                    if viewModel.symbolicatedReport != nil {
                        HStack(spacing: 12) {
                            Button(action: viewModel.copyToClipboard) {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            
                            Button(action: viewModel.exportReport) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // 结果内容
                if let result = viewModel.formattedReport {
                    ScrollView {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(result)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("等待符号化")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        
                        Text("请上传 dSYM 文件和错误日志，然后点击\"开始符号化\"")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - 文件拖拽区域组件
struct FileDropZone: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let systemImage: String
    let action: () -> Void
    
    @State private var isTargeted = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : (isTargeted ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.3)),
                        style: StrokeStyle(lineWidth: 2, dash: isSelected ? [] : [5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isSelected ? Color.accentColor.opacity(0.1) : (isTargeted ? Color.accentColor.opacity(0.05) : Color.clear))
                    )
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                if let data = data as? Data,
                   let path = String(data: data, encoding: .utf8),
                   let url = URL(string: path) {
                    DispatchQueue.main.async {
                        action()
                    }
                }
            }
            return true
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 700)
}
