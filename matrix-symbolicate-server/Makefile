.PHONY: help install run build clean test dev

# 默认目标
help:
	@echo "Matrix 符号化服务 - Makefile"
	@echo ""
	@echo "可用命令:"
	@echo "  make install    - 安装依赖"
	@echo "  make run        - 运行服务（开发模式）"
	@echo "  make build      - 编译二进制文件"
	@echo "  make clean      - 清理临时文件"
	@echo "  make test       - 运行测试"
	@echo "  make dev        - 启动开发服务（自动重载）"
	@echo ""

# 安装依赖
install:
	@echo "📦 安装 Go 依赖..."
	go mod download
	go mod tidy
	@echo "✅ 依赖安装完成"

# 运行服务
run:
	@echo "🚀 启动服务..."
	@mkdir -p uploads dsyms reports static
	go run .

# 编译二进制
build:
	@echo "🔨 编译二进制文件..."
	@mkdir -p bin
	go build -o bin/matrix-server .
	@echo "✅ 编译完成: bin/matrix-server"

# 清理文件
clean:
	@echo "🗑️  清理临时文件..."
	rm -rf bin/
	rm -rf uploads/*
	rm -rf dsyms/*
	rm -rf reports/*
	@echo "✅ 清理完成"

# 运行测试
test:
	@echo "🧪 运行测试..."
	go test -v ./...

# 开发模式（需要安装 air）
dev:
	@if command -v air > /dev/null; then \
		air; \
	else \
		echo "❌ 请先安装 air: go install github.com/cosmtrek/air@latest"; \
		echo "或使用: make run"; \
	fi

# 检查环境
check:
	@echo "🔍 检查环境..."
	@command -v go >/dev/null 2>&1 || { echo "❌ 未找到 Go"; exit 1; }
	@command -v atos >/dev/null 2>&1 || { echo "❌ 未找到 atos"; exit 1; }
	@command -v dwarfdump >/dev/null 2>&1 || { echo "❌ 未找到 dwarfdump"; exit 1; }
	@echo "✅ 环境检查通过"

# 格式化代码
fmt:
	@echo "🎨 格式化代码..."
	go fmt ./...
	@echo "✅ 格式化完成"

# 代码检查
lint:
	@echo "🔍 运行代码检查..."
	@if command -v golangci-lint > /dev/null; then \
		golangci-lint run; \
	else \
		echo "⚠️  未安装 golangci-lint，使用 go vet"; \
		go vet ./...; \
	fi

# 生产部署
deploy: build
	@echo "🚀 准备部署..."
	@mkdir -p deploy
	cp bin/matrix-server deploy/
	cp -r static deploy/
	@echo "✅ 部署文件已准备到 deploy/ 目录"

# 查看日志目录大小
du:
	@echo "📊 存储使用情况:"
	@du -sh dsyms 2>/dev/null || echo "  dsyms: 0 B"
	@du -sh reports 2>/dev/null || echo "  reports: 0 B"
	@du -sh uploads 2>/dev/null || echo "  uploads: 0 B"

