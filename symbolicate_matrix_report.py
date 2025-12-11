#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Matrix 报告符号化工具
自动将内存地址转换为函数名、文件名和行号
"""

import json
import sys
import os
import subprocess
import re
import glob
import argparse
from pathlib import Path

def get_binary_uuid(binary_path, arch='arm64'):
    """获取二进制文件的 UUID"""
    try:
        cmd = ['dwarfdump', '--uuid', binary_path]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            # 输出格式: UUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (arm64) /path/to/binary
            for line in result.stdout.split('\n'):
                if arch in line or 'arm64' in line:
                    match = re.search(r'UUID: ([A-F0-9-]+)', line)
                    if match:
                        return match.group(1).upper()
    except:
        pass
    return None

def find_all_possible_binaries():
    """查找所有可能的应用二进制文件"""
    binaries = []
    
    # 1. 从 DerivedData 查找
    derived_data = os.path.expanduser('~/Library/Developer/Xcode/DerivedData')
    patterns = [
        '*/Build/Products/Debug-iphonesimulator/MatrixTestApp.app/MatrixTestApp',
        '*/Build/Products/Debug-iphoneos/MatrixTestApp.app/MatrixTestApp',
        '*/Build/Products/Debug/MatrixTestApp.app/MatrixTestApp',
    ]
    
    for pattern in patterns:
        full_pattern = os.path.join(derived_data, pattern)
        matches = glob.glob(full_pattern)
        for match in matches:
            if os.path.exists(match):
                mtime = os.path.getmtime(match)
                binaries.append((match, mtime))
    
    # 按时间排序（最新的在前）
    binaries.sort(key=lambda x: x[1], reverse=True)
    
    return [b[0] for b in binaries]

def find_app_binary(report_data):
    """从报告中找到应用的二进制文件路径"""
    try:
        binary_images = report_data.get('binary_images', [])
        report_uuid = None
        load_addr = None
        simulator_path = None
        
        # 从报告中获取应用的 UUID 和加载地址
        for image in binary_images:
            name = os.path.basename(image.get('name', ''))
            # 尝试多种可能的应用名称
            if name in ['MatrixTestApp', 'MatrixTestApp.app', 'MatrixTestApp.app/MatrixTestApp']:
                simulator_path = image.get('name', '')
                load_addr = image.get('image_addr', 0)
                report_uuid = image.get('uuid', '').upper()
                break
        
        # 如果没找到，尝试使用第一个加载地址最小的镜像（通常是主程序）
        if not load_addr and binary_images:
            print("⚠️  未找到明确的应用镜像，尝试使用第一个镜像")
            first_image = min(binary_images, key=lambda x: x.get('image_addr', float('inf')))
            simulator_path = first_image.get('name', '')
            load_addr = first_image.get('image_addr', 0)
            report_uuid = first_image.get('uuid', '').upper()
        
        if not load_addr:
            print("⚠️  报告中没有找到应用的二进制信息")
            return None, None
        
        print(f"📋 报告信息:")
        print(f"   原始路径: {simulator_path}")
        if report_uuid:
            print(f"   UUID: {report_uuid}")
        print()
        
        # 先尝试报告中的路径（虽然通常不可用）
        if simulator_path and os.path.exists(simulator_path):
            print(f"✅ 使用报告中的路径")
            return simulator_path, load_addr
        
        # 查找所有可能的二进制文件
        print("🔍 从 DerivedData 查找二进制文件...")
        candidates = find_all_possible_binaries()
        
        if not candidates:
            print("❌ 未找到任何二进制文件")
            print()
            print("请确保:")
            print("  1. 已在 Xcode 中编译过应用")
            print("  2. DerivedData 未被清理")
            print()
            return None, load_addr
        
        print(f"找到 {len(candidates)} 个候选文件:")
        print()
        
        # 如果报告有 UUID，尝试匹配
        if report_uuid:
            for candidate in candidates:
                binary_uuid = get_binary_uuid(candidate)
                print(f"  📦 {os.path.basename(os.path.dirname(candidate))}")
                print(f"     路径: {candidate}")
                print(f"     UUID: {binary_uuid if binary_uuid else '(无法获取)'}")
                
                if binary_uuid and binary_uuid == report_uuid:
                    print(f"     ✅ UUID 匹配！")
                    print()
                    return candidate, load_addr
                elif binary_uuid:
                    print(f"     ⚠️  UUID 不匹配")
                print()
        
        # 如果没有 UUID 或没有匹配，使用最新的
        print("⚠️  无法通过 UUID 匹配，使用最新的二进制文件")
        latest = candidates[0]
        print(f"💡 选择: {latest}")
        print()
        print("⚠️  警告: 二进制文件可能与报告不匹配")
        print("   建议: 重新运行应用并立即生成新报告")
        print()
        
        return latest, load_addr
        
    except Exception as e:
        print(f"❌ 查找二进制文件时出错: {e}")
        import traceback
        traceback.print_exc()
    return None, None

def get_cpu_arch(report_data):
    """获取 CPU 架构"""
    try:
        system = report_data.get('system', {})
        cpu_arch = system.get('cpu_arch', '')
        if 'arm64' in cpu_arch.lower() or 'arm' in cpu_arch.lower():
            return 'arm64'
        elif 'x86_64' in cpu_arch.lower():
            return 'x86_64'
    except:
        pass
    return 'arm64'  # 默认

def symbolicate_address(binary_path, load_addr, target_addr, arch='arm64', verbose=False):
    """使用 atos 符号化单个地址"""
    try:
        cmd = [
            'atos',
            '-arch', arch,
            '-o', binary_path,
            '-l', hex(load_addr),
            hex(target_addr)
        ]
        
        if verbose:
            print(f"     执行命令: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        
        if verbose:
            print(f"     返回码: {result.returncode}")
            print(f"     输出: {result.stdout.strip()}")
            if result.stderr:
                print(f"     错误: {result.stderr.strip()}")
        
        if result.returncode == 0:
            symbol = result.stdout.strip()
            # 如果符号化成功，会返回类似：
            # -[TestLagViewController simulateLag] (in MatrixTestApp) (TestLagViewController.mm:145)
            if symbol and symbol != hex(target_addr) and '0x' not in symbol:
                return symbol
    except Exception as e:
        if verbose:
            print(f"     异常: {e}")
    
    return None

def parse_symbol_output(symbol_str, verbose=False):
    """解析符号化输出"""
    # 尝试提取文件名和行号
    # 格式: -[Class method] (in App) (File.m:123) 或 (File.mm:123) 或 (File.c:123)
    if verbose:
        print(f"     [parse] 输入: {symbol_str}")
    
    match = re.search(r'\(([^)]+\.(?:m|mm|c|cpp|swift)):(\d+)\)', symbol_str)
    if match:
        file_name = match.group(1)
        line_num = match.group(2)
        
        if verbose:
            print(f"     [parse] 成功: file={file_name}, line={line_num}")
        
        return file_name, line_num
    
    if verbose:
        print(f"     [parse] 失败: 未匹配")
    
    return None, None

def find_library_for_address(address, binary_images):
    """根据地址找到对应的库"""
    for image in binary_images:
        image_addr = image.get('image_addr', 0)
        image_size = image.get('image_size', 0)
        
        if image_addr <= address < image_addr + image_size:
            name = image.get('name', '')
            # 返回库的基本名称
            base_name = os.path.basename(name)
            
            # 简化常见系统库名称
            if base_name.startswith('libsystem_'):
                return 'libsystem_*'
            elif base_name.startswith('libobjc'):
                return 'libobjc (Obj-C Runtime)'
            elif base_name.startswith('libdispatch'):
                return 'libdispatch (GCD)'
            elif 'UIKitCore' in base_name or 'UIKit' in base_name:
                return 'UIKit'
            elif 'CoreFoundation' in base_name:
                return 'CoreFoundation'
            elif 'Foundation' in base_name:
                return 'Foundation'
            elif 'QuartzCore' in base_name:
                return 'QuartzCore'
            elif 'GraphicsServices' in base_name:
                return 'GraphicsServices'
            elif 'dyld' in base_name.lower():
                return 'dyld (动态链接器)'
            
            return base_name
    
    return None

def symbolicate_report(report_path, output_file=None, verbose=False):
    """符号化整个报告"""
    
    # 检查文件是否存在
    if not os.path.exists(report_path):
        print(f"❌ 文件不存在: {report_path}")
        return
    
    # 如果指定了输出文件，重定向输出
    original_stdout = sys.stdout
    if output_file:
        try:
            output_handle = open(output_file, 'w', encoding='utf-8')
            sys.stdout = output_handle
            # 同时在终端显示一条消息
            print(f"📝 符号化结果将保存到: {output_file}", file=original_stdout)
        except Exception as e:
            print(f"❌ 无法创建输出文件: {e}", file=original_stdout)
            return
    
    # 读取 JSON
    try:
        with open(report_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        print(f"❌ 读取文件失败: {e}")
        return
    
    print("=" * 80)
    print("🔍 Matrix 报告符号化工具")
    print("=" * 80)
    print()
    
    # 查找应用二进制文件
    binary_path, load_addr = find_app_binary(data)
    if not binary_path or not load_addr:
        print("❌ 无法从报告中找到应用二进制文件信息")
        return
    
    print(f"📱 应用二进制: {binary_path}")
    print(f"📍 加载地址: {hex(load_addr)}")
    
    # 调试：打印所有 binary_images
    if verbose:
        print()
        print("📦 报告中的所有模块:")
        binary_images = data.get('binary_images', [])
        for img in binary_images[:10]:  # 只显示前10个
            print(f"   - {os.path.basename(img.get('name', '???'))}: {hex(img.get('image_addr', 0))}")
        if len(binary_images) > 10:
            print(f"   ... (还有 {len(binary_images) - 10} 个模块)")
        print()
    
    # 检查二进制文件是否存在
    if not os.path.exists(binary_path):
        print(f"⚠️  警告: 二进制文件不存在")
        print(f"   路径: {binary_path}")
        print(f"   提示: 可能需要重新编译应用")
        return
    
    # 获取架构
    arch = get_cpu_arch(data)
    print(f"🖥️  CPU 架构: {arch}")
    print()
    
    # 获取线程信息
    crash_info = data.get('crash', {})
    threads = crash_info.get('threads', [])
    
    if not threads:
        print("❌ 报告中没有线程信息")
        return
    
    # 分析所有线程
    app_name = 'MatrixTestApp'
    
    print("🔍 分析所有线程...")
    print()
    
    # 找出所有重要的线程
    main_thread = None
    crashed_thread = None
    app_code_threads = []
    
    for thread in threads:
        thread_idx = thread.get('index', '?')
        thread_name = thread.get('name', '未命名')
        is_crashed = thread.get('crashed', False)
        
        backtrace = thread.get('backtrace', {})
        frames = backtrace.get('contents', [])
        
        # 检查是否有应用代码
        has_app_code = False
        for frame in frames:
            obj_name = frame.get('object_name', '')
            if app_name in obj_name:
                has_app_code = True
                break
        
        # 判断是否是主线程
        if thread_idx == 0 or 'main' in thread_name.lower():
            main_thread = thread
        
        if is_crashed:
            crashed_thread = thread
        
        if has_app_code:
            app_code_threads.append(thread)
    
    # 决定要显示哪些线程
    threads_to_show = []
    
    # 优先显示主线程（最重要）
    if main_thread:
        threads_to_show.append(('主线程', main_thread))
        print(f"✅ 找到主线程: Thread {main_thread.get('index', '?')} - {main_thread.get('name', '未命名')}")
    
    # 然后是崩溃线程
    if crashed_thread and crashed_thread != main_thread:
        threads_to_show.append(('崩溃线程', crashed_thread))
        print(f"⚠️  找到崩溃线程: Thread {crashed_thread.get('index', '?')} - {crashed_thread.get('name', '未命名')}")
    
    # 最后是其他有应用代码的线程
    for thread in app_code_threads:
        if thread not in [main_thread, crashed_thread]:
            thread_idx = thread.get('index', '?')
            thread_name = thread.get('name', '未命名')
            threads_to_show.append((f'应用线程 {thread_idx}', thread))
            print(f"📍 找到应用代码线程: Thread {thread_idx} - {thread_name}")
    
    if not threads_to_show:
        print("❌ 无法找到重要线程")
        return
    
    print()
    
    # 获取所有二进制镜像用于查找库名
    binary_images = data.get('binary_images', [])
    
    # 符号化所有重要线程
    total_symbolicated = 0
    app_code_locations = []  # 记录所有应用代码位置
    
    for thread_label, target_thread in threads_to_show:
        print("=" * 80)
        print(f"📋 {thread_label}: Thread {target_thread.get('index', '?')}")
        print(f"   名称: {target_thread.get('name', '未命名')}")
        print("=" * 80)
        print()
        
        # 获取堆栈
        backtrace = target_thread.get('backtrace', {})
        frames = backtrace.get('contents', [])
        
        if not frames:
            print("⚠️  该线程没有堆栈信息")
            print()
            continue
        
        symbolicated_count = 0
        app_frames = []
        
        # 先统计有多少个应用栈帧
        for frame in frames:
            obj_name = frame.get('object_name', '???')
            if app_name in obj_name:
                app_frames.append(frame)
        
        print(f"📊 共 {len(frames)} 个栈帧，其中 {len(app_frames)} 个应用代码")
        print()
        
        # 如果没有识别出应用代码，尝试符号化所有栈帧
        if len(app_frames) == 0:
            print("⚠️  未识别出应用代码栈帧，将尝试符号化所有地址")
            print()
        
        print("-" * 80)
        
        for i, frame in enumerate(frames):
            obj_name = frame.get('object_name', '???')
            symbol = frame.get('symbol_name', None)
            addr = frame.get('instruction_addr', 0)
            
            if verbose and i < 3:
                print(f"[调试] Frame {i}: obj_name='{obj_name}', symbol='{symbol}', addr={hex(addr)}")
            
            # 判断是否需要符号化：
            # 1. 如果有识别出应用代码，只符号化应用代码
            # 2. 如果没有识别出应用代码，尝试符号化所有地址
            should_symbolicate = False
            
            if len(app_frames) > 0:
                # 有识别出应用代码，只符号化应用代码
                if app_name in obj_name and (not symbol or symbol == '<redacted>'):
                    should_symbolicate = True
            else:
                # 没有识别出应用代码，尝试符号化所有未知地址
                if obj_name == '???' and (not symbol or symbol == '<redacted>'):
                    should_symbolicate = True
            
            if should_symbolicate:
                symbolicated = symbolicate_address(binary_path, load_addr, addr, arch, verbose=verbose and i < 3)
                
                if symbolicated:
                    # 解析文件名和行号
                    file_name, line_num = parse_symbol_output(symbolicated, verbose=(verbose and i < 3))
                    
                    # 优化显示名称：如果 obj_name 是 ???，尝试从符号化结果或地址推断
                    display_name = obj_name
                    if obj_name == '???':
                        # 从符号化输出中提取库名 "(in LibraryName)"
                        in_match = re.search(r'\(in ([^)]+)\)', symbolicated)
                        if in_match:
                            display_name = in_match.group(1)
                        else:
                            # 如果没找到，从地址推断
                            lib_name = find_library_for_address(addr, binary_images)
                            if lib_name:
                                display_name = lib_name
                    
                    # 高亮显示应用代码（排除 Matrix 框架内部代码）
                    is_app_code = False
                    if file_name:
                        # Matrix 框架内部文件（精确匹配，不包括应用代码）
                        framework_files = (
                            'KSCrash', 'KS', 'WCCrash', 'WCBlock', 'WCMemory', 'WCFPS', 'WCDump',
                            'MatrixAdapter', 'MatrixPlugin', 'MatrixIssue', 'MatrixLog', 'MatrixDevice',
                            'MatrixPath', 'MatrixBase', 'MatrixAppReboot',
                            'logger_', 'memory_', 'stack_', 'object_'
                        )
                        # 检查文件名是否以框架前缀开头
                        is_framework = any(file_name.startswith(p) for p in framework_files)
                        is_app_code = not is_framework
                        
                        if verbose and i < 3:
                            print(f"     [标记] 文件: {file_name}, 框架代码: {is_framework}, 应用代码: {is_app_code}")
                    else:
                        # 如果没有解析出文件名，但符号化成功了，也认为是应用代码
                        is_app_code = True
                        
                        if verbose and i < 3:
                            print(f"     [标记] 未解析出文件名，默认为应用代码")
                    
                    # 决定标记
                    if is_app_code:
                        marker = "👉 "
                        # 记录应用代码位置
                        app_code_locations.append({
                            'thread': thread_label,
                            'file': file_name,
                            'line': line_num,
                            'symbol': symbolicated
                        })
                    else:
                        marker = "   "
                    
                    # 使用优化后的显示名称
                    # 如果是 MatrixTestApp 但是框架代码，添加说明
                    if display_name == 'MatrixTestApp' and file_name and any(file_name.startswith(p) for p in ('KS', 'WC')):
                        display_name = 'MatrixTestApp [框架]'
                    
                    print(f"{marker}{i:2d}  {display_name:25s} {hex(addr):18s}")
                    print(f"      {symbolicated}")
                    symbolicated_count += 1
                    total_symbolicated += 1
                else:
                    # 符号化失败，尝试找出是哪个库
                    lib_name = find_library_for_address(addr, binary_images)
                    if lib_name:
                        # 简化系统库名称显示
                        if lib_name != 'MatrixTestApp':
                            print(f"   {i:2d}  {lib_name:25s} {hex(addr):18s}")
                        else:
                            print(f"   {i:2d}  {'MatrixTestApp':25s} {hex(addr):18s} ⚠️ 符号化失败")
                    else:
                        print(f"   {i:2d}  {obj_name:25s} {hex(addr):18s} (未知库)")
            else:
                # 已有符号或非应用代码
                if symbol:
                    # 如果有符号，显示它
                    print(f"   {i:2d}  {obj_name:25s} {hex(addr):18s} {symbol}")
                else:
                    # 没有符号，尝试找出是哪个库
                    if obj_name == '???':
                        lib_name = find_library_for_address(addr, binary_images)
                        if lib_name and lib_name != 'MatrixTestApp':
                            print(f"   {i:2d}  {lib_name:25s} {hex(addr):18s}")
                        else:
                            print(f"   {i:2d}  {obj_name:25s} {hex(addr)}")
                    else:
                        print(f"   {i:2d}  {obj_name:25s} {hex(addr)}")
        
        print("-" * 80)
        print()
        
        if symbolicated_count > 0:
            print(f"✅ 该线程成功符号化 {symbolicated_count} 个地址")
        else:
            print("⚠️  该线程没有符号化任何地址")
        
        print()
    
    print("=" * 80)
    print(f"📊 总结: 共符号化 {total_symbolicated} 个地址")
    print("=" * 80)
    print()
    
    if total_symbolicated > 0:
        print("💡 如何阅读报告:")
        print("   👉 标记的是你的应用代码 - 重点关注这些")
        print("   📌 主线程的堆栈通常是导致卡顿的真正原因")
        print("   📂 文件名和行号在符号化信息中显示")
        print()
        print("📚 堆栈说明:")
        print("   👉 你的应用代码 - 重点关注（如 TestLagViewController.mm）")
        print("   • MatrixTestApp [框架] - Matrix 监控内部代码（如 KSCrash, WC*）")
        print("   • UIKit, Foundation, GCD 等 - iOS 系统框架")
        print("   ⚠️ 符号化失败 - 应用代码但缺少调试信息")
        print()
    
    # 显示所有应用代码位置
    if app_code_locations:
        print("=" * 80)
        print("🎯 发现的应用代码位置（重点关注）:")
        print("=" * 80)
        print()
        
        for loc in app_code_locations:
            thread = loc['thread']
            file_name = loc['file']
            line_num = loc['line']
            symbol = loc['symbol']
            
            if file_name and line_num:
                print(f"📍 [{thread}] {file_name}:{line_num}")
                print(f"   {symbol}")
                print()
            else:
                print(f"📍 [{thread}]")
                print(f"   {symbol}")
                print()
        
        print("=" * 80)
        print()
    
    if total_symbolicated == 0:
        print("⚠️  没有符号化任何应用代码地址")
        print()
        print("💡 说明:")
        print("   堆栈中显示的可能都是系统库代码（UIKit, Foundation等）")
        print("   这些是 iOS 系统框架，不需要符号化")
        print()
        print("🔍 如果应该有应用代码但没符号化，可能的原因:")
        print("  1. 二进制文件与报告不匹配（UUID 不同）")
        print("  2. 应用以 Release 模式编译（符号被剥离）")
        print("  3. 报告太旧，对应的二进制文件已被重新编译")
        print()
        print("💡 推荐的解决方法:")
        print("  1. 在 Xcode 中重新运行应用 (Cmd+R)")
        print("  2. 在应用中立即触发卡顿:")
        print("     Matrix 功能演示 → 卡顿监控 → 模拟主线程卡顿")
        print("  3. 立即再次运行此脚本")
        print()
        print("⚙️  或检查 Xcode 设置:")
        print("  - Build Settings → Debug Information Format = DWARF with dSYM File")
        print("  - Build Settings → Strip Debug Symbols = NO (Debug)")
    
    print()
    print("=" * 80)
    
    # 恢复标准输出并关闭文件
    if output_file:
        sys.stdout = original_stdout
        output_handle.close()
        print(f"✅ 符号化结果已保存到: {output_file}")
        print(f"📖 查看文件: open \"{output_file}\"")

def main():
    parser = argparse.ArgumentParser(
        description='Matrix 报告符号化工具 - 将内存地址转换为函数名、文件名和行号',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 只在终端显示
  python3 symbolicate_matrix_report.py report.json
  
  # 保存到文件
  python3 symbolicate_matrix_report.py report.json -o output.txt
  
  # 保存到文件并指定完整路径
  python3 symbolicate_matrix_report.py report.json -o ~/Desktop/symbolicated.txt
        """
    )
    
    parser.add_argument('report', help='Matrix 报告文件路径 (JSON 格式)')
    parser.add_argument('-o', '--output', help='输出文件路径（可选，不指定则只在终端显示）')
    parser.add_argument('-v', '--verbose', action='store_true', help='显示详细调试信息')
    
    args = parser.parse_args()
    
    symbolicate_report(args.report, args.output, args.verbose)

if __name__ == '__main__':
    main()

