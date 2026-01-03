package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// 将 Matrix JSON 报告转换为 Apple crash report 格式
func formatReportToAppleStyle(report map[string]interface{}) string {
	var result strings.Builder

	// 检查是否是耗电日志
	dumpType := 0
	if dt, ok := report["dump_type"].(float64); ok {
		dumpType = int(dt)
	}

	// 耗电日志使用不同的格式化方式
	if dumpType == 2011 { // EDumpType_PowerConsume
		return formatPowerConsumeReport(report)
	}

	// 卡顿/崩溃日志的格式化
	// 解析系统信息
	result.WriteString(formatSystemInfo(report))
	result.WriteString("\n")

	// 解析错误信息
	result.WriteString(formatErrorInfo(report))
	result.WriteString("\n")

	// 解析用户信息
	result.WriteString(formatUserInfo(report))
	result.WriteString("\n")

	// 解析应用信息
	result.WriteString(formatAppInfo(report))
	result.WriteString("\n")

	// 解析线程信息
	result.WriteString(formatThreadList(report))
	result.WriteString("\n")

	// 解析 CPU 状态
	result.WriteString(formatCPUState(report))
	result.WriteString("\n")

	// 二进制镜像列表通常很长且对日常分析用处不大，已省略
	// 如需查看完整的二进制镜像列表，请查看 JSON 格式报告

	return result.String()
}

func formatSystemInfo(report map[string]interface{}) string {
	system, ok := report["system"].(map[string]interface{})
	if !ok {
		return ""
	}

	var result strings.Builder
	result.WriteString("System Info: {\n")

	// 设备信息
	if machine, ok := system["machine"].(string); ok {
		deviceName := getDeviceName(machine)
		result.WriteString(fmt.Sprintf("    Device:      %s\n", deviceName))
	}

	// 系统版本
	if systemName, ok := system["system_name"].(string); ok {
		systemVersion := getString(system, "system_version")
		osVersion := getString(system, "os_version")
		result.WriteString(fmt.Sprintf("    OS Version:  %s %s (%s)\n", systemName, systemVersion, osVersion))
	}

	// 内存信息
	if memory, ok := system["memory"].(map[string]interface{}); ok {
		if usable, ok := memory["usable"].(float64); ok {
			result.WriteString(fmt.Sprintf("    Mem usable:  %4d M\n", int(usable)/1024/1024))
		}
		if free, ok := memory["free"].(float64); ok {
			result.WriteString(fmt.Sprintf("    Mem free:    %4d M\n", int(free)/1024/1024))
		}
		if size, ok := memory["size"].(float64); ok {
			result.WriteString(fmt.Sprintf("    Mem size:    %4d M\n", int(size)/1024/1024))
		}
	}

	result.WriteString("}\n")
	return result.String()
}

func formatErrorInfo(report map[string]interface{}) string {
	crash, ok := report["crash"].(map[string]interface{})
	if !ok {
		return ""
	}

	error, ok := crash["error"].(map[string]interface{})
	if !ok {
		return ""
	}

	var result strings.Builder

	// Exception Type
	excName := ""
	sigName := ""

	if mach, ok := error["mach"].(map[string]interface{}); ok {
		excName = getString(mach, "exception_name")
	}

	if signal, ok := error["signal"].(map[string]interface{}); ok {
		// 优先使用 name，否则使用 signal 数字
		sigName = getString(signal, "name")
		if sigName == "" {
			if sigNum := getInt64(signal, "signal"); sigNum != 0 {
				sigName = fmt.Sprintf("SIG%d", sigNum)
			}
		}
	}

	result.WriteString(fmt.Sprintf("\nException Type:  %s (%s)\n", excName, sigName))

	// Exception Codes
	codeName := ""
	if mach, ok := error["mach"].(map[string]interface{}); ok {
		codeName = getString(mach, "code_name")
		if codeName == "" {
			if code := getInt64(mach, "code"); code != 0 {
				codeName = fmt.Sprintf("0x%x", code)
			}
		}
	}

	addr := getInt64(error, "address")
	result.WriteString(fmt.Sprintf("Exception Codes: %s at 0x%016x\n", codeName, addr))

	// Crashed Thread
	crashedThreadIdx := getCrashedThreadIndex(report)
	result.WriteString(fmt.Sprintf("Crashed Thread:  %d\n", crashedThreadIdx))

	return result.String()
}

func formatUserInfo(report map[string]interface{}) string {
	user, ok := report["user"].(map[string]interface{})
	if !ok || len(user) == 0 {
		return ""
	}

	var result strings.Builder
	result.WriteString("\nUser Info: {\n")

	// 遍历所有应用的用户信息
	for appName, appData := range user {
		if appInfo, ok := appData.(map[string]interface{}); ok {
			result.WriteString(fmt.Sprintf("    App: %s\n", appName))
			if uin, ok := appInfo["uin"]; ok {
				result.WriteString(fmt.Sprintf("    Uin:             %v\n", uin))
			}
			if blockTime, ok := appInfo["blockTime"]; ok {
				result.WriteString(fmt.Sprintf("    blockTime:       %v\n", blockTime))
			}
			if dumpType, ok := appInfo["DumpType"]; ok {
				result.WriteString(fmt.Sprintf("    dumpType:        %v\n", dumpType))
			}
		}
	}

	result.WriteString("}\n")
	return result.String()
}

func formatAppInfo(report map[string]interface{}) string {
	system, ok := report["system"].(map[string]interface{})
	if !ok {
		return ""
	}

	reportInfo, _ := report["report"].(map[string]interface{})

	var result strings.Builder
	result.WriteString("\nApplication Info: {\n")

	// Process
	processName := getString(system, "process_name")
	processID := getInt64(system, "process_id")
	result.WriteString(fmt.Sprintf("    Process:                             %s [%d]\n", processName, processID))

	// Identifier
	if id := getString(reportInfo, "id"); id != "" {
		result.WriteString(fmt.Sprintf("    Identifier:                          %s\n", id))
	}

	// Version
	shortVersion := getString(system, "CFBundleShortVersionString")
	bundleVersion := getString(system, "CFBundleVersion")
	result.WriteString(fmt.Sprintf("    Version:                             %s (%s)\n", shortVersion, bundleVersion))

	// Code Type
	cpuArch := getString(system, "cpu_arch")
	result.WriteString(fmt.Sprintf("    Code Type:                           %s\n", strings.ToUpper(cpuArch)))

	// Crash Time
	if timestamp := getInt64(reportInfo, "timestamp"); timestamp > 0 {
		crashTime := time.Unix(timestamp, 0).Format("2006-01-02 15:04:05")
		result.WriteString(fmt.Sprintf("    app_crash_time:                      %s\n", crashTime))
	}

	// App Launch Time
	if appStats, ok := system["application_stats"].(map[string]interface{}); ok {
		if launchTime := getInt64(appStats, "app_launch_time"); launchTime > 0 {
			launchTimeStr := time.Unix(launchTime, 0).Format("2006-01-02 15:04:05")
			result.WriteString(fmt.Sprintf("    app_launch_time:                     %s\n", launchTimeStr))
		}
	}

	result.WriteString("}\n")
	return result.String()
}

func formatThreadList(report map[string]interface{}) string {
	crash, ok := report["crash"].(map[string]interface{})
	if !ok {
		return ""
	}

	threads, ok := crash["threads"].([]interface{})
	if !ok {
		return ""
	}

	var result strings.Builder
	seenThreads := make(map[int64]bool)

	for _, threadData := range threads {
		thread, ok := threadData.(map[string]interface{})
		if !ok {
			continue
		}

		// 去重：检查线程索引
		index := getInt64(thread, "index")
		if seenThreads[index] {
			continue
		}
		seenThreads[index] = true

		result.WriteString(formatThread(thread, report))
		result.WriteString("\n")
	}

	return result.String()
}

func formatThread(thread map[string]interface{}, report map[string]interface{}) string {
	var result strings.Builder

	index := getInt64(thread, "index")
	crashed := getBool(thread, "crashed")

	// Thread name/queue
	if name := getString(thread, "name"); name != "" {
		result.WriteString(fmt.Sprintf("\nThread %d name:  %s\n", index, name))
	} else if queue := getString(thread, "dispatch_queue"); queue != "" {
		result.WriteString(fmt.Sprintf("\nThread %d name:  Dispatch queue: %s\n", index, queue))
	}

	// Thread header
	if crashed {
		result.WriteString(fmt.Sprintf("Thread %d Crashed:\n", index))
	} else {
		result.WriteString(fmt.Sprintf("Thread %d:\n", index))
	}

	// Backtrace
	if backtrace, ok := thread["backtrace"].(map[string]interface{}); ok {
		result.WriteString(formatBacktrace(backtrace, report))
	}

	return result.String()
}

func formatBacktrace(backtrace map[string]interface{}, report map[string]interface{}) string {
	contents, ok := backtrace["contents"].([]interface{})
	if !ok {
		return ""
	}

	var result strings.Builder
	for i, frameData := range contents {
		frame, ok := frameData.(map[string]interface{})
		if !ok {
			continue
		}

		pc := getInt64(frame, "instruction_addr")

		// 获取模块名，优先从 frame 中获取
		objectName := getString(frame, "object_name")

		// 如果没有，尝试从镜像信息中获取
		if objectName == "" || objectName == "unknown" {
			img := findImageForAddress(report, pc)
			if img != nil {
				imgName := getString(img, "name")
				if imgName != "" {
					// 只取文件名部分
					objectName = filepath.Base(imgName)
				}
			}
		}

		if objectName == "" {
			objectName = "???"
		}

		// 获取对应的镜像信息
		img := findImageForAddress(report, pc)
		if img != nil {
			objAddr := getInt64(img, "image_addr")
			offset := pc - objAddr

			// 格式：序号 模块名 地址 符号信息
			preamble := fmt.Sprintf("%-4d%-31s 0x%016x", i, objectName, pc)

			// 优先使用符号化后的名称
			symbolicatedName := getString(frame, "symbolicated_name")
			symbolName := getString(frame, "symbol_name")

			if symbolicatedName != "" {
				// 使用符号化后的结果
				result.WriteString(fmt.Sprintf("%s %s\n", preamble, symbolicatedName))
			} else if symbolName != "" && symbolName != "<redacted>" {
				// 使用原始符号名
				result.WriteString(fmt.Sprintf("%s %s\n", preamble, symbolName))
			} else {
				// 未符号化，显示地址+偏移
				result.WriteString(fmt.Sprintf("%s 0x%x + %d\n", preamble, objAddr, offset))
			}
		} else {
			result.WriteString(fmt.Sprintf("%-4d%-31s 0x%016x\n", i, objectName, pc))
		}
	}

	return result.String()
}

func formatCPUState(report map[string]interface{}) string {
	crash, ok := report["crash"].(map[string]interface{})
	if !ok {
		return ""
	}

	threads, ok := crash["threads"].([]interface{})
	if !ok {
		return ""
	}

	// 找到崩溃的线程
	var crashedThread map[string]interface{}
	for _, threadData := range threads {
		thread, ok := threadData.(map[string]interface{})
		if !ok {
			continue
		}
		if getBool(thread, "crashed") {
			crashedThread = thread
			break
		}
	}

	if crashedThread == nil {
		return ""
	}

	var result strings.Builder

	index := getInt64(crashedThread, "index")
	system, _ := report["system"].(map[string]interface{})
	cpuArch := getString(system, "cpu_arch")

	result.WriteString(fmt.Sprintf("\nThread %d crashed with %s Thread State:\n", index, strings.ToUpper(cpuArch)))

	// 获取寄存器
	registers, ok := crashedThread["registers"].(map[string]interface{})
	if !ok {
		return result.String()
	}

	basic, ok := registers["basic"].(map[string]interface{})
	if !ok {
		return result.String()
	}

	// 根据架构确定寄存器顺序
	regOrder := getRegisterOrder(cpuArch)

	line := ""
	for i, reg := range regOrder {
		if i != 0 && i%4 == 0 {
			result.WriteString(line + "\n")
			line = ""
		}
		if val, ok := basic[reg].(float64); ok {
			line += fmt.Sprintf("%6s: 0x%016x ", reg, int64(val))
		}
	}
	if line != "" {
		result.WriteString(line + "\n")
	}

	return result.String()
}

func formatBinaryImages(report map[string]interface{}) string {
	images, ok := report["binary_images"].([]interface{})
	if !ok {
		return ""
	}

	system, _ := report["system"].(map[string]interface{})
	exePath := getString(system, "CFBundleExecutablePath")

	var result strings.Builder
	result.WriteString("\nBinary Images:\n")

	// 按地址排序
	type imageInfo struct {
		addr  int64
		size  int64
		name  string
		uuid  string
		path  string
		isApp bool
	}

	var imageList []imageInfo
	for _, imgData := range images {
		img, ok := imgData.(map[string]interface{})
		if !ok {
			continue
		}

		addr := getInt64(img, "image_addr")
		size := getInt64(img, "image_size")
		path := getString(img, "name")
		uuid := getString(img, "uuid")
		name := filepath.Base(path)

		imageList = append(imageList, imageInfo{
			addr:  addr,
			size:  size,
			name:  name,
			uuid:  strings.ReplaceAll(strings.ToLower(uuid), "-", ""),
			path:  path,
			isApp: path == exePath,
		})
	}

	sort.Slice(imageList, func(i, j int) bool {
		return imageList[i].addr < imageList[j].addr
	})

	for _, img := range imageList {
		marker := " "
		if img.isApp {
			marker = "+"
		}
		result.WriteString(fmt.Sprintf("%#18x - %#18x %s%-31s <%s> %s\n",
			img.addr, img.addr+img.size-1, marker, img.name, img.uuid, img.path))
	}

	return result.String()
}

// 辅助函数

func getString(m map[string]interface{}, key string) string {
	if val, ok := m[key].(string); ok {
		return val
	}
	return ""
}

func getInt64(m map[string]interface{}, key string) int64 {
	if val, ok := m[key].(float64); ok {
		return int64(val)
	}
	if val, ok := m[key].(int64); ok {
		return val
	}
	if val, ok := m[key].(int); ok {
		return int64(val)
	}
	return 0
}

func getBool(m map[string]interface{}, key string) bool {
	if val, ok := m[key].(bool); ok {
		return val
	}
	return false
}

func getCrashedThreadIndex(report map[string]interface{}) int64 {
	crash, ok := report["crash"].(map[string]interface{})
	if !ok {
		return 0
	}

	threads, ok := crash["threads"].([]interface{})
	if !ok {
		return 0
	}

	for _, threadData := range threads {
		thread, ok := threadData.(map[string]interface{})
		if !ok {
			continue
		}
		if getBool(thread, "crashed") {
			return getInt64(thread, "index")
		}
	}

	return 0
}

func findImageForAddress(report map[string]interface{}, addr int64) map[string]interface{} {
	images, ok := report["binary_images"].([]interface{})
	if !ok {
		return nil
	}

	for _, imgData := range images {
		img, ok := imgData.(map[string]interface{})
		if !ok {
			continue
		}

		imgAddr := getInt64(img, "image_addr")
		imgSize := getInt64(img, "image_size")

		if addr >= imgAddr && addr <= imgAddr+imgSize {
			return img
		}
	}

	return nil
}

func getRegisterOrder(cpuArch string) []string {
	cpuArch = strings.ToLower(cpuArch)

	if strings.HasPrefix(cpuArch, "arm64") || cpuArch == "arm64" {
		regs := []string{}
		for i := 0; i < 30; i++ {
			regs = append(regs, fmt.Sprintf("x%d", i))
		}
		regs = append(regs, "fp", "sp", "lr", "pc", "cpsr")
		return regs
	} else if cpuArch == "x86_64" {
		return []string{"rax", "rbx", "rcx", "rdx", "rdi", "rsi", "rbp",
			"rsp", "r8", "r9", "r10", "r11", "r12", "r13",
			"r14", "r15", "rip", "rflags", "cs", "fs", "gs"}
	} else if cpuArch == "x86" || cpuArch == "i386" {
		return []string{"eax", "ebx", "ecx", "edx", "edi", "esi", "ebp",
			"esp", "ss", "eflags", "eip", "cs", "ds", "es",
			"fs", "gs"}
	}

	// 默认返回 arm64
	regs := []string{}
	for i := 0; i < 30; i++ {
		regs = append(regs, fmt.Sprintf("x%d", i))
	}
	regs = append(regs, "fp", "sp", "lr", "pc", "cpsr")
	return regs
}

func getDeviceName(machine string) string {
	deviceMap := map[string]string{
		"iPhone9,2":  "iPhone 7 Plus",
		"iPhone9,4":  "iPhone 7 Plus",
		"iPhone10,1": "iPhone 8",
		"iPhone10,4": "iPhone 8",
		"iPhone10,2": "iPhone 8 Plus",
		"iPhone10,5": "iPhone 8 Plus",
		"iPhone10,3": "iPhone X",
		"iPhone10,6": "iPhone X",
		"iPhone11,2": "iPhone XS",
		"iPhone11,4": "iPhone XS Max",
		"iPhone11,6": "iPhone XS Max",
		"iPhone11,8": "iPhone XR",
		"iPhone12,1": "iPhone 11",
		"iPhone12,3": "iPhone 11 Pro",
		"iPhone12,5": "iPhone 11 Pro Max",
		"iPhone13,1": "iPhone 12 mini",
		"iPhone13,2": "iPhone 12",
		"iPhone13,3": "iPhone 12 Pro",
		"iPhone13,4": "iPhone 12 Pro Max",
		"iPhone14,2": "iPhone 13 Pro",
		"iPhone14,3": "iPhone 13 Pro Max",
		"iPhone14,4": "iPhone 13 mini",
		"iPhone14,5": "iPhone 13",
		"iPhone14,6": "iPhone SE (3rd generation)",
		"iPhone14,7": "iPhone 14",
		"iPhone14,8": "iPhone 14 Plus",
		"iPhone15,2": "iPhone 14 Pro",
		"iPhone15,3": "iPhone 14 Pro Max",
		"iPhone15,4": "iPhone 15",
		"iPhone15,5": "iPhone 15 Plus",
		"iPhone16,1": "iPhone 15 Pro",
		"iPhone16,2": "iPhone 15 Pro Max",
	}

	if name, ok := deviceMap[machine]; ok {
		return fmt.Sprintf("%s (%s)", name, machine)
	}
	return machine
}

// formatPowerConsumeReport 格式化耗电监控报告
func formatPowerConsumeReport(report map[string]interface{}) string {
	var result strings.Builder

	result.WriteString("🔋 Matrix 耗电监控报告\n")
	result.WriteString(strings.Repeat("=", 80) + "\n\n")

	// 系统信息
	result.WriteString(formatSystemInfo(report))
	result.WriteString("\n")

	// 应用信息
	result.WriteString(formatAppInfo(report))
	result.WriteString("\n")

	// 用户信息
	result.WriteString(formatUserInfo(report))
	result.WriteString("\n")

	// 耗电堆栈信息
	stackString, ok := report["stack_string"].([]interface{})
	if !ok || len(stackString) == 0 {
		result.WriteString("⚠️  未找到耗电堆栈数据\n")
		return result.String()
	}

	result.WriteString(fmt.Sprintf("📊 耗电堆栈分析（共 %d 个采样点）\n", len(stackString)))
	result.WriteString(strings.Repeat("-", 80) + "\n\n")

	// 格式化每个堆栈树
	for i, stack := range stackString {
		result.WriteString(fmt.Sprintf("🔋 堆栈 #%d:\n", i+1))
		if stackMap, ok := stack.(map[string]interface{}); ok {
			formatPowerConsumeFrame(&result, stackMap, 0)
		}
		result.WriteString("\n")
	}

	result.WriteString(strings.Repeat("=", 80) + "\n")
	result.WriteString("说明：\n")
	result.WriteString("  - 每个堆栈帧后的数字表示该函数被采样到的次数\n")
	result.WriteString("  - 缩进表示调用层级，子节点是从父节点调用的\n")
	result.WriteString("  - 采样次数越多，说明该函数耗电越严重\n")

	return result.String()
}

// formatPowerConsumeFrame 递归格式化耗电堆栈帧
func formatPowerConsumeFrame(result *strings.Builder, frame map[string]interface{}, depth int) {
	indent := strings.Repeat("  ", depth)

	// 获取基本信息
	objName := ""
	if on, ok := frame["object_name"].(string); ok {
		objName = on
	}

	symbolName := ""
	if sn, ok := frame["symbol_name"].(string); ok && sn != "" && sn != "<redacted>" {
		symbolName = sn
	}

	addr := uint64(0)
	if a, ok := frame["instruction_address"].(float64); ok {
		addr = uint64(a)
	}

	objAddr := uint64(0)
	if oa, ok := frame["object_address"].(float64); ok {
		objAddr = uint64(oa)
	}

	sampleCount := 0
	if sc, ok := frame["sample"].(float64); ok {
		sampleCount = int(sc)
	}

	imageName := ""
	if in, ok := frame["image_name"].(string); ok {
		imageName = filepath.Base(in)
	}

	// 检查是否有符号化信息
	symbolicatedName := ""
	if sn, ok := frame["symbolicated_name"].(string); ok && sn != "" {
		symbolicatedName = sn
	}

	// 从 symbol_name 中提取库名（格式如 "funcName (in AppName)"）
	libraryName := objName
	if symbolName != "" && strings.Contains(symbolName, " (in ") {
		start := strings.Index(symbolName, " (in ")
		end := strings.LastIndex(symbolName, ")")
		if start > 0 && end > start {
			libraryName = symbolName[start+5 : end]
		}
	}
	if libraryName == "" && imageName != "" {
		libraryName = imageName
	}

	// 计算偏移量
	offset := addr - objAddr

	// 格式化输出 - 参考 battery2apple.py 的格式
	if symbolicatedName != "" {
		// 已符号化（应用自己的代码）
		fileInfo := ""
		if fileName, ok := frame["file_name"].(string); ok {
			if lineNum, ok := frame["line_number"].(float64); ok {
				fileInfo = fmt.Sprintf(" (%s:%d)", filepath.Base(fileName), int(lineNum))
			}
		}
		
		// 显示完整的符号化信息
		result.WriteString(fmt.Sprintf("%s📍 [采样:%d次] %s%s\n", indent, sampleCount, symbolicatedName, fileInfo))
		if libraryName != "" {
			result.WriteString(fmt.Sprintf("%s    (%s + %d) [0x%x]\n", indent, libraryName, offset, addr))
		} else {
			result.WriteString(fmt.Sprintf("%s    [0x%x]\n", indent, addr))
		}
	} else if symbolName != "" && symbolName != "<redacted>" {
		// 有原始符号名但未符号化（通常是系统库）
		result.WriteString(fmt.Sprintf("%s📍 [采样:%d次] %s\n", indent, sampleCount, symbolName))
		if libraryName != "" && offset > 0 {
			result.WriteString(fmt.Sprintf("%s    (%s + %d) [0x%x]\n", indent, libraryName, offset, addr))
		} else {
			result.WriteString(fmt.Sprintf("%s    [0x%x]\n", indent, addr))
		}
	} else if libraryName != "" {
		// 只有库名，没有符号（系统库未导出的函数）
		result.WriteString(fmt.Sprintf("%s📍 [采样:%d次] (%s + %d) [0x%x]\n", indent, sampleCount, libraryName, offset, addr))
	} else {
		// 完全没有信息
		result.WriteString(fmt.Sprintf("%s📍 [采样:%d次] 0x%x\n", indent, sampleCount, addr))
	}

	// 递归处理子帧
	if children, ok := frame["child"].([]interface{}); ok && len(children) > 0 {
		for _, child := range children {
			if childMap, ok := child.(map[string]interface{}); ok {
				formatPowerConsumeFrame(result, childMap, depth+1)
			}
		}
	}
}
