package main

import (
	"testing"
)

func TestExtractDsymInfo(t *testing.T) {
	// 这是一个示例测试
	// 实际使用时需要有真实的 dSYM 文件
	t.Log("dSYM 信息提取测试")
	
	// TODO: 添加实际的测试用例
	// uuid, arch, err := extractDsymInfo("path/to/test.app")
	// if err != nil {
	//     t.Errorf("提取失败: %v", err)
	// }
}

func TestParseSymbolOutput(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantFile   string
		wantLine   string
	}{
		{
			name:     "标准格式",
			input:    "-[TestLagViewController simulateLag] (in MatrixTestApp) (TestLagViewController.mm:145)",
			wantFile: "TestLagViewController.mm",
			wantLine: "145",
		},
		{
			name:     "Swift 文件",
			input:    "MyClass.doSomething() (in MyApp) (MyFile.swift:42)",
			wantFile: "MyFile.swift",
			wantLine: "42",
		},
		{
			name:     "C 文件",
			input:    "my_function (in MyApp) (myfile.c:100)",
			wantFile: "myfile.c",
			wantLine: "100",
		},
		{
			name:     "无匹配",
			input:    "0x123456789",
			wantFile: "",
			wantLine: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotFile, gotLine := parseSymbolOutput(tt.input)
			
			if gotFile != tt.wantFile {
				t.Errorf("parseSymbolOutput() 文件名 = %v, want %v", gotFile, tt.wantFile)
			}
			
			if gotLine != tt.wantLine {
				t.Errorf("parseSymbolOutput() 行号 = %v, want %v", gotLine, tt.wantLine)
			}
		})
	}
}

func TestFindMatchingDsym(t *testing.T) {
	t.Log("符号表匹配测试")
	
	// 示例报告数据
	report := map[string]interface{}{
		"binary_images": []interface{}{
			map[string]interface{}{
				"name":       "/var/containers/Bundle/Application/XXX/MatrixTestApp.app/MatrixTestApp",
				"uuid":       "FD7CB3D0-06EF-3582-9C99-432ABD79F29C",
				"image_addr": float64(0x100000000),
			},
		},
	}

	// TODO: 添加实际的匹配逻辑测试
	result := findMatchingDsym(report)
	t.Logf("匹配结果: %s", result)
}

func BenchmarkSymbolicateAddress(b *testing.B) {
	// 性能测试
	// TODO: 添加实际的性能测试用例
	b.Log("符号化性能测试")
}

