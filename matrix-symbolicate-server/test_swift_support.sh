#!/bin/bash

# ============================================================================
# Swift 符号化支持测试脚本
# ============================================================================

echo "🧪 测试 Swift 符号化支持"
echo "======================================"
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# 测试1: 检查 swift demangle 工具是否可用
# ============================================================================
echo "📋 测试 1: 检查 swift demangle 工具"
echo "--------------------------------------"

if command -v swift &> /dev/null; then
    echo -e "${GREEN}✅ swift 命令可用${NC}"
    swift --version
    echo ""
    
    # 测试 demangle
    echo "测试 Swift demangle 功能..."
    TEST_SYMBOL='$s15MatrixTestApp23TestSwiftViewControllerC9fibonacciyS2iF'
    RESULT=$(swift demangle "$TEST_SYMBOL" 2>/dev/null)
    
    if [[ $RESULT == *"TestSwiftViewController"* ]]; then
        echo -e "${GREEN}✅ Swift demangle 功能正常${NC}"
        echo "   输入: $TEST_SYMBOL"
        echo "   输出: $RESULT"
    else
        echo -e "${RED}❌ Swift demangle 功能异常${NC}"
        echo "   输出: $RESULT"
    fi
else
    echo -e "${RED}❌ swift 命令不可用${NC}"
    echo "   请确保安装了 Xcode 或 Swift 工具链"
fi

echo ""

# ============================================================================
# 测试2: 检查 atos 工具
# ============================================================================
echo "📋 测试 2: 检查 atos 工具"
echo "--------------------------------------"

if command -v atos &> /dev/null; then
    echo -e "${GREEN}✅ atos 命令可用${NC}"
    ATOS_VERSION=$(atos -v 2>&1 | head -1)
    echo "   版本: $ATOS_VERSION"
else
    echo -e "${RED}❌ atos 命令不可用${NC}"
fi

echo ""

# ============================================================================
# 测试3: 检查编译后的服务器
# ============================================================================
echo "📋 测试 3: 检查编译后的服务器"
echo "--------------------------------------"

if [ -f "matrix-server" ]; then
    echo -e "${GREEN}✅ matrix-server 已编译${NC}"
    ls -lh matrix-server
else
    echo -e "${RED}❌ matrix-server 未找到${NC}"
    echo "   请运行: go build -o matrix-server main.go symbolicate.go format.go"
fi

echo ""

# ============================================================================
# 测试4: 验证代码中的 Swift 支持函数
# ============================================================================
echo "📋 测试 4: 验证 Swift 支持函数"
echo "--------------------------------------"

REQUIRED_FUNCTIONS=(
    "isSwiftSymbol"
    "demangleSwiftSymbol"
    "detectSymbolLanguage"
    "isSymbolWellFormatted"
    "extractMangledSymbol"
    "replaceSymbolName"
    "calculateSymbolicationStats"
)

for func in "${REQUIRED_FUNCTIONS[@]}"; do
    if grep -q "func $func" symbolicate.go; then
        echo -e "${GREEN}✅ $func 已定义${NC}"
    else
        echo -e "${RED}❌ $func 未找到${NC}"
    fi
done

echo ""

# ============================================================================
# 测试5: 检查文件扩展名支持
# ============================================================================
echo "📋 测试 5: 检查文件扩展名支持"
echo "--------------------------------------"

if grep -q "\.swift" symbolicate.go; then
    echo -e "${GREEN}✅ .swift 文件扩展名已支持${NC}"
else
    echo -e "${RED}❌ .swift 文件扩展名未支持${NC}"
fi

if grep -q "Swift 应用代码" symbolicate.go; then
    echo -e "${GREEN}✅ Swift 代码标记已添加${NC}"
else
    echo -e "${RED}❌ Swift 代码标记未找到${NC}"
fi

echo ""

# ============================================================================
# 总结
# ============================================================================
echo "======================================"
echo "🎯 测试完成"
echo "======================================"
echo ""
echo "💡 下一步："
echo "   1. 启动服务器: ./matrix-server"
echo "   2. 上传 Swift dSYM 文件"
echo "   3. 触发 Swift 测试场景（TestSwiftViewController）"
echo "   4. 查看符号化报告，验证 Swift 函数名"
echo ""
echo "📚 参考文档："
echo "   - Swift堆栈回溯技术说明.md"
echo "   - Swift堆栈测试指南.md"
echo "   - Swift与ObjC堆栈对比.md"
echo ""

