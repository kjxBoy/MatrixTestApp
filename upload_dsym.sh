#!/bin/bash

# Matrix 符号表上传脚本
# 自动查找、打包并上传 dSYM 到服务器

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
APP_NAME="MatrixTestApp"
SERVER_URL="${MATRIX_SERVER_URL:-http://localhost:8080}"
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData"

echo -e "${BLUE}🚀 Matrix 符号表上传工具${NC}"
echo "================================"
echo ""

# 检查服务器是否运行
echo -e "${BLUE}📡 检查服务器连接...${NC}"
if ! curl -s --connect-timeout 3 "$SERVER_URL/api/health" > /dev/null 2>&1; then
    echo -e "${RED}❌ 无法连接到服务器: $SERVER_URL${NC}"
    echo -e "${YELLOW}💡 请先启动服务器:${NC}"
    echo "   cd matrix-symbolicate-server"
    echo "   ./start.sh"
    exit 1
fi
echo -e "${GREEN}✅ 服务器运行正常${NC}"
echo ""

# 查找最新的 dSYM
echo -e "${BLUE}🔍 查找 $APP_NAME 的 dSYM...${NC}"

# 查找所有可能的路径
DSYM_PATHS=(
    "$DERIVED_DATA_PATH/$APP_NAME-*/Build/Products/Debug-iphonesimulator/$APP_NAME.app.dSYM"
    "$DERIVED_DATA_PATH/$APP_NAME-*/Build/Products/Debug-iphoneos/$APP_NAME.app.dSYM"
    "$DERIVED_DATA_PATH/$APP_NAME-*/Build/Products/Release-iphonesimulator/$APP_NAME.app.dSYM"
    "$DERIVED_DATA_PATH/$APP_NAME-*/Build/Products/Release-iphoneos/$APP_NAME.app.dSYM"
)

FOUND_DSYMS=()
for pattern in "${DSYM_PATHS[@]}"; do
    for dsym in $pattern; do
        if [ -d "$dsym" ]; then
            FOUND_DSYMS+=("$dsym")
        fi
    done
done

if [ ${#FOUND_DSYMS[@]} -eq 0 ]; then
    echo -e "${RED}❌ 未找到 dSYM 文件${NC}"
    echo ""
    echo -e "${YELLOW}💡 请确保:${NC}"
    echo "   1. 已在 Xcode 中编译过应用 (Cmd+B)"
    echo "   2. Build Settings → Debug Information Format = DWARF with dSYM"
    echo "   3. DerivedData 未被清理"
    echo ""
    echo "DerivedData 路径: $DERIVED_DATA_PATH"
    exit 1
fi

# 按修改时间排序，找到最新的
LATEST_DSYM=""
LATEST_TIME=0
for dsym in "${FOUND_DSYMS[@]}"; do
    if [[ "$OSTYPE" == "darwin"* ]]; then
        TIME=$(stat -f %m "$dsym")
    else
        TIME=$(stat -c %Y "$dsym")
    fi
    
    if [ $TIME -gt $LATEST_TIME ]; then
        LATEST_TIME=$TIME
        LATEST_DSYM="$dsym"
    fi
done

echo -e "${GREEN}✅ 找到 ${#FOUND_DSYMS[@]} 个 dSYM 文件${NC}"
echo ""

# 显示所有找到的 dSYM
for i in "${!FOUND_DSYMS[@]}"; do
    dsym="${FOUND_DSYMS[$i]}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mod_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$dsym")
    else
        mod_time=$(stat -c %y "$dsym" | cut -d'.' -f1)
    fi
    
    if [ "$dsym" == "$LATEST_DSYM" ]; then
        echo -e "  ${GREEN}[$((i+1))] $dsym${NC}"
        echo -e "      ${GREEN}编译时间: $mod_time (最新)${NC}"
    else
        echo "  [$((i+1))] $dsym"
        echo "      编译时间: $mod_time"
    fi
done
echo ""

# 让用户选择
if [ ${#FOUND_DSYMS[@]} -eq 1 ]; then
    SELECTED_DSYM="$LATEST_DSYM"
    echo -e "${BLUE}📦 使用唯一的 dSYM${NC}"
else
    echo -e "${YELLOW}请选择要上传的 dSYM [1-${#FOUND_DSYMS[@]}] (默认: 1 最新):${NC}"
    read -r selection
    
    if [ -z "$selection" ]; then
        selection=1
    fi
    
    if [ "$selection" -ge 1 ] && [ "$selection" -le ${#FOUND_DSYMS[@]} ]; then
        SELECTED_DSYM="${FOUND_DSYMS[$((selection-1))]}"
    else
        echo -e "${RED}❌ 无效的选择${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${BLUE}📦 准备上传的 dSYM:${NC}"
echo "   路径: $SELECTED_DSYM"

# 提取 UUID
echo ""
echo -e "${BLUE}🔍 提取 UUID...${NC}"
BINARY_PATH="$SELECTED_DSYM/Contents/Resources/DWARF/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}❌ 找不到 DWARF 文件: $BINARY_PATH${NC}"
    exit 1
fi

UUID=$(dwarfdump --uuid "$BINARY_PATH" | grep "UUID:" | head -1 | awk '{print $2}')
ARCH=$(dwarfdump --uuid "$BINARY_PATH" | grep "UUID:" | head -1 | awk '{print $3}' | tr -d '()')

if [ -z "$UUID" ]; then
    echo -e "${YELLOW}⚠️  无法提取 UUID，但继续上传${NC}"
else
    echo -e "${GREEN}   UUID: $UUID${NC}"
    echo -e "${GREEN}   架构: $ARCH${NC}"
fi

# 创建临时目录
TEMP_DIR=$(mktemp -d)
ZIP_FILE="$TEMP_DIR/$APP_NAME.dSYM.zip"

echo ""
echo -e "${BLUE}📦 打包 dSYM...${NC}"
cd "$(dirname "$SELECTED_DSYM")"
zip -r -q "$ZIP_FILE" "$(basename "$SELECTED_DSYM")"

ZIP_SIZE=$(du -h "$ZIP_FILE" | awk '{print $1}')
echo -e "${GREEN}   文件大小: $ZIP_SIZE${NC}"
echo "   临时文件: $ZIP_FILE"

# 上传到服务器
echo ""
echo -e "${BLUE}📤 上传到服务器...${NC}"
echo "   服务器: $SERVER_URL"

UPLOAD_URL="$SERVER_URL/api/dsym/upload"
RESPONSE=$(curl -s -w "\n%{http_code}" -F "file=@$ZIP_FILE" "$UPLOAD_URL")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

# 清理临时文件
rm -rf "$TEMP_DIR"

# 检查结果
if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}✅ 上传成功！${NC}"
    echo ""
    
    # 解析响应
    if command -v jq &> /dev/null; then
        SERVER_UUID=$(echo "$BODY" | jq -r '.uuid // empty')
        SERVER_ARCH=$(echo "$BODY" | jq -r '.arch // empty')
        SERVER_SIZE=$(echo "$BODY" | jq -r '.size // empty')
        
        if [ -n "$SERVER_UUID" ]; then
            echo -e "${BLUE}📋 服务器信息:${NC}"
            echo "   UUID: $SERVER_UUID"
            [ -n "$SERVER_ARCH" ] && echo "   架构: $SERVER_ARCH"
            [ -n "$SERVER_SIZE" ] && echo "   大小: $SERVER_SIZE bytes"
        fi
    else
        echo -e "${BLUE}📋 服务器响应:${NC}"
        echo "$BODY"
    fi
    
    echo ""
    echo -e "${GREEN}🎉 完成！${NC}"
    echo -e "${BLUE}💡 查看符号表:${NC} $SERVER_URL/#dsyms"
    
else
    echo -e "${RED}❌ 上传失败 (HTTP $HTTP_CODE)${NC}"
    echo ""
    echo "响应内容:"
    echo "$BODY"
    exit 1
fi

