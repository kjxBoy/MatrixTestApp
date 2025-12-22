#!/bin/bash

# Matrix 服务器 IP 配置脚本
# 用于快速配置真机测试的服务器地址

echo "🔧 Matrix 服务器地址配置工具"
echo "================================"
echo ""

# 获取 Mac 的 IP 地址
echo "📡 检测 Mac IP 地址..."
IP_ADDRESSES=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}')

if [ -z "$IP_ADDRESSES" ]; then
    echo "❌ 未检测到网络连接"
    echo "请确保 Mac 已连接到网络"
    exit 1
fi

echo ""
echo "找到以下 IP 地址："
echo ""

# 显示所有 IP 地址
count=1
declare -a ip_array
while IFS= read -r ip; do
    echo "  [$count] $ip"
    ip_array[$count]=$ip
    count=$((count + 1))
done <<< "$IP_ADDRESSES"

echo ""
echo "  [0] 使用 localhost (模拟器)"
echo ""

# 选择 IP
read -p "请选择要使用的 IP 地址 [0-$((count-1))]: " selection

if [ "$selection" == "0" ]; then
    SERVER_URL="http://localhost:8080"
    echo "✅ 已选择: $SERVER_URL (模拟器)"
elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$count" ]; then
    selected_ip=${ip_array[$selection]}
    SERVER_URL="http://$selected_ip:8080"
    echo "✅ 已选择: $SERVER_URL (真机)"
else
    echo "❌ 无效的选择"
    exit 1
fi

echo ""

# 更新 Info.plist
PLIST_PATH="./MatrixTestApp/Info.plist"

if [ ! -f "$PLIST_PATH" ]; then
    echo "❌ 找不到 Info.plist 文件"
    echo "请确保在项目根目录运行此脚本"
    exit 1
fi

echo "📝 更新 Info.plist..."

# 使用 PlistBuddy 更新配置
/usr/libexec/PlistBuddy -c "Set :MatrixServerURL $SERVER_URL" "$PLIST_PATH" 2>/dev/null

if [ $? -ne 0 ]; then
    # 如果键不存在，则添加
    /usr/libexec/PlistBuddy -c "Add :MatrixServerURL string $SERVER_URL" "$PLIST_PATH"
fi

echo "✅ 配置已更新！"
echo ""
echo "📱 下一步："
echo "   1. 在 Xcode 中重新编译应用 (Cmd+B)"
echo "   2. 运行到设备上 (Cmd+R)"
echo "   3. 触发卡顿并查看自动上报"
echo ""
echo "🌐 服务器地址: $SERVER_URL"
echo "   访问 Web 界面: $SERVER_URL"
echo ""

# 测试连接
echo "🔍 测试服务器连接..."
if curl -s --connect-timeout 2 "$SERVER_URL/api/health" > /dev/null 2>&1; then
    echo "✅ 服务器运行正常！"
else
    echo "⚠️  无法连接到服务器"
    echo ""
    echo "请确保符号化服务正在运行："
    echo "  cd matrix-symbolicate-server"
    echo "  ./start.sh"
fi

echo ""
echo "完成！🎉"

