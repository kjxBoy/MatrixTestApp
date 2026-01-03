package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// ============================================================================
// Swift 支持相关函数
// ============================================================================

// isSwiftSymbol 检测是否是 Swift mangled 符号
func isSwiftSymbol(symbol string) bool {
	// Swift 符号特征：
	// - 以 $s 或 _$s 开头（Swift 5.0+）
	// - 以 $S 或 _$S 开头（Swift 4.x）
	// - 以 _T 开头（Swift 3.x, 已弃用）
	return strings.HasPrefix(symbol, "$s") ||
		strings.HasPrefix(symbol, "_$s") ||
		strings.HasPrefix(symbol, "$S") ||
		strings.HasPrefix(symbol, "_$S") ||
		strings.HasPrefix(symbol, "_T")
}

// demangleSwiftSymbol 使用 swift demangle 工具解码 Swift 符号
func demangleSwiftSymbol(mangledSymbol string) string {
	// 尝试使用 swift demangle 命令
	cmd := exec.Command("swift", "demangle", mangledSymbol)

	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		log.Printf("⚠️ Swift demangle 失败: %v, 符号: %s", err, mangledSymbol)
		return mangledSymbol // 失败则返回原始符号
	}

	demangled := strings.TrimSpace(out.String())

	// swift demangle 输出格式: "原始符号 ---> 解码后的符号"
	if strings.Contains(demangled, "--->") {
		parts := strings.Split(demangled, "--->")
		if len(parts) >= 2 {
			demangled = strings.TrimSpace(parts[1])
		}
	}

	// 如果解码成功且不同于原始符号
	if demangled != "" && demangled != mangledSymbol {
		log.Printf("✅ Swift demangle 成功:")
		log.Printf("   原始: %s", mangledSymbol)
		log.Printf("   解码: %s", demangled)
		return demangled
	}

	return mangledSymbol
}

// detectSymbolLanguage 检测符号的编程语言类型
func detectSymbolLanguage(symbol string) string {
	if isSwiftSymbol(symbol) {
		return "Swift"
	}

	// Objective-C 符号特征
	if strings.HasPrefix(symbol, "-[") || strings.HasPrefix(symbol, "+[") {
		return "Objective-C"
	}

	// C++ 符号特征（mangled）
	if strings.HasPrefix(symbol, "_Z") {
		return "C++"
	}

	// C 符号（未 mangled）
	return "C/Other"
}

// isSymbolWellFormatted 检查符号是否格式良好（已正确符号化）
func isSymbolWellFormatted(symbol string) bool {
	// 如果是地址，说明符号化失败
	if strings.HasPrefix(symbol, "0x") {
		return false
	}

	// 如果是 mangled 符号，说明未 demangle
	if isSwiftSymbol(symbol) {
		return false
	}

	// 如果包含 "???" 或 "unknown"
	if strings.Contains(symbol, "???") || strings.Contains(symbol, "unknown") {
		return false
	}

	return true
}

// ============================================================================
// dSYM 信息提取
// ============================================================================

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

	// 检查报告类型并符号化
	result := make(map[string]interface{})
	for k, v := range reportMap {
		result[k] = v
	}

	var symbolicated []interface{}
	var dumpType int
	
	// 获取 dump_type
	if dt, ok := reportMap["dump_type"].(float64); ok {
		dumpType = int(dt)
	}

	// binary_images 已经在第246行获取了，这里直接使用
	// 如果之前没有获取到，初始化为空数组
	if binaryImages == nil {
		binaryImages = []interface{}{}
	}

	// 判断是卡顿类型还是耗电类型
	if stackString, ok := reportMap["stack_string"].([]interface{}); ok && len(stackString) > 0 {
		// 耗电监控数据格式：stack_string[]
		log.Printf("📊 检测到耗电监控数据，dump_type=%d, stack_string数组长度=%d", dumpType, len(stackString))
		symbolicated = symbolicateCustomStack(stackString, binaryPath, loadAddr, arch, binaryImages)
		result["stack_string"] = symbolicated
		dumpType = 2011 // 确保设置为耗电类型 (EDumpType_PowerConsume)
	} else if crash, ok := reportMap["crash"].(map[string]interface{}); ok {
		// 卡顿数据格式：crash.threads[]
		log.Printf("📊 检测到卡顿监控数据，dump_type=%d", dumpType)
		
		threads, ok := crash["threads"].([]interface{})
		if !ok {
			return nil, fmt.Errorf("报告中没有线程信息")
		}

		// 创建新的 crash 对象
		newCrash := make(map[string]interface{})
		for k, v := range crash {
			newCrash[k] = v
		}
		result["crash"] = newCrash

		// 符号化线程
		for _, t := range threads {
			thread := t.(map[string]interface{})
			symbolicatedThread := symbolicateThread(thread, binaryPath, loadAddr, arch)
			symbolicated = append(symbolicated, symbolicatedThread)
		}

		newCrash["threads"] = symbolicated
	} else {
		return nil, fmt.Errorf("报告格式不支持：既没有 stack_string 也没有 crash 信息")
	}

	// ========================================================================
	// 符号化统计
	// ========================================================================
	stats := calculateSymbolicationStats(symbolicated, dumpType)

	// 添加符号化元数据
	result["symbolication_info"] = map[string]interface{}{
		"symbolicated":     true,
		"dsym_path":        dsymPath,
		"binary_path":      binaryPath,
		"load_address":     fmt.Sprintf("0x%x", loadAddr),
		"architecture":     arch,
		"symbolicate_time": timeNow(),
		"formatted_report": formatReportToAppleStyle(result),
		"statistics":       stats, // ✅ 新增：符号化统计
	}

	// 打印统计信息
	log.Printf("📊 符号化统计:")
	log.Printf("   总线程数: %d", stats["total_threads"])
	log.Printf("   总帧数: %d", stats["total_frames"])
	log.Printf("   符号化帧数: %d", stats["symbolicated_frames"])
	log.Printf("   Swift 符号: %d", stats["swift_symbols"])
	log.Printf("   ObjC 符号: %d", stats["objc_symbols"])
	log.Printf("   应用代码帧: %d", stats["app_code_frames"])
	log.Printf("   符号化成功率: %.1f%%", stats["success_rate"])

	return result, nil
}

// calculateSymbolicationStats 计算符号化统计信息
func calculateSymbolicationStats(data []interface{}, dumpType int) map[string]interface{} {
	stats := map[string]interface{}{
		"total_threads":       len(data),
		"total_frames":        0,
		"symbolicated_frames": 0,
		"swift_symbols":       0,
		"objc_symbols":        0,
		"cpp_symbols":         0,
		"c_symbols":           0,
		"app_code_frames":     0,
		"success_rate":        0.0,
	}

	totalFrames := 0
	symbolicatedFrames := 0
	swiftSymbols := 0
	objcSymbols := 0
	cppSymbols := 0
	cSymbols := 0
	appCodeFrames := 0

	// 判断数据类型：检查第一个元素的结构
	isCustomStack := false
	if len(data) > 0 {
		if firstItem, ok := data[0].(map[string]interface{}); ok {
			// 如果有 "child" 字段，说明是树状结构（stack_string）
			if _, hasChild := firstItem["child"]; hasChild {
				isCustomStack = true
			} else if _, hasBacktrace := firstItem["backtrace"]; hasBacktrace {
				// 如果有 "backtrace" 字段，说明是线性结构（crash.threads）
				isCustomStack = false
			} else if dumpType == 2011 {
				// 兜底：如果 dump_type 是 2011 (EDumpType_PowerConsume)，也认为是耗电数据
				isCustomStack = true
			}
		}
	}

	log.Printf("🔍 统计数据类型判断: isCustomStack=%v, dumpType=%d, 数据数量=%d", isCustomStack, dumpType, len(data))

	if isCustomStack {
		// stack_string 格式：树状结构，需要递归统计
		for _, item := range data {
			countStackFrameRecursive(item, &totalFrames, &symbolicatedFrames, &swiftSymbols, &objcSymbols, &cppSymbols, &cSymbols, &appCodeFrames)
		}
	} else {
		// crash.threads 格式：线性结构
		for _, item := range data {
			itemMap := item.(map[string]interface{})
			
			backtrace, ok := itemMap["backtrace"].(map[string]interface{})
			if !ok {
				continue
			}

			contents, ok := backtrace["contents"].([]interface{})
			if !ok {
				continue
			}

			for _, f := range contents {
				frame := f.(map[string]interface{})
				totalFrames++

				// 检查是否符号化
				if symbolicatedName, ok := frame["symbolicated_name"].(string); ok && symbolicatedName != "" {
					symbolicatedFrames++

					// 检测语言类型
					language := detectSymbolLanguage(symbolicatedName)
					switch language {
					case "Swift":
						swiftSymbols++
					case "Objective-C":
						objcSymbols++
					case "C++":
						cppSymbols++
					case "C/Other":
						cSymbols++
					}
				}

				// 检查是否是应用代码
				if isApp, ok := frame["is_app_code"].(bool); ok && isApp {
					appCodeFrames++
				}
			}
		}
	}

	// 计算成功率
	successRate := 0.0
	if totalFrames > 0 {
		successRate = float64(symbolicatedFrames) / float64(totalFrames) * 100.0
	}

	stats["total_frames"] = totalFrames
	stats["symbolicated_frames"] = symbolicatedFrames
	stats["swift_symbols"] = swiftSymbols
	stats["objc_symbols"] = objcSymbols
	stats["cpp_symbols"] = cppSymbols
	stats["c_symbols"] = cSymbols
	stats["app_code_frames"] = appCodeFrames
	stats["success_rate"] = successRate

	return stats
}

// countStackFrameRecursive 递归统计堆栈帧（处理树状结构）
func countStackFrameRecursive(frame interface{}, totalFrames, symbolicatedFrames, swiftSymbols, objcSymbols, cppSymbols, cSymbols, appCodeFrames *int) {
	frameMap, ok := frame.(map[string]interface{})
	if !ok {
		return
	}

	*totalFrames++

	// 检查是否符号化
	if symbolicatedName, ok := frameMap["symbolicated_name"].(string); ok && symbolicatedName != "" {
		*symbolicatedFrames++

		// 检测语言类型
		language := detectSymbolLanguage(symbolicatedName)
		switch language {
		case "Swift":
			*swiftSymbols++
		case "Objective-C":
			*objcSymbols++
		case "C++":
			*cppSymbols++
		case "C/Other":
			*cSymbols++
		}
	}

	// 检查是否是应用代码
	if isApp, ok := frameMap["is_app_code"].(bool); ok && isApp {
		*appCodeFrames++
	}

	// 递归处理子帧
	if childFrames, ok := frameMap["child"].([]interface{}); ok {
		for _, childFrame := range childFrames {
			countStackFrameRecursive(childFrame, totalFrames, symbolicatedFrames, swiftSymbols, objcSymbols, cppSymbols, cSymbols, appCodeFrames)
		}
	}
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

				// ✅ 新增：检测符号语言类型
				language := detectSymbolLanguage(symbol)
				symbolicatedFrame["symbol_language"] = language

				// ✅ 新增：检查符号质量
				symbolicatedFrame["symbol_quality"] = isSymbolWellFormatted(symbol)

				// 解析文件名和行号
				fileName, lineNum := parseSymbolOutput(symbol)
				if fileName != "" {
					symbolicatedFrame["file_name"] = fileName
					symbolicatedFrame["line_number"] = lineNum

					// ✅ 新增：记录文件类型
					ext := filepath.Ext(fileName)
					if ext == ".swift" {
						symbolicatedFrame["file_type"] = "Swift"
					} else if ext == ".mm" || ext == ".m" {
						symbolicatedFrame["file_type"] = "Objective-C"
					} else if ext == ".cpp" || ext == ".cc" || ext == ".cxx" {
						symbolicatedFrame["file_type"] = "C++"
					} else if ext == ".c" {
						symbolicatedFrame["file_type"] = "C"
					}
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

// symbolicateCustomStack 符号化耗电监控的 stack_string 数据（树状结构）
func symbolicateCustomStack(stackString []interface{}, binaryPath string, loadAddr uint64, arch string, binaryImages []interface{}) []interface{} {
	symbolicated := []interface{}{}
	
	for _, item := range stackString {
		symbolicatedItem := symbolicateStackFrame(item, binaryPath, loadAddr, arch, binaryImages)
		symbolicated = append(symbolicated, symbolicatedItem)
	}

	return symbolicated
}

// symbolicateStackFrame 递归符号化单个堆栈帧及其子帧
func symbolicateStackFrame(frame interface{}, binaryPath string, loadAddr uint64, arch string, binaryImages []interface{}) interface{} {
	frameMap, ok := frame.(map[string]interface{})
	if !ok {
		return frame
	}

	// 复制原始数据
	result := make(map[string]interface{})
	for k, v := range frameMap {
		result[k] = v
	}

	// 获取地址
	var addr uint64
	if a, ok := frameMap["instruction_address"].(float64); ok {
		addr = uint64(a)
		
		// 根据地址查找所属的库
		if img := findBinaryImageForAddress(addr, binaryImages); img != nil {
			if name, ok := img["name"].(string); ok {
				result["image_name"] = name
				result["object_name"] = filepath.Base(name)
			}
			if imgAddr, ok := img["image_addr"].(float64); ok {
				result["object_address"] = imgAddr
			}
		}
		
		// 符号化当前帧的地址
		symbol := symbolicateAddress(binaryPath, loadAddr, addr, arch)
		if symbol != "" {
			result["symbolicated_name"] = symbol
			result["symbol_language"] = detectSymbolLanguage(symbol)
			result["symbol_quality"] = isSymbolWellFormatted(symbol)

			// 解析文件名和行号
			fileName, lineNum := parseSymbolOutput(symbol)
			if fileName != "" {
				result["file_name"] = fileName
				result["line_number"] = lineNum
				
				ext := filepath.Ext(fileName)
				if ext == ".swift" {
					result["file_type"] = "Swift"
				} else if ext == ".mm" || ext == ".m" {
					result["file_type"] = "Objective-C"
				} else if ext == ".cpp" || ext == ".cc" || ext == ".cxx" {
					result["file_type"] = "C++"
				} else if ext == ".c" {
					result["file_type"] = "C"
				}
			}

			// 标记为应用代码
			if fileName != "" &&
				!strings.Contains(fileName, "KSCrash") &&
				!strings.Contains(fileName, "WC") &&
				!strings.Contains(fileName, "Matrix") {
				result["is_app_code"] = true
			}
		}
	}

	// 递归处理子帧
	if childFrames, ok := frameMap["child"].([]interface{}); ok {
		symbolicatedChildren := []interface{}{}
		for _, childFrame := range childFrames {
			symbolicatedChild := symbolicateStackFrame(childFrame, binaryPath, loadAddr, arch, binaryImages)
			symbolicatedChildren = append(symbolicatedChildren, symbolicatedChild)
		}
		result["child"] = symbolicatedChildren
	}

	return result
}

// findBinaryImageForAddress 根据地址查找对应的库
func findBinaryImageForAddress(addr uint64, binaryImages []interface{}) map[string]interface{} {
	for _, img := range binaryImages {
		imgMap, ok := img.(map[string]interface{})
		if !ok {
			continue
		}
		
		imgAddr, ok1 := imgMap["image_addr"].(float64)
		imgSize, ok2 := imgMap["image_size"].(float64)
		if !ok1 || !ok2 {
			continue
		}
		
		// 检查地址是否在此库的范围内
		if addr >= uint64(imgAddr) && addr < uint64(imgAddr)+uint64(imgSize) {
			return imgMap
		}
	}
	
	return nil
}

// symbolicateAddress 使用 atos 符号化单个地址（增强 Swift 支持）
func symbolicateAddress(binaryPath string, loadAddr uint64, targetAddr uint64, arch string) string {
	startTime := time.Now()

	// ========================================================================
	// 步骤1: 使用 atos 进行符号化
	// ========================================================================
	cmd := exec.Command(
		"atos",
		"-arch", arch,
		"-o", binaryPath,
		"-l", fmt.Sprintf("0x%x", loadAddr),
		fmt.Sprintf("0x%x", targetAddr),
	)

	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		log.Printf("⚠️ atos 执行失败: %v, stderr: %s", err, stderr.String())
		return ""
	}

	symbol := strings.TrimSpace(out.String())

	// ========================================================================
	// 步骤2: 检查符号化是否成功
	// ========================================================================
	// 如果 atos 返回的还是地址，说明符号化失败
	if symbol == "" ||
		symbol == fmt.Sprintf("0x%x", targetAddr) ||
		strings.HasPrefix(symbol, "0x") {
		log.Printf("⚠️ atos 符号化失败，地址: 0x%x", targetAddr)
		return ""
	}

	// ========================================================================
	// 步骤3: 检测符号语言类型
	// ========================================================================
	language := detectSymbolLanguage(symbol)

	// ========================================================================
	// 步骤4: Swift 符号特殊处理
	// ========================================================================
	if language == "Swift" {
		log.Printf("🔍 检测到 Swift 符号 (0x%x)", targetAddr)

		// 检查 atos 是否已经 demangle
		if isSymbolWellFormatted(symbol) {
			// atos 已自动 demangle（推荐路径）
			elapsed := time.Since(startTime)
			log.Printf("✅ [Swift] atos 自动 demangle 成功 (耗时: %v)", elapsed)
			log.Printf("   符号: %s", symbol)
			return symbol
		}

		// 如果 atos 未 demangle，尝试手动 demangle
		log.Printf("⚙️ atos 未 demangle，尝试手动处理...")

		// 提取 mangled 符号名（去掉地址和模块信息）
		mangledSymbol := extractMangledSymbol(symbol)
		if mangledSymbol != "" {
			demangled := demangleSwiftSymbol(mangledSymbol)
			if demangled != mangledSymbol {
				// 重新组合完整符号（保留文件名和行号等信息）
				fullSymbol := replaceSymbolName(symbol, mangledSymbol, demangled)
				elapsed := time.Since(startTime)
				log.Printf("✅ [Swift] 手动 demangle 成功 (耗时: %v)", elapsed)
				log.Printf("   最终符号: %s", fullSymbol)
				return fullSymbol
			}
		}

		// 如果 demangle 失败，返回原始符号
		log.Printf("⚠️ [Swift] demangle 失败，返回原始符号")
		return symbol
	}

	// ========================================================================
	// 步骤5: Objective-C/C/C++ 符号直接返回
	// ========================================================================
	elapsed := time.Since(startTime)
	log.Printf("✅ [%s] 符号化成功 (耗时: %v, 地址: 0x%x)", language, elapsed, targetAddr)

	return symbol
}

// extractMangledSymbol 从 atos 输出中提取 mangled 符号名
// 输入示例: "$s15MatrixTestApp23TestSwiftViewControllerC9fibonacciyS2iF (in MatrixTestApp)"
// 输出示例: "$s15MatrixTestApp23TestSwiftViewControllerC9fibonacciyS2iF"
func extractMangledSymbol(atosOutput string) string {
	// 移除 " (in ModuleName)" 后缀
	if idx := strings.Index(atosOutput, " (in "); idx != -1 {
		return strings.TrimSpace(atosOutput[:idx])
	}

	// 移除文件名和行号 "(File.swift:123)"
	if idx := strings.Index(atosOutput, " ("); idx != -1 {
		return strings.TrimSpace(atosOutput[:idx])
	}

	return strings.TrimSpace(atosOutput)
}

// replaceSymbolName 替换符号名称（保留其他信息）
// 原始: "$s15...F (in MatrixTestApp) (TestSwiftViewController.swift:65)"
// mangled: "$s15...F"
// demangled: "TestSwiftViewController.fibonacci(_:) -> Swift.Int"
// 结果: "TestSwiftViewController.fibonacci(_:) -> Swift.Int (in MatrixTestApp) (TestSwiftViewController.swift:65)"
func replaceSymbolName(original, mangledName, demangledName string) string {
	return strings.Replace(original, mangledName, demangledName, 1)
}

// parseSymbolOutput 解析符号化输出（增强 Swift 支持）
func parseSymbolOutput(symbol string) (fileName string, lineNum string) {
	// 支持的文件扩展名：
	// - Objective-C: .m, .mm
	// - C/C++: .c, .cpp, .cc, .cxx
	// - Swift: .swift ✅ 新增
	// - Header: .h, .hpp

	// 格式示例：
	// ObjC:  -[Class method] (in App) (File.mm:123)
	// Swift: TestViewController.method() (in App) (File.swift:65)
	// C++:   MyClass::method() (in App) (File.cpp:42)

	re := regexp.MustCompile(`\(([^)]+\.(?:m|mm|c|cpp|cc|cxx|swift|h|hpp)):(\d+)\)`)
	matches := re.FindStringSubmatch(symbol)

	if len(matches) >= 3 {
		fileName = matches[1]
		lineNum = matches[2]

		// 检测文件类型
		ext := filepath.Ext(fileName)
		if ext == ".swift" {
			log.Printf("📄 [Swift] 文件: %s:%s", fileName, lineNum)
		} else if ext == ".mm" || ext == ".m" {
			log.Printf("📄 [ObjC] 文件: %s:%s", fileName, lineNum)
		}
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

	// 判断报告类型
	dumpType := 0
	if dt, ok := report["dump_type"].(float64); ok {
		dumpType = int(dt)
	}
	
	reportTitle := "🔍 Matrix 卡顿报告 - 符号化版本"
	if dumpType == 2011 {
		reportTitle = "🔋 Matrix 耗电监控报告 - 符号化版本"
	}

	buf.WriteString("=" + strings.Repeat("=", 79) + "\n")
	buf.WriteString(reportTitle + "\n")
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
	var threads []interface{}
	isCustomStack := false
	
	if stackString, ok := report["stack_string"].([]interface{}); ok {
		// 耗电监控数据
		threads = stackString
		isCustomStack = true
		buf.WriteString(fmt.Sprintf("🔋 共 %d 个堆栈采样\n\n", len(threads)))
	} else if crash, ok := report["crash"].(map[string]interface{}); ok {
		// 卡顿数据
		threads, _ = crash["threads"].([]interface{})
		buf.WriteString(fmt.Sprintf("📋 共 %d 个线程\n\n", len(threads)))
	} else {
		buf.WriteString("⚠️ 报告格式未知\n\n")
		return buf.String()
	}

	// 找出主线程和有应用代码的线程
	for threadIdx, t := range threads {
		thread := t.(map[string]interface{})
		
		var contents []interface{}
		var idx interface{}
		var name string
		var crashed bool
		
		if isCustomStack {
			// 耗电监控格式
			stack, _ := thread["stack"].([]interface{})
			contents = stack
			idx = threadIdx
			name = "耗电堆栈"
		} else {
			// 卡顿格式
			idx = thread["index"]
			name, _ = thread["name"].(string)
			crashed, _ = thread["crashed"].(bool)
			
			backtrace, _ := thread["backtrace"].(map[string]interface{})
			contents, _ = backtrace["contents"].([]interface{})
		}

		// 检查是否有应用代码
		hasAppCode := false
		for _, f := range contents {
			frame := f.(map[string]interface{})
			if isApp, ok := frame["is_app_code"].(bool); ok && isApp {
				hasAppCode = true
				break
			}
		}

		if !hasAppCode && !isCustomStack && idx != 0 && !crashed {
			continue
		}

		// 显示线程/堆栈标题
		label := ""
		if isCustomStack {
			label = fmt.Sprintf("🔋 耗电堆栈 %d", threadIdx+1)
			// 显示额外的耗电信息
			if cost, ok := thread["cost"].(float64); ok {
				buf.WriteString(strings.Repeat("=", 80) + "\n")
				buf.WriteString(fmt.Sprintf("%s (耗电: %.2f)\n", label, cost))
				buf.WriteString(strings.Repeat("=", 80) + "\n\n")
			} else {
				buf.WriteString(strings.Repeat("=", 80) + "\n")
				buf.WriteString(fmt.Sprintf("%s\n", label))
				buf.WriteString(strings.Repeat("=", 80) + "\n\n")
			}
		} else {
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
		}

		// 显示堆栈
		if isCustomStack {
			// 树状结构：递归显示
			for i, frame := range contents {
				formatStackFrameRecursive(&buf, frame, i, 0)
			}
		} else {
			// 线性结构：直接显示
			for i, f := range contents {
				frame := f.(map[string]interface{})
				objName, _ := frame["object_name"].(string)
				addr := frame["instruction_addr"]

				isApp, _ := frame["is_app_code"].(bool)

				// 根据语言类型选择不同的标记
				language, _ := frame["symbol_language"].(string)
				marker := "   "
				if isApp {
					switch language {
					case "Swift":
						marker = "🟦 " // Swift 代码
					case "Objective-C":
						marker = "🟧 " // ObjC 代码
					case "C++":
						marker = "🟥 " // C++ 代码
					default:
						marker = "👉 " // 其他应用代码
					}
				}

				symbolicatedName, hasSymbol := frame["symbolicated_name"].(string)
				if hasSymbol {
					fileType, _ := frame["file_type"].(string)
					languageTag := ""
					if fileType != "" {
						languageTag = fmt.Sprintf(" [%s]", fileType)
					}

					buf.WriteString(fmt.Sprintf("%s%2d  %-25s %v%s\n", marker, i, objName, addr, languageTag))
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
		}

		buf.WriteString("\n")
	}

	buf.WriteString(strings.Repeat("=", 80) + "\n")
	buf.WriteString("💡 图例说明:\n")
	buf.WriteString("   🟦 Swift 应用代码\n")
	buf.WriteString("   🟧 Objective-C 应用代码\n")
	buf.WriteString("   🟥 C++ 应用代码\n")
	buf.WriteString("   👉 其他应用代码\n")
	buf.WriteString("      系统库代码（无标记）\n")
	buf.WriteString(strings.Repeat("=", 80) + "\n")

	return buf.String()
}

// formatStackFrameRecursive 递归格式化并显示堆栈帧（处理树状结构）
func formatStackFrameRecursive(buf *bytes.Buffer, frame interface{}, index int, depth int) {
	frameMap, ok := frame.(map[string]interface{})
	if !ok {
		return
	}

	// 缩进
	indent := strings.Repeat("  ", depth)
	
	// 获取地址
	addr, _ := frameMap["instruction_address"].(float64)
	isApp, _ := frameMap["is_app_code"].(bool)
	language, _ := frameMap["symbol_language"].(string)
	
	// 根据语言类型选择不同的标记
	marker := indent + "   "
	if isApp {
		switch language {
		case "Swift":
			marker = indent + "🟦 "
		case "Objective-C":
			marker = indent + "🟧 "
		case "C++":
			marker = indent + "🟥 "
		default:
			marker = indent + "👉 "
		}
	}
	
	// 采样次数
	sampleCount, _ := frameMap["sample"].(float64)
	
	// 显示当前帧
	if symbolicatedName, ok := frameMap["symbolicated_name"].(string); ok && symbolicatedName != "" {
		fileType, _ := frameMap["file_type"].(string)
		languageTag := ""
		if fileType != "" {
			languageTag = fmt.Sprintf(" [%s]", fileType)
		}
		
		buf.WriteString(fmt.Sprintf("%s#%d  0x%x (采样:%d次)%s\n", marker, index, uint64(addr), int(sampleCount), languageTag))
		buf.WriteString(fmt.Sprintf("%s     %s\n", indent, symbolicatedName))
	} else if symbolName, ok := frameMap["symbol_name"].(string); ok && symbolName != "" {
		buf.WriteString(fmt.Sprintf("%s#%d  0x%x (采样:%d次) %s\n", marker, index, uint64(addr), int(sampleCount), symbolName))
	} else {
		buf.WriteString(fmt.Sprintf("%s#%d  0x%x (采样:%d次)\n", marker, index, uint64(addr), int(sampleCount)))
	}
	
	// 递归显示子帧
	if childFrames, ok := frameMap["child"].([]interface{}); ok && len(childFrames) > 0 {
		for i, childFrame := range childFrames {
			formatStackFrameRecursive(buf, childFrame, i, depth+1)
		}
	}
}
