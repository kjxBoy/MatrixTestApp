package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
)

const (
	UploadDir     = "./uploads"
	DsymDir       = "./dsyms"
	ReportsDir    = "./reports"
	MaxUploadSize = 500 * 1024 * 1024 // 500MB
)

func main() {
	// 创建必要的目录
	dirs := []string{UploadDir, DsymDir, ReportsDir}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			log.Fatalf("创建目录失败 %s: %v", dir, err)
		}
	}

	// 设置 Gin
	gin.SetMode(gin.ReleaseMode)
	r := gin.Default()

	// 配置 CORS
	r.Use(cors.New(cors.Config{
		AllowOrigins:     []string{"*"},
		AllowMethods:     []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowHeaders:     []string{"Origin", "Content-Type", "Accept"},
		ExposeHeaders:    []string{"Content-Length"},
		AllowCredentials: true,
		MaxAge:           12 * time.Hour,
	}))

	// 静态文件服务
	r.Static("/static", "./static")
	r.GET("/", func(c *gin.Context) {
		c.File("./static/index.html")
	})
	r.GET("/web", func(c *gin.Context) {
		c.File("./static/index.html")
	})
	r.GET("/web/", func(c *gin.Context) {
		c.File("./static/index.html")
	})

	// API 路由
	api := r.Group("/api")
	{
		// 符号表管理
		api.POST("/dsym/upload", uploadDsymHandler)
		api.GET("/dsym/list", listDsymHandler)
		api.DELETE("/dsym/:uuid", deleteDsymHandler)

		// 日志上传和符号化
		api.POST("/report/upload", uploadReportHandler)
		api.POST("/report/symbolicate", symbolicateReportHandler)
		api.GET("/report/list", listReportsHandler)
		api.GET("/report/:id", getReportHandler)
		api.GET("/report/:id/formatted", getFormattedReportHandler)
		api.DELETE("/report/:id", deleteReportHandler)

		// 健康检查
		api.GET("/health", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{"status": "ok"})
		})
	}

	// 启动服务器
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("🚀 Matrix 符号化服务启动在端口 %s", port)
	log.Printf("📱 访问地址: http://localhost:%s", port)
	log.Printf("📂 符号表目录: %s", DsymDir)
	log.Printf("📋 报告目录: %s", ReportsDir)

	if err := r.Run(":" + port); err != nil {
		log.Fatalf("启动服务器失败: %v", err)
	}
}

// uploadDsymHandler 处理符号表上传
func uploadDsymHandler(c *gin.Context) {
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "文件上传失败: " + err.Error()})
		return
	}

	// 验证文件类型
	if !strings.HasSuffix(file.Filename, ".dSYM.zip") && !strings.HasSuffix(file.Filename, ".app") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "仅支持 .dSYM.zip 或 .app 文件"})
		return
	}

	// 保存文件
	timestamp := time.Now().Format("20060102_150405")
	filename := fmt.Sprintf("%s_%s", timestamp, filepath.Base(file.Filename))
	filepath := filepath.Join(DsymDir, filename)

	if err := c.SaveUploadedFile(file, filepath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败: " + err.Error()})
		return
	}

	// 提取 UUID
	uuid, arch, err := extractDsymInfo(filepath)
	if err != nil {
		log.Printf("警告: 提取 dSYM 信息失败: %v", err)
	}

	log.Printf("✅ 符号表上传成功: %s (UUID: %s, Arch: %s)", filename, uuid, arch)

	c.JSON(http.StatusOK, gin.H{
		"message":  "符号表上传成功",
		"filename": filename,
		"uuid":     uuid,
		"arch":     arch,
		"size":     file.Size,
	})
}

// listDsymHandler 列出所有符号表
func listDsymHandler(c *gin.Context) {
	files, err := os.ReadDir(DsymDir)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	var dsyms []map[string]interface{}
	for _, file := range files {
		if file.IsDir() {
			continue
		}

		info, _ := file.Info()
		filepath := filepath.Join(DsymDir, file.Name())
		uuid, arch, _ := extractDsymInfo(filepath)

		dsyms = append(dsyms, map[string]interface{}{
			"filename": file.Name(),
			"size":     info.Size(),
			"modified": info.ModTime(),
			"uuid":     uuid,
			"arch":     arch,
		})
	}

	c.JSON(http.StatusOK, gin.H{"dsyms": dsyms})
}

// deleteDsymHandler 删除符号表
func deleteDsymHandler(c *gin.Context) {
	filename := c.Param("uuid")
	filepath := filepath.Join(DsymDir, filename)

	if err := os.Remove(filepath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	log.Printf("🗑️  删除符号表: %s", filename)
	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// uploadReportHandler 处理报告上传
func uploadReportHandler(c *gin.Context) {
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "文件上传失败: " + err.Error()})
		return
	}

	// 验证文件类型
	if !strings.HasSuffix(file.Filename, ".json") && !strings.HasSuffix(file.Filename, ".txt") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "仅支持 .json 或 .txt 文件"})
		return
	}

	// 生成唯一ID
	reportID := fmt.Sprintf("%d", time.Now().UnixNano())
	filename := fmt.Sprintf("%s_%s", reportID, filepath.Base(file.Filename))
	savePath := filepath.Join(ReportsDir, filename)

	if err := c.SaveUploadedFile(file, savePath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败: " + err.Error()})
		return
	}

	// 检测报告格式
	data, err := os.ReadFile(savePath)
	if err == nil {
		var jsonData interface{}
		if err := json.Unmarshal(data, &jsonData); err == nil {
			if _, isArray := jsonData.([]interface{}); isArray {
				log.Printf("📥 报告上传成功: %s [数组格式]", filename)
			} else if _, isMap := jsonData.(map[string]interface{}); isMap {
				log.Printf("📥 报告上传成功: %s [字典格式]", filename)
			} else {
				log.Printf("📥 报告上传成功: %s [未知格式]", filename)
			}
		} else {
			log.Printf("📥 报告上传成功: %s [非JSON格式]", filename)
		}
	} else {
		log.Printf("📥 报告上传成功: %s", filename)
	}

	c.JSON(http.StatusOK, gin.H{
		"message":   "报告上传成功",
		"report_id": reportID,
		"filename":  filename,
	})
}

// symbolicateReportHandler 符号化报告
func symbolicateReportHandler(c *gin.Context) {
	var req struct {
		ReportID string `json:"report_id" binding:"required"`
		DsymFile string `json:"dsym_file"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 查找报告文件
	reportFile := findReportFile(req.ReportID)
	if reportFile == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "报告不存在"})
		return
	}

	// 读取报告
	data, err := os.ReadFile(reportFile)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取报告失败"})
		return
	}

	// 解析 JSON
	var report interface{}
	if err := json.Unmarshal(data, &report); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "报告格式错误"})
		return
	}

	// 查找匹配的符号表
	dsymPath := ""
	if req.DsymFile != "" {
		dsymPath = filepath.Join(DsymDir, req.DsymFile)
	} else {
		// 自动匹配
		dsymPath = findMatchingDsym(report)
	}

	if dsymPath == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "未找到匹配的符号表"})
		return
	}

	// 执行符号化
	log.Printf("🔍 开始符号化: report=%s, dsym=%s", reportFile, dsymPath)
	symbolicated, err := symbolicateReport(report, dsymPath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "符号化失败: " + err.Error()})
		return
	}

	// 保存符号化结果
	outputFile := strings.Replace(reportFile, ".json", "_symbolicated.json", 1)
	outputData, _ := json.MarshalIndent(symbolicated, "", "  ")
	os.WriteFile(outputFile, outputData, 0644)

	log.Printf("✅ 符号化完成: %s", outputFile)

	c.JSON(http.StatusOK, gin.H{
		"message": "符号化成功",
		"result":  symbolicated,
	})
}

// listReportsHandler 列出所有报告
func listReportsHandler(c *gin.Context) {
	files, err := os.ReadDir(ReportsDir)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	var reports []map[string]interface{}
	for _, file := range files {
		if file.IsDir() || strings.HasSuffix(file.Name(), "_symbolicated.json") {
			continue
		}

		info, _ := file.Info()
		parts := strings.SplitN(file.Name(), "_", 2)
		reportID := parts[0]

		// 检查是否已符号化
		symbolicatedPath := filepath.Join(ReportsDir, strings.Replace(file.Name(), ".json", "_symbolicated.json", 1))
		symbolicated := false
		if _, err := os.Stat(symbolicatedPath); err == nil {
			symbolicated = true
		}

		// 尝试读取dump_type信息
		dumpType := ""
		dumpTypeCode := -1
		reportPath := filepath.Join(ReportsDir, file.Name())
		if data, err := os.ReadFile(reportPath); err == nil {
			var reportData map[string]interface{}
			if err := json.Unmarshal(data, &reportData); err == nil {
				if dt, ok := reportData["dump_type"].(float64); ok {
					dumpTypeCode = int(dt)
					dumpType = getDumpTypeName(dumpTypeCode)
				}
			}
		}

		reports = append(reports, map[string]interface{}{
			"id":            reportID,
			"filename":      file.Name(),
			"size":          info.Size(),
			"uploaded":      info.ModTime(),
			"symbolicated":  symbolicated,
			"dump_type":     dumpType,
			"dump_type_code": dumpTypeCode,
		})
	}

	c.JSON(http.StatusOK, gin.H{"reports": reports})
}

// getDumpTypeName 根据dump_type代码返回类型名称
func getDumpTypeName(dumpType int) string {
	switch dumpType {
	case 2000:
		return "无卡顿"
	case 2001:
		return "主线程卡顿"
	case 2002:
		return "后台主线程卡顿"
	case 2003:
		return "CPU 占用过高"
	case 2007:
		return "启动阻塞"
	case 2009:
		return "线程过多"
	case 2010:
		return "被杀死前卡顿"
	case 2011:
		return "耗电监控"
	case 2013:
		return "磁盘 I/O"
	case 2014:
		return "FPS 掉帧"
	default:
		return fmt.Sprintf("类型 %d", dumpType)
	}
}

// getReportHandler 获取报告详情
func getReportHandler(c *gin.Context) {
	reportID := c.Param("id")
	reportFile := findReportFile(reportID)

	if reportFile == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "报告不存在"})
		return
	}

	// 优先返回符号化的版本
	symbolicatedFile := strings.Replace(reportFile, ".json", "_symbolicated.json", 1)
	if _, err := os.Stat(symbolicatedFile); err == nil {
		reportFile = symbolicatedFile
	}

	data, err := os.ReadFile(reportFile)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取报告失败"})
		return
	}

	var report interface{}
	if err := json.Unmarshal(data, &report); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "报告格式错误"})
		return
	}

	c.JSON(http.StatusOK, report)
}

// getFormattedReportHandler 获取格式化的可读报告
func getFormattedReportHandler(c *gin.Context) {
	reportID := c.Param("id")
	reportFile := findReportFile(reportID)

	if reportFile == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "报告不存在"})
		return
	}

	// 优先返回符号化的版本
	symbolicatedFile := strings.Replace(reportFile, ".json", "_symbolicated.json", 1)
	if _, err := os.Stat(symbolicatedFile); err == nil {
		reportFile = symbolicatedFile
	}

	data, err := os.ReadFile(reportFile)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取报告失败"})
		return
	}

	var report map[string]interface{}
	if err := json.Unmarshal(data, &report); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "报告格式错误"})
		return
	}

	// 检查是否已经有格式化的报告
	if symbInfo, ok := report["symbolication_info"].(map[string]interface{}); ok {
		if formatted, ok := symbInfo["formatted_report"].(string); ok && formatted != "" {
			// 返回纯文本格式
			c.Header("Content-Type", "text/plain; charset=utf-8")
			c.String(http.StatusOK, formatted)
			return
		}
	}

	// 如果没有格式化报告，现场生成
	formattedText := formatReportToAppleStyle(report)
	c.Header("Content-Type", "text/plain; charset=utf-8")
	c.String(http.StatusOK, formattedText)
}

// deleteReportHandler 删除报告
func deleteReportHandler(c *gin.Context) {
	reportID := c.Param("id")
	reportFile := findReportFile(reportID)

	if reportFile == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "报告不存在"})
		return
	}

	// 删除原始报告和符号化版本
	os.Remove(reportFile)
	symbolicatedFile := strings.Replace(reportFile, ".json", "_symbolicated.json", 1)
	os.Remove(symbolicatedFile)

	log.Printf("🗑️  删除报告: %s", reportFile)
	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// findReportFile 根据 ID 查找报告文件
func findReportFile(reportID string) string {
	files, err := os.ReadDir(ReportsDir)
	if err != nil {
		return ""
	}

	for _, file := range files {
		if strings.HasPrefix(file.Name(), reportID+"_") {
			return filepath.Join(ReportsDir, file.Name())
		}
	}

	return ""
}
