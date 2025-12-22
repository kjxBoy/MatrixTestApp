#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Matrix 符号表上传工具
自动查找、打包并上传 dSYM 到服务器
"""

import os
import sys
import subprocess
import json
import zipfile
import tempfile
import time
from pathlib import Path
from datetime import datetime
import requests

# 配置
APP_NAME = "MatrixTestApp"
SERVER_URL = os.environ.get("MATRIX_SERVER_URL", "http://localhost:8080")
DERIVED_DATA_PATH = Path.home() / "Library/Developer/Xcode/DerivedData"

# 颜色输出
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'  # No Color

def print_color(text, color):
    """彩色输出"""
    print(f"{color}{text}{Colors.NC}")

def print_header(text):
    """打印标题"""
    print_color(f"\n{text}", Colors.BLUE)

def print_success(text):
    """打印成功消息"""
    print_color(f"✅ {text}", Colors.GREEN)

def print_error(text):
    """打印错误消息"""
    print_color(f"❌ {text}", Colors.RED)

def print_warning(text):
    """打印警告消息"""
    print_color(f"⚠️  {text}", Colors.YELLOW)

def print_info(text):
    """打印信息"""
    print_color(f"💡 {text}", Colors.CYAN)

def check_server():
    """检查服务器是否运行"""
    print_header("📡 检查服务器连接...")
    try:
        response = requests.get(f"{SERVER_URL}/api/health", timeout=3)
        if response.status_code == 200:
            print_success("服务器运行正常")
            return True
    except:
        pass
    
    print_error(f"无法连接到服务器: {SERVER_URL}")
    print_info("请先启动服务器:")
    print("   cd matrix-symbolicate-server")
    print("   ./start.sh")
    return False

def find_dsyms():
    """查找所有 dSYM 文件"""
    print_header(f"🔍 查找 {APP_NAME} 的 dSYM...")
    
    patterns = [
        f"**/Build/Products/Debug-iphonesimulator/{APP_NAME}.app.dSYM",
        f"**/Build/Products/Debug-iphoneos/{APP_NAME}.app.dSYM",
        f"**/Build/Products/Release-iphonesimulator/{APP_NAME}.app.dSYM",
        f"**/Build/Products/Release-iphoneos/{APP_NAME}.app.dSYM",
    ]
    
    dsyms = []
    for pattern in patterns:
        dsyms.extend(DERIVED_DATA_PATH.glob(pattern))
    
    if not dsyms:
        print_error("未找到 dSYM 文件")
        print()
        print_info("请确保:")
        print("   1. 已在 Xcode 中编译过应用 (Cmd+B)")
        print("   2. Build Settings → Debug Information Format = DWARF with dSYM")
        print("   3. DerivedData 未被清理")
        print()
        print(f"DerivedData 路径: {DERIVED_DATA_PATH}")
        return []
    
    # 按修改时间排序
    dsyms_with_time = [(dsym, dsym.stat().st_mtime) for dsym in dsyms]
    dsyms_with_time.sort(key=lambda x: x[1], reverse=True)
    
    print_success(f"找到 {len(dsyms)} 个 dSYM 文件")
    print()
    
    return dsyms_with_time

def extract_uuid(dsym_path):
    """提取 dSYM 的 UUID"""
    binary_path = dsym_path / "Contents/Resources/DWARF" / APP_NAME
    
    if not binary_path.exists():
        return None, None
    
    try:
        result = subprocess.run(
            ['dwarfdump', '--uuid', str(binary_path)],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            if lines:
                parts = lines[0].split()
                uuid = parts[1] if len(parts) > 1 else None
                arch = parts[2].strip('()') if len(parts) > 2 else None
                return uuid, arch
    except:
        pass
    
    return None, None

def display_dsyms(dsyms_with_time):
    """显示所有 dSYM 并让用户选择"""
    for i, (dsym, mtime) in enumerate(dsyms_with_time, 1):
        mod_time = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
        
        if i == 1:
            print_color(f"  [{i}] {dsym}", Colors.GREEN)
            print_color(f"      编译时间: {mod_time} (最新)", Colors.GREEN)
        else:
            print(f"  [{i}] {dsym}")
            print(f"      编译时间: {mod_time}")
    print()

def create_zip(dsym_path):
    """打包 dSYM 为 zip"""
    print_header("📦 打包 dSYM...")
    
    temp_dir = tempfile.mkdtemp()
    zip_path = Path(temp_dir) / f"{APP_NAME}.dSYM.zip"
    
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(dsym_path):
            for file in files:
                file_path = Path(root) / file
                arcname = file_path.relative_to(dsym_path.parent)
                zipf.write(file_path, arcname)
    
    size = zip_path.stat().st_size
    size_mb = size / (1024 * 1024)
    
    print_success(f"文件大小: {size_mb:.2f} MB")
    print(f"   临时文件: {zip_path}")
    
    return zip_path

def upload_dsym(zip_path):
    """上传 dSYM 到服务器"""
    print_header("📤 上传到服务器...")
    print(f"   服务器: {SERVER_URL}")
    
    upload_url = f"{SERVER_URL}/api/dsym/upload"
    
    try:
        with open(zip_path, 'rb') as f:
            files = {'file': (zip_path.name, f, 'application/zip')}
            response = requests.post(upload_url, files=files, timeout=60)
        
        if response.status_code == 200:
            print_success("上传成功！")
            print()
            
            try:
                data = response.json()
                print_header("📋 服务器信息:")
                if 'uuid' in data:
                    print(f"   UUID: {data['uuid']}")
                if 'arch' in data:
                    print(f"   架构: {data['arch']}")
                if 'size' in data:
                    size_mb = data['size'] / (1024 * 1024)
                    print(f"   大小: {size_mb:.2f} MB")
            except:
                print_header("📋 服务器响应:")
                print(response.text)
            
            print()
            print_success("🎉 完成！")
            print_info(f"查看符号表: {SERVER_URL}/#dsyms")
            return True
        else:
            print_error(f"上传失败 (HTTP {response.status_code})")
            print()
            print("响应内容:")
            print(response.text)
            return False
            
    except Exception as e:
        print_error(f"上传失败: {e}")
        return False

def main():
    """主函数"""
    print_color("\n🚀 Matrix 符号表上传工具", Colors.BLUE)
    print("================================")
    
    # 检查服务器
    if not check_server():
        sys.exit(1)
    
    # 查找 dSYM
    dsyms_with_time = find_dsyms()
    if not dsyms_with_time:
        sys.exit(1)
    
    # 显示所有 dSYM
    display_dsyms(dsyms_with_time)
    
    # 选择 dSYM
    if len(dsyms_with_time) == 1:
        selected_dsym = dsyms_with_time[0][0]
        print_color("📦 使用唯一的 dSYM", Colors.BLUE)
    else:
        try:
            selection = input(f"请选择要上传的 dSYM [1-{len(dsyms_with_time)}] (默认: 1 最新): ").strip()
            if not selection:
                selection = 1
            else:
                selection = int(selection)
            
            if 1 <= selection <= len(dsyms_with_time):
                selected_dsym = dsyms_with_time[selection - 1][0]
            else:
                print_error("无效的选择")
                sys.exit(1)
        except (ValueError, KeyboardInterrupt):
            print_error("\n操作取消")
            sys.exit(1)
    
    print()
    print_color("📦 准备上传的 dSYM:", Colors.BLUE)
    print(f"   路径: {selected_dsym}")
    
    # 提取 UUID
    print_header("🔍 提取 UUID...")
    uuid, arch = extract_uuid(selected_dsym)
    if uuid:
        print_success(f"UUID: {uuid}")
        print_success(f"架构: {arch}")
    else:
        print_warning("无法提取 UUID，但继续上传")
    
    # 打包
    zip_path = create_zip(selected_dsym)
    
    # 上传
    success = upload_dsym(zip_path)
    
    # 清理
    try:
        zip_path.unlink()
        zip_path.parent.rmdir()
    except:
        pass
    
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print_error("\n\n操作取消")
        sys.exit(1)

