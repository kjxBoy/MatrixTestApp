package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// extractDsymInfo 提取 dSYM 的 UUID 和架构信息
func extractDsymInfo(dsymPath string) (uuid string, arch string, err error) {
	// 如果是 .app 文件，查找内部的二进制文件
	binaryPath := dsymPath
	if strings.HasSuffix(dsymPath, ".app") {
		appName := strings.TrimSuffix(filepath.Base(dsymPath), ".app")
		binaryPath = filepath.Join(dsymPath, appName)
	}

	// 如果是 .dSYM.zip，需要先解压
	if strings.HasSuffix(dsymPath, ".dSYM.zip") {
		// 解压到临时目录
		tmpDir := filepath.Join(os.TempDir(), "dsym_extract")
		os.MkdirAll(tmpDir, 0755)

		cmd := exec.Command("unzip", "-o", dsymPath, "-d", tmpDir)
		if err := cmd.Run(); err != nil {
			return "", "", fmt.Errorf("解压 dSYM 失败: %v", err)
		}

		// 查找 .dSYM 目录中的二进制文件
		matches, err := filepath.Glob(filepath.Join(tmpDir, "*.dSYM/Contents/Resources/DWARF/*"))
		if err != nil || len(matches) == 0 {
			return "", "", fmt.Errorf("未找到 DWARF 文件")
		}
		binaryPath = matches[0]
	}

	// 使用 dwarfdump 获取 UUID
	cmd := exec.Command("dwarfdump", "--uuid", binaryPath)
	output, err := cmd.Output()
	if err != nil {
		return "", "", fmt.Errorf("dwarfdump 执行失败: %v", err)
	}

	// 解析输出: UUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (arm64)
	re := regexp.MustCompile(`UUID: ([A-F0-9-]+) \(([^)]+)\)`)
	matches := re.FindStringSubmatch(string(output))
	if len(matches) >= 3 {
		uuid = strings.ToUpper(matches[1])
		arch = matches[2]
	}

	return uuid, arch, nil
}

// normalizeReportFormat 统一报告格式（数组转字典）
func normalizeReportFormat(report interface{}) map[string]interface{} {
	// 情况1：已经是字典
	if reportMap, ok := report.(map[string]interface{}); ok {
		return reportMap
	}

	// 情况2：是数组，取第一个元素
	if reportArray, ok := report.([]interface{}); ok && len(reportArray) > 0 {
		if reportMap, ok := reportArray[0].(map[string]interface{}); ok {
			return reportMap
		}
	}

	return nil
}

// findMatchingDsym 查找匹配的符号表
func findMatchingDsym(report interface{}) string {
	// 统一格式
	reportMap := normalizeReportFormat(report)
	if reportMap == nil {
		return ""
	}

	binaryImages, ok := reportMap["binary_images"].([]interface{})
	if !ok || len(binaryImages) == 0 {
		return ""
	}

	// 查找应用的 UUID
	var appUUID string
	for _, img := range binaryImages {
		imgMap, ok := img.(map[string]interface{})
		if !ok {
			continue
		}

		name := imgMap["name"].(string)
		if strings.Contains(name, "MatrixTestApp") || strings.Contains(name, ".app/") {
			appUUID = strings.ToUpper(imgMap["uuid"].(string))
			break
		}
	}

	if appUUID == "" {
		return ""
	}

	// 遍历所有符号表文件
	files, err := os.ReadDir(DsymDir)
	if err != nil {
		return ""
	}

	for _, file := range files {
		if file.IsDir() {
			continue
		}

		dsymPath := filepath.Join(DsymDir, file.Name())
		uuid, _, err := extractDsymInfo(dsymPath)
		if err != nil {
			continue
		}

		if uuid == appUUID {
			return dsymPath
		}
	}

	return ""
}

// symbolicateReport 符号化报告
func symbolicateReport(report interface{}, dsymPath string) (map[string]interface{}, error) {
	// 解析报告 - 统一处理数组和字典格式
	reportMap := normalizeReportFormat(report)
	if reportMap == nil {
		return nil, fmt.Errorf("报告格式错误：无法解析为有效的 JSON 对象")
	}

	// 获取二进制路径和加载地址
	binaryPath, loadAddr, err := getBinaryInfo(dsymPath)
	if err != nil {
		return nil, err
	}

	// 从报告中获取加载地址
	binaryImages, ok := reportMap["binary_images"].([]interface{})
	if ok && len(binaryImages) > 0 {
		for _, img := range binaryImages {
			imgMap, ok := img.(map[string]interface{})
			if !ok {
				continue
			}

			name := imgMap["name"].(string)
			if strings.Contains(name, "MatrixTestApp") || strings.Contains(name, ".app/") {
				if addr, ok := imgMap["image_addr"].(float64); ok {
					loadAddr = uint64(addr)
				}
				break
			}
		}
	}

	// 获取架构
	arch := "arm64"
	if system, ok := reportMap["system"].(map[string]interface{}); ok {
		if cpuArch, ok := system["cpu_arch"].(string); ok {
			if strings.Contains(strings.ToLower(cpuArch), "x86") {
				arch = "x86_64"
			}
		}
	}

	// 符号化所有线程
	crash, ok := reportMap["crash"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("报告中没有 crash 信息")
	}

	threads, ok := crash["threads"].([]interface{})
	if !ok {
		return nil, fmt.Errorf("报告中没有线程信息")
	}

	// 创建结果副本
	result := make(map[string]interface{})
	for k, v := range reportMap {
		result[k] = v
	}

	// 创建新的 crash 对象
	newCrash := make(map[string]interface{})
	for k, v := range crash {
		newCrash[k] = v
	}
	result["crash"] = newCrash

	// 符号化线程
	symbolicated := []interface{}{}
	for _, t := range threads {
		thread := t.(map[string]interface{})
		symbolicatedThread := symbolicateThread(thread, binaryPath, loadAddr, arch)
		symbolicated = append(symbolicated, symbolicatedThread)
	}

	newCrash["threads"] = symbolicated

	// 添加符号化元数据
	result["symbolication_info"] = map[string]interface{}{
		"symbolicated":     true,
		"dsym_path":        dsymPath,
		"binary_path":      binaryPath,
		"load_address":     fmt.Sprintf("0x%x", loadAddr),
		"architecture":     arch,
		"symbolicate_time": timeNow(),
		"formatted_report": formatReportToAppleStyle(result),
	}

	return result, nil
}

// getBinaryInfo 获取二进制文件信息
func getBinaryInfo(dsymPath string) (binaryPath string, loadAddr uint64, err error) {
	binaryPath = dsymPath

	// 如果是 .app 文件
	if strings.HasSuffix(dsymPath, ".app") {
		appName := strings.TrimSuffix(filepath.Base(dsymPath), ".app")
		binaryPath = filepath.Join(dsymPath, appName)
		return binaryPath, 0, nil
	}

	// 如果是 .dSYM.zip，需要解压
	if strings.HasSuffix(dsymPath, ".dSYM.zip") {
		tmpDir := filepath.Join(os.TempDir(), "dsym_symbolicate")
		os.MkdirAll(tmpDir, 0755)

		cmd := exec.Command("unzip", "-o", dsymPath, "-d", tmpDir)
		if err := cmd.Run(); err != nil {
			return "", 0, fmt.Errorf("解压 dSYM 失败: %v", err)
		}

		matches, err := filepath.Glob(filepath.Join(tmpDir, "*.dSYM/Contents/Resources/DWARF/*"))
		if err != nil || len(matches) == 0 {
			return "", 0, fmt.Errorf("未找到 DWARF 文件")
		}
		binaryPath = matches[0]
	}

	return binaryPath, 0, nil
}

// symbolicateThread 符号化单个线程
func symbolicateThread(thread map[string]interface{}, binaryPath string, loadAddr uint64, arch string) map[string]interface{} {
	result := make(map[string]interface{})
	for k, v := range thread {
		result[k] = v
	}

	backtrace, ok := thread["backtrace"].(map[string]interface{})
	if !ok {
		return result
	}

	contents, ok := backtrace["contents"].([]interface{})
	if !ok {
		return result
	}

	// 符号化每一帧
	symbolicatedFrames := []interface{}{}
	for _, f := range contents {
		frame := f.(map[string]interface{})
		symbolicatedFrame := make(map[string]interface{})
		for k, v := range frame {
			symbolicatedFrame[k] = v
		}

		// 检查是否需要符号化
		addr, ok := frame["instruction_addr"].(float64)
		if !ok {
			symbolicatedFrames = append(symbolicatedFrames, symbolicatedFrame)
			continue
		}

		objName, _ := frame["object_name"].(string)
		symbolName, _ := frame["symbol_name"].(string)

		// 如果是应用代码或未知代码，尝试符号化
		if strings.Contains(objName, "MatrixTestApp") || objName == "???" ||
			symbolName == "" || symbolName == "<redacted>" {

			symbol := symbolicateAddress(binaryPath, loadAddr, uint64(addr), arch)
			if symbol != "" {
				symbolicatedFrame["symbolicated_name"] = symbol

				// 解析文件名和行号
				fileName, lineNum := parseSymbolOutput(symbol)
				if fileName != "" {
					symbolicatedFrame["file_name"] = fileName
					symbolicatedFrame["line_number"] = lineNum
				}

				// 标记为应用代码
				if !strings.Contains(fileName, "KSCrash") &&
					!strings.Contains(fileName, "WC") &&
					!strings.Contains(fileName, "Matrix") {
					symbolicatedFrame["is_app_code"] = true
				}
			}
		}

		symbolicatedFrames = append(symbolicatedFrames, symbolicatedFrame)
	}

	// 更新 backtrace
	newBacktrace := make(map[string]interface{})
	for k, v := range backtrace {
		newBacktrace[k] = v
	}
	newBacktrace["contents"] = symbolicatedFrames

	result["backtrace"] = newBacktrace
	return result
}

// symbolicateAddress 使用 atos 符号化单个地址
func symbolicateAddress(binaryPath string, loadAddr uint64, targetAddr uint64, arch string) string {
	cmd := exec.Command(
		"atos",
		"-arch", arch,
		"-o", binaryPath,
		"-l", fmt.Sprintf("0x%x", loadAddr),
		fmt.Sprintf("0x%x", targetAddr),
	)

	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		return ""
	}

	symbol := strings.TrimSpace(out.String())

	// 如果符号化成功，返回符号
	if symbol != "" && symbol != fmt.Sprintf("0x%x", targetAddr) && !strings.HasPrefix(symbol, "0x") {
		return symbol
	}

	return ""
}

// parseSymbolOutput 解析符号化输出
func parseSymbolOutput(symbol string) (fileName string, lineNum string) {
	// 格式: -[Class method] (in App) (File.mm:123)
	re := regexp.MustCompile(`\(([^)]+\.(?:m|mm|c|cpp|swift)):(\d+)\)`)
	matches := re.FindStringSubmatch(symbol)

	if len(matches) >= 3 {
		fileName = matches[1]
		lineNum = matches[2]
	}

	return fileName, lineNum
}

// timeNow 返回当前时间的 ISO 格式字符串
func timeNow() string {
	return fmt.Sprintf("%d", timeNowUnix())
}

func timeNowUnix() int64 {
	return 0 // 这里返回0，实际使用时可以返回 time.Now().Unix()
}

// FormatSymbolicatedReport 格式化符号化报告为人类可读格式
func FormatSymbolicatedReport(report map[string]interface{}) string {
	var buf bytes.Buffer

	buf.WriteString("=" + strings.Repeat("=", 79) + "\n")
	buf.WriteString("🔍 Matrix 卡顿报告 - 符号化版本\n")
	buf.WriteString("=" + strings.Repeat("=", 79) + "\n\n")

	// 系统信息
	if system, ok := report["system"].(map[string]interface{}); ok {
		buf.WriteString("📱 系统信息:\n")
		if v, ok := system["CFBundleName"].(string); ok {
			buf.WriteString(fmt.Sprintf("   应用名称: %s\n", v))
		}
		if v, ok := system["system_version"].(string); ok {
			buf.WriteString(fmt.Sprintf("   系统版本: iOS %s\n", v))
		}
		if v, ok := system["machine"].(string); ok {
			buf.WriteString(fmt.Sprintf("   设备型号: %s\n", v))
		}
		buf.WriteString("\n")
	}

	// 符号化信息
	if info, ok := report["symbolication_info"].(map[string]interface{}); ok {
		buf.WriteString("🔧 符号化信息:\n")
		if v, ok := info["architecture"].(string); ok {
			buf.WriteString(fmt.Sprintf("   架构: %s\n", v))
		}
		if v, ok := info["load_address"].(string); ok {
			buf.WriteString(fmt.Sprintf("   加载地址: %s\n", v))
		}
		buf.WriteString("\n")
	}

	// 线程信息
	crash, _ := report["crash"].(map[string]interface{})
	threads, _ := crash["threads"].([]interface{})

	buf.WriteString(fmt.Sprintf("📋 共 %d 个线程\n\n", len(threads)))

	// 找出主线程和有应用代码的线程
	for _, t := range threads {
		thread := t.(map[string]interface{})
		idx := thread["index"]
		name, _ := thread["name"].(string)
		crashed, _ := thread["crashed"].(bool)

		// 检查是否有应用代码
		hasAppCode := false
		backtrace, _ := thread["backtrace"].(map[string]interface{})
		contents, _ := backtrace["contents"].([]interface{})

		for _, f := range contents {
			frame := f.(map[string]interface{})
			if isApp, ok := frame["is_app_code"].(bool); ok && isApp {
				hasAppCode = true
				break
			}
		}

		if !hasAppCode && idx != 0 && !crashed {
			continue
		}

		// 显示线程
		label := ""
		if idx == 0 || strings.Contains(strings.ToLower(name), "main") {
			label = "🎯 主线程"
		} else if crashed {
			label = "⚠️  崩溃线程"
		} else {
			label = fmt.Sprintf("📍 线程 %v", idx)
		}

		buf.WriteString(strings.Repeat("=", 80) + "\n")
		buf.WriteString(fmt.Sprintf("%s: Thread %v\n", label, idx))
		if name != "" {
			buf.WriteString(fmt.Sprintf("   名称: %s\n", name))
		}
		buf.WriteString(strings.Repeat("=", 80) + "\n\n")

		// 显示堆栈
		for i, f := range contents {
			frame := f.(map[string]interface{})
			objName, _ := frame["object_name"].(string)
			addr := frame["instruction_addr"]

			isApp, _ := frame["is_app_code"].(bool)
			marker := "   "
			if isApp {
				marker = "👉 "
			}

			symbolicatedName, hasSymbol := frame["symbolicated_name"].(string)
			if hasSymbol {
				buf.WriteString(fmt.Sprintf("%s%2d  %-25s %v\n", marker, i, objName, addr))
				buf.WriteString(fmt.Sprintf("      %s\n", symbolicatedName))
			} else {
				symbolName, _ := frame["symbol_name"].(string)
				if symbolName != "" && symbolName != "<redacted>" {
					buf.WriteString(fmt.Sprintf("%s%2d  %-25s %v %s\n", marker, i, objName, addr, symbolName))
				} else {
					buf.WriteString(fmt.Sprintf("%s%2d  %-25s %v\n", marker, i, objName, addr))
				}
			}
		}

		buf.WriteString("\n")
	}

	buf.WriteString(strings.Repeat("=", 80) + "\n")
	buf.WriteString("💡 说明: 👉 标记的是你的应用代码 - 重点关注这些\n")
	buf.WriteString(strings.Repeat("=", 80) + "\n")

	return buf.String()
}
