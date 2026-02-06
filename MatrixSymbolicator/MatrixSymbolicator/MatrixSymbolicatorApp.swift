//
//  MatrixSymbolicatorApp.swift
//  MatrixSymbolicator
//
//  Created on 2026-01-16.
//  Matrix 符号化工具 - macOS 桌面版
//

import SwiftUI

@main
struct MatrixSymbolicatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 添加自定义菜单命令
            CommandGroup(replacing: .newItem) {
                Button("打开报告...") {
                    // 打开文件对话框
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
