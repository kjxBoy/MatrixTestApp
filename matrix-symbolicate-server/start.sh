#!/bin/bash

# Matrix 符号化服务启动脚本

echo "🚀 启动 Matrix 符号化服务..."
echo ""

# 检查 Go 是否安装
if ! command -v go &> /dev/null; then
    echo "❌ 错误: 未找到 Go 编译器"
    echo "请先安装 Go: https://golang.org/dl/"
    exit 1
fi

# 检查必要的命令
if ! command -v atos &> /dev/null; then
    echo "❌ 错误: 未找到 atos 命令"
    echo "请确保已安装 Xcode 命令行工具: xcode-select --install"
    exit 1
fi

if ! command -v dwarfdump &> /dev/null; then
    echo "❌ 错误: 未找到 dwarfdump 命令"
    echo "请确保已安装 Xcode 命令行工具: xcode-select --install"
    exit 1
fi

# 创建必要的目录
echo "📁 创建必要的目录..."
mkdir -p uploads dsyms reports static

# 检查依赖
if [ ! -f "go.sum" ]; then
    echo "📦 下载依赖..."
    go mod download
fi

# 设置端口
PORT=${PORT:-8080}

echo "✅ 环境检查完成"
echo ""
echo "📱 服务将在以下地址启动:"
echo "   http://localhost:$PORT"
echo ""
echo "按 Ctrl+C 停止服务"
echo ""

# 启动服务
export PORT=$PORT
go run main.go symbolicate.go

