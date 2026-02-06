# Matrix 符号化工具 - macOS 桌面版

一个漂亮的 macOS 桌面应用，用于将 Matrix iOS 卡顿/崩溃日志进行符号化，支持拖拽上传、实时处理、结果导出。

## ✨ 功能特性

- **🎯 拖拽上传**: 支持拖拽 dSYM 文件和 JSON 错误日志
- **⚡ 实时符号化**: 使用 `atos` 和 `dwarfdump` 进行高效符号化
- **📊 详细统计**: 显示符号化成功率、Swift/ObjC 符号数量等统计信息
- **📋 一键复制**: 快速复制符号化结果到剪贴板
- **💾 导出报告**: 将符号化结果导出为文本文件
- **🎨 现代 UI**: 使用 SwiftUI 构建的原生 macOS 界面

## 🚀 快速开始

### 系统要求

- macOS 13.0 或更高版本
- Xcode 15.0 或更高版本（用于构建）

### 构建应用

```bash
# 1. 进入项目目录
cd MatrixTestApp/MatrixSymbolicator

# 2. 使用 Xcode 打开项目
open MatrixSymbolicator.xcodeproj

# 3. 在 Xcode 中选择 "Product > Build" (⌘B)

# 4. 运行应用 (⌘R)
```

### 使用方法

1. **上传 dSYM 文件**
   - 点击或拖拽 `.dSYM.zip` 文件到左侧上传区域
   - 应用会自动提取 UUID 信息

2. **上传错误日志**
   - 点击或拖拽 Matrix 生成的 `.json` 日志文件
   - 应用会自动识别报告类型（卡顿/崩溃/OOM/耗电）

3. **开始符号化**
   - 点击"开始符号化"按钮
   - 等待处理完成（通常几秒钟）

4. **查看和导出结果**
   - 在右侧查看格式化的符号化结果
   - 点击"复制"按钮复制到剪贴板
   - 点击"导出"按钮保存为文本文件

## 📁 项目结构

```
MatrixSymbolicator/
├── MatrixSymbolicator.xcodeproj/     # Xcode 项目文件
└── MatrixSymbolicator/
    ├── MatrixSymbolicatorApp.swift   # 应用入口
    ├── ContentView.swift              # 主界面 UI
    ├── SymbolicatorViewModel.swift    # 视图模型（状态管理）
    ├── SymbolicationEngine.swift      # 符号化引擎（核心逻辑）
    ├── Assets.xcassets/               # 图标和颜色资源
    ├── Info.plist                     # 应用配置
    └── MatrixSymbolicator.entitlements # 权限配置
```

## 🔧 技术实现

### 核心组件

1. **SymbolicationEngine**: 
   - 使用 `atos` 进行地址符号化
   - 使用 `dwarfdump` 提取 dSYM UUID
   - 支持 arm64 和 x86_64 架构
   - 自动检测 Swift/Objective-C/C++ 符号

2. **SymbolicatorViewModel**:
   - 管理应用状态
   - 处理文件选择和上传
   - 协调符号化流程

3. **ContentView**:
   - 现代化的 SwiftUI 界面
   - 支持拖拽上传
   - 实时显示处理进度

### 符号化流程

```
1. 用户上传 dSYM.zip 和 JSON 报告
     ↓
2. 解压 dSYM，提取 DWARF 二进制文件
     ↓
3. 解析 JSON 报告，提取线程和堆栈信息
     ↓
4. 对每个地址调用 atos 进行符号化
     ↓
5. 解析文件名、行号、语言类型
     ↓
6. 生成格式化的报告
     ↓
7. 显示结果，支持复制和导出
```

## 🎨 界面预览

### 主界面

```
┌────────────────────────────────────────────────────────┐
│  Matrix 符号化工具                                      │
├───────────────┬────────────────────────────────────────┤
│               │                                         │
│  📦 dSYM 上传 │           符号化结果                    │
│  ┌─────────┐  │                                         │
│  │ 拖拽区域│  │  🎯 主线程: Thread 0                    │
│  └─────────┘  │  ═══════════════════════════════════   │
│               │                                         │
│  📄 日志上传  │  🟦 0  MatrixTestApp  0x1000abc        │
│  ┌─────────┐  │     TestViewController.viewDidLoad()   │
│  │ 拖拽区域│  │     (TestViewController.swift:42)      │
│  └─────────┘  │                                         │
│               │  🟧 1  MatrixTestApp  0x1000def        │
│  [ 开始符号化 ]│     -[AppDelegate application:...]     │
│               │     (AppDelegate.m:123)                 │
│               │                                         │
│               │  [ 复制 ]  [ 导出 ]                     │
└───────────────┴────────────────────────────────────────┘
```

## 📝 支持的报告类型

- ✅ 主线程卡顿 (EDumpType_MainThreadBlock = 2001)
- ✅ 后台主线程卡顿 (EDumpType_BackgroundMainThreadBlock = 2002)
- ✅ CPU 占用过高 (EDumpType_CPUBlock = 2003)
- ✅ 耗电监控 (EDumpType_PowerConsume = 2011)
- ✅ 内存溢出 OOM (3000)

## 🔐 权限说明

应用使用 App Sandbox，仅请求必要的权限：

- `com.apple.security.files.user-selected.read-only`: 读取用户选择的文件
- `com.apple.security.files.user-selected.read-write`: 保存导出的报告

## 🐛 故障排查

### 问题：无法提取 UUID

**解决方案**:
- 确保上传的是有效的 `.dSYM.zip` 文件
- 检查 dSYM 文件是否包含 DWARF 调试信息
- 使用终端手动验证: `dwarfdump --uuid /path/to/app.dSYM`

### 问题：符号化失败

**解决方案**:
- 确保 dSYM 的 UUID 与崩溃日志中的 UUID 匹配
- 检查架构是否正确（arm64 vs x86_64）
- 验证 `atos` 工具可用: `which atos`

### 问题：应用无法启动

**解决方案**:
- 检查 macOS 版本是否 >= 13.0
- 在 Xcode 中清理构建: `Product > Clean Build Folder` (⌘⇧K)
- 重新构建项目

## 🆚 与服务端版本对比

| 特性 | macOS 应用 | Go 服务端 |
|------|-----------|----------|
| 部署方式 | 本地应用 | HTTP 服务器 |
| 用户界面 | 原生 macOS UI | Web 界面 |
| 符号化速度 | ⚡ 非常快 | 快 |
| 多用户 | ❌ 单用户 | ✅ 多用户 |
| 文件管理 | 临时处理 | 持久化存储 |
| 适用场景 | 开发调试 | 团队协作 |

## 📚 相关文档

- [Matrix iOS 文档](../README.md)
- [符号化服务端](../matrix-symbolicate-server/)
- [快速使用指南](../快速使用指南.md)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本项目与 Matrix 主项目使用相同的许可证。

---

**作者**: Matrix Team  
**创建日期**: 2026-01-16  
**版本**: 1.0.0
