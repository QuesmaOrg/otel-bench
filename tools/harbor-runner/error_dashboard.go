package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ErrorCategory classifies errors as infrastructure or task-related
type ErrorCategory string

const (
	CategoryInfrastructure ErrorCategory = "Infrastructure"
	CategoryTaskRelated    ErrorCategory = "Task-Related"
	CategoryUnknown        ErrorCategory = "Unknown"
)

// ErrorInfo holds parsed error information
type ErrorInfo struct {
	TaskName      string
	ModelName     string
	ErrorType     string
	ErrorMessage  string
	Category      ErrorCategory
	OccurredAt    time.Time
	TrialDir      string
	ShortMessage  string
}

// ErrorSummary holds aggregated error statistics
type ErrorSummary struct {
	TotalErrors       int
	ByType            map[string]int
	ByCategory        map[ErrorCategory]int
	ByModel           map[string]int
	ByTask            map[string]int
	InfrastructureErrors []ErrorInfo
	TaskErrors        []ErrorInfo
	Timeline          []ErrorInfo
}

// ClassifyError determines if an error is infrastructure or task-related
func ClassifyError(errorType, errorMessage string) ErrorCategory {
	// Infrastructure errors - external system failures
	infrastructurePatterns := []string{
		"NotFoundError",      // Model not available
		"RateLimitError",     // API rate limiting
		"APIError",           // Generic API errors
		"ConnectionError",    // Network issues
		"ServiceUnavailable", // Service down
		"InternalServerError",
		"no space left on device",
		"out of memory",
		"disk quota exceeded",
		"connection refused",
		"connection reset",
		"timeout.*upstream",
		"temporarily rate-limited",
		"No endpoints found",
	}

	for _, pattern := range infrastructurePatterns {
		matched, _ := regexp.MatchString("(?i)"+pattern, errorType+errorMessage)
		if matched {
			return CategoryInfrastructure
		}
	}

	// Task-related errors - failures during task execution
	taskPatterns := []string{
		"AgentTimeoutError",      // Agent took too long (could be complex task)
		"VerifierTimeoutError",   // Verifier took too long
		"RewardFileNotFoundError", // Task didn't produce expected output
		"BadRequestError",        // Usually prompt too long
		"prompt is too long",
	}

	for _, pattern := range taskPatterns {
		matched, _ := regexp.MatchString("(?i)"+pattern, errorType+errorMessage)
		if matched {
			return CategoryTaskRelated
		}
	}

	return CategoryUnknown
}

// ExtractShortMessage creates a human-readable short error message
func ExtractShortMessage(errorType, errorMessage string) string {
	switch errorType {
	case "AgentTimeoutError":
		// Extract timeout duration
		re := regexp.MustCompile(`(\d+\.?\d*)\s*seconds`)
		if match := re.FindStringSubmatch(errorMessage); len(match) > 1 {
			return fmt.Sprintf("Agent timeout after %ss", match[1])
		}
		return "Agent timeout"
	case "VerifierTimeoutError":
		re := regexp.MustCompile(`(\d+\.?\d*)\s*seconds`)
		if match := re.FindStringSubmatch(errorMessage); len(match) > 1 {
			return fmt.Sprintf("Verifier timeout after %ss", match[1])
		}
		return "Verifier timeout"
	case "NotFoundError":
		if strings.Contains(errorMessage, "No endpoints found") {
			re := regexp.MustCompile(`for\s+([^\s.]+)`)
			if match := re.FindStringSubmatch(errorMessage); len(match) > 1 {
				return fmt.Sprintf("Model unavailable: %s", match[1])
			}
		}
		return "Resource not found"
	case "BadRequestError":
		if strings.Contains(errorMessage, "prompt is too long") {
			re := regexp.MustCompile(`(\d+)\s*tokens\s*>\s*(\d+)`)
			if match := re.FindStringSubmatch(errorMessage); len(match) > 2 {
				return fmt.Sprintf("Prompt too long: %s > %s tokens", match[1], match[2])
			}
		}
		return "Bad request"
	case "RateLimitError":
		return "Rate limited by API"
	case "RewardFileNotFoundError":
		return "Task output not found"
	default:
		// Truncate long messages
		if len(errorMessage) > 60 {
			return errorMessage[:57] + "..."
		}
		return errorMessage
	}
}

// AnalyzeErrors parses results and extracts error information
func AnalyzeErrors(results []TaskResult) *ErrorSummary {
	summary := &ErrorSummary{
		ByType:     make(map[string]int),
		ByCategory: make(map[ErrorCategory]int),
		ByModel:    make(map[string]int),
		ByTask:     make(map[string]int),
	}

	for _, r := range results {
		if r.Error == "" {
			continue
		}

		// Parse error type from the error message
		errorType := "Unknown"
		errorMessage := r.Error

		// Try to extract error type from the message
		// First check for exact type names
		typePatterns := []string{
			"AgentTimeoutError",
			"VerifierTimeoutError",
			"NotFoundError",
			"BadRequestError",
			"RateLimitError",
			"RewardFileNotFoundError",
			"APIError",
		}

		for _, pattern := range typePatterns {
			if strings.Contains(r.Error, pattern) {
				errorType = pattern
				break
			}
		}

		// Also check for message patterns if type not found
		if errorType == "Unknown" {
			messagePatternsToType := map[string]string{
				"Agent execution timed out":    "AgentTimeoutError",
				"Verifier execution timed out": "VerifierTimeoutError",
				"No endpoints found":           "NotFoundError",
				"prompt is too long":           "BadRequestError",
				"rate-limited":                 "RateLimitError",
			}
			for pattern, typ := range messagePatternsToType {
				if strings.Contains(r.Error, pattern) {
					errorType = typ
					break
				}
			}
		}

		category := ClassifyError(errorType, errorMessage)
		shortMessage := ExtractShortMessage(errorType, errorMessage)

		errInfo := ErrorInfo{
			TaskName:     r.TaskName,
			ModelName:    r.ModelName,
			ErrorType:    errorType,
			ErrorMessage: errorMessage,
			Category:     category,
			OccurredAt:   r.FinishedAt,
			TrialDir:     r.TrialDir,
			ShortMessage: shortMessage,
		}

		summary.TotalErrors++
		summary.ByType[errorType]++
		summary.ByCategory[category]++
		summary.ByModel[r.ModelName]++
		summary.ByTask[r.TaskName]++

		if category == CategoryInfrastructure {
			summary.InfrastructureErrors = append(summary.InfrastructureErrors, errInfo)
		} else {
			summary.TaskErrors = append(summary.TaskErrors, errInfo)
		}

		summary.Timeline = append(summary.Timeline, errInfo)
	}

	// Sort timeline by occurrence time
	sort.Slice(summary.Timeline, func(i, j int) bool {
		return summary.Timeline[i].OccurredAt.Before(summary.Timeline[j].OccurredAt)
	})

	return summary
}

// ErrorTypeCount for sorting
type ErrorTypeCount struct {
	Type  string
	Count int
}

// ModelErrorCount for sorting
type ModelErrorCount struct {
	Model string
	Count int
}

// TaskErrorCount for sorting
type TaskErrorCount struct {
	Task  string
	Count int
}

// GenerateErrorDashboard creates an HTML error dashboard
func GenerateErrorDashboard(results []TaskResult, outputDir string) error {
	// Create output directory
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("creating output directory: %w", err)
	}

	summary := AnalyzeErrors(results)

	// Convert maps to sorted slices for template
	var typeStats []ErrorTypeCount
	for t, c := range summary.ByType {
		typeStats = append(typeStats, ErrorTypeCount{Type: t, Count: c})
	}
	sort.Slice(typeStats, func(i, j int) bool {
		return typeStats[i].Count > typeStats[j].Count
	})

	var modelStats []ModelErrorCount
	for m, c := range summary.ByModel {
		modelStats = append(modelStats, ModelErrorCount{Model: m, Count: c})
	}
	sort.Slice(modelStats, func(i, j int) bool {
		return modelStats[i].Count > modelStats[j].Count
	})

	var taskStats []TaskErrorCount
	for t, c := range summary.ByTask {
		taskStats = append(taskStats, TaskErrorCount{Task: t, Count: c})
	}
	sort.Slice(taskStats, func(i, j int) bool {
		return taskStats[i].Count > taskStats[j].Count
	})

	// Calculate total runs and error rate
	totalRuns := len(results)
	errorRate := 0.0
	if totalRuns > 0 {
		errorRate = float64(summary.TotalErrors) / float64(totalRuns) * 100
	}

	tmpl := template.Must(template.New("error_dashboard").Funcs(template.FuncMap{
		"formatTime": func(t time.Time) string {
			if t.IsZero() {
				return "-"
			}
			return t.Format("2006-01-02 15:04:05")
		},
		"truncate": func(s string, max int) string {
			if len(s) <= max {
				return s
			}
			return s[:max] + "..."
		},
		"categoryClass": func(c ErrorCategory) string {
			switch c {
			case CategoryInfrastructure:
				return "bg-orange-100 text-orange-800"
			case CategoryTaskRelated:
				return "bg-blue-100 text-blue-800"
			default:
				return "bg-gray-100 text-gray-800"
			}
		},
		"formatRate": func(r float64) string {
			return fmt.Sprintf("%.1f%%", r)
		},
		"mulf": func(a, b float64) float64 {
			return a * b
		},
		"divf": func(a, b int) float64 {
			if b == 0 {
				return 0
			}
			return float64(a) / float64(b)
		},
	}).Parse(errorDashboardTemplate))

	data := struct {
		GeneratedAt          time.Time
		Summary              *ErrorSummary
		TypeStats            []ErrorTypeCount
		ModelStats           []ModelErrorCount
		TaskStats            []TaskErrorCount
		TotalRuns            int
		ErrorRate            float64
		InfrastructureCount  int
		TaskRelatedCount     int
	}{
		GeneratedAt:         time.Now(),
		Summary:             summary,
		TypeStats:           typeStats,
		ModelStats:          modelStats,
		TaskStats:           taskStats,
		TotalRuns:           totalRuns,
		ErrorRate:           errorRate,
		InfrastructureCount: summary.ByCategory[CategoryInfrastructure],
		TaskRelatedCount:    summary.ByCategory[CategoryTaskRelated] + summary.ByCategory[CategoryUnknown],
	}

	f, err := os.Create(filepath.Join(outputDir, "errors.html"))
	if err != nil {
		return fmt.Errorf("creating error dashboard file: %w", err)
	}
	defer f.Close()

	if err := tmpl.Execute(f, data); err != nil {
		return fmt.Errorf("executing template: %w", err)
	}

	// Export error data as JSON
	errorsJSON, err := json.MarshalIndent(struct {
		Summary     *ErrorSummary
		TypeStats   []ErrorTypeCount
		ModelStats  []ModelErrorCount
		TaskStats   []TaskErrorCount
	}{
		Summary:    summary,
		TypeStats:  typeStats,
		ModelStats: modelStats,
		TaskStats:  taskStats,
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling errors: %w", err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "errors.json"), errorsJSON, 0644); err != nil {
		return fmt.Errorf("writing errors.json: %w", err)
	}

	return nil
}

const errorDashboardTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Harbor Error Analysis</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', system-ui, sans-serif; }
        .card { @apply bg-white rounded-xl shadow-sm border border-gray-200; }
        .table-row:hover { background-color: #f9fafb; }
    </style>
</head>
<body class="bg-gray-50 min-h-screen">
    <!-- Header Banner -->
    <div class="bg-gradient-to-r from-red-600 via-orange-500 to-yellow-500 text-white">
        <div class="container mx-auto px-6 py-8">
            <h1 class="text-3xl font-bold mb-2">Harbor Error Analysis</h1>
            <p class="text-red-100 mb-6">Infrastructure and Task Execution Failures</p>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-red-100 text-sm">Total Errors</div>
                    <div class="text-2xl font-bold">{{.Summary.TotalErrors}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-red-100 text-sm">Error Rate</div>
                    <div class="text-2xl font-bold">{{formatRate .ErrorRate}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-orange-100 text-sm">Infrastructure</div>
                    <div class="text-2xl font-bold">{{.InfrastructureCount}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-yellow-100 text-sm">Task-Related</div>
                    <div class="text-2xl font-bold">{{.TaskRelatedCount}}</div>
                </div>
            </div>
        </div>
    </div>

    <div class="container mx-auto px-6 py-8 max-w-7xl">
        {{if eq .Summary.TotalErrors 0}}
        <div class="card p-12 text-center">
            <div class="text-6xl mb-4">✅</div>
            <h2 class="text-2xl font-semibold text-gray-900 mb-2">No Errors Found</h2>
            <p class="text-gray-500">All {{.TotalRuns}} task executions completed without errors.</p>
        </div>
        {{else}}

        <!-- Error Type Distribution -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Errors by Type</h2>
                <div class="space-y-3">
                    {{range .TypeStats}}
                    <div class="flex items-center justify-between">
                        <span class="font-medium text-gray-700">{{.Type}}</span>
                        <div class="flex items-center gap-3">
                            <div class="w-32 bg-gray-200 rounded-full h-2">
                                <div class="bg-red-500 h-2 rounded-full" style="width: {{if $.Summary.TotalErrors}}{{printf "%.0f" (mulf (divf .Count $.Summary.TotalErrors) 100)}}{{else}}0{{end}}%"></div>
                            </div>
                            <span class="text-sm font-semibold text-gray-900 w-8 text-right">{{.Count}}</span>
                        </div>
                    </div>
                    {{end}}
                </div>
            </div>

            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Error Categories</h2>
                <div class="h-64">
                    <canvas id="categoryChart"></canvas>
                </div>
                <div class="mt-4 grid grid-cols-2 gap-4 text-sm">
                    <div class="flex items-center gap-2">
                        <span class="w-3 h-3 rounded bg-orange-500"></span>
                        <span class="text-gray-600">Infrastructure: API failures, rate limits, unavailable models</span>
                    </div>
                    <div class="flex items-center gap-2">
                        <span class="w-3 h-3 rounded bg-blue-500"></span>
                        <span class="text-gray-600">Task-Related: Timeouts, prompt too long, missing outputs</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Errors by Model and Task -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Errors by Model</h2>
                <div class="overflow-y-auto max-h-64">
                    <table class="w-full text-sm">
                        <thead class="sticky top-0 bg-white">
                            <tr class="text-left text-gray-500 border-b">
                                <th class="pb-2">Model</th>
                                <th class="pb-2 text-right">Errors</th>
                            </tr>
                        </thead>
                        <tbody>
                            {{range .ModelStats}}
                            <tr class="border-b border-gray-100">
                                <td class="py-2 font-medium text-gray-700" title="{{.Model}}">{{truncate .Model 50}}</td>
                                <td class="py-2 text-right">
                                    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
                                        {{.Count}}
                                    </span>
                                </td>
                            </tr>
                            {{end}}
                        </tbody>
                    </table>
                </div>
            </div>

            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Errors by Task</h2>
                <div class="overflow-y-auto max-h-64">
                    <table class="w-full text-sm">
                        <thead class="sticky top-0 bg-white">
                            <tr class="text-left text-gray-500 border-b">
                                <th class="pb-2">Task</th>
                                <th class="pb-2 text-right">Errors</th>
                            </tr>
                        </thead>
                        <tbody>
                            {{range .TaskStats}}
                            <tr class="border-b border-gray-100">
                                <td class="py-2 font-medium text-gray-700">{{.Task}}</td>
                                <td class="py-2 text-right">
                                    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
                                        {{.Count}}
                                    </span>
                                </td>
                            </tr>
                            {{end}}
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <!-- Infrastructure Errors -->
        {{if .Summary.InfrastructureErrors}}
        <div class="card p-6 mb-8">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">
                <span class="inline-flex items-center gap-2">
                    <span class="w-3 h-3 rounded bg-orange-500"></span>
                    Infrastructure Errors ({{len .Summary.InfrastructureErrors}})
                </span>
            </h2>
            <p class="text-sm text-gray-500 mb-4">These errors indicate external system failures that may warrant re-running affected tasks.</p>
            <div class="overflow-x-auto">
                <table class="w-full text-sm">
                    <thead>
                        <tr class="text-left text-gray-500 border-b">
                            <th class="pb-3">Time</th>
                            <th class="pb-3">Model</th>
                            <th class="pb-3">Task</th>
                            <th class="pb-3">Error Type</th>
                            <th class="pb-3">Message</th>
                        </tr>
                    </thead>
                    <tbody>
                        {{range .Summary.InfrastructureErrors}}
                        <tr class="table-row border-b border-gray-100">
                            <td class="py-3 text-gray-500 font-mono text-xs whitespace-nowrap">{{formatTime .OccurredAt}}</td>
                            <td class="py-3 font-medium" title="{{.ModelName}}">{{truncate .ModelName 40}}</td>
                            <td class="py-3">{{.TaskName}}</td>
                            <td class="py-3">
                                <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-orange-100 text-orange-800">
                                    {{.ErrorType}}
                                </span>
                            </td>
                            <td class="py-3 text-gray-600" title="{{.ErrorMessage}}">{{.ShortMessage}}</td>
                        </tr>
                        {{end}}
                    </tbody>
                </table>
            </div>
        </div>
        {{end}}

        <!-- Task-Related Errors -->
        {{if .Summary.TaskErrors}}
        <div class="card p-6 mb-8">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">
                <span class="inline-flex items-center gap-2">
                    <span class="w-3 h-3 rounded bg-blue-500"></span>
                    Task-Related Errors ({{len .Summary.TaskErrors}})
                </span>
            </h2>
            <p class="text-sm text-gray-500 mb-4">These errors occurred during task execution and may indicate task complexity or model limitations.</p>
            <div class="overflow-x-auto">
                <table class="w-full text-sm">
                    <thead>
                        <tr class="text-left text-gray-500 border-b">
                            <th class="pb-3">Time</th>
                            <th class="pb-3">Model</th>
                            <th class="pb-3">Task</th>
                            <th class="pb-3">Error Type</th>
                            <th class="pb-3">Message</th>
                        </tr>
                    </thead>
                    <tbody>
                        {{range .Summary.TaskErrors}}
                        <tr class="table-row border-b border-gray-100">
                            <td class="py-3 text-gray-500 font-mono text-xs whitespace-nowrap">{{formatTime .OccurredAt}}</td>
                            <td class="py-3 font-medium" title="{{.ModelName}}">{{truncate .ModelName 40}}</td>
                            <td class="py-3">{{.TaskName}}</td>
                            <td class="py-3">
                                <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800">
                                    {{.ErrorType}}
                                </span>
                            </td>
                            <td class="py-3 text-gray-600" title="{{.ErrorMessage}}">{{.ShortMessage}}</td>
                        </tr>
                        {{end}}
                    </tbody>
                </table>
            </div>
        </div>
        {{end}}

        {{end}}

        <!-- Footer -->
        <div class="mt-8 text-center text-gray-500 text-sm">
            <p>Generated: {{.GeneratedAt.Format "2006-01-02 15:04:05"}} |
               <a href="errors.json" class="text-indigo-500 hover:underline">Download JSON</a> |
               <a href="index.html" class="text-indigo-500 hover:underline">Back to Benchmark</a>
            </p>
        </div>
    </div>

    {{if .Summary.TotalErrors}}
    <script>
        const categoryCtx = document.getElementById('categoryChart').getContext('2d');
        new Chart(categoryCtx, {
            type: 'doughnut',
            data: {
                labels: ['Infrastructure', 'Task-Related'],
                datasets: [{
                    data: [{{.InfrastructureCount}}, {{.TaskRelatedCount}}],
                    backgroundColor: ['#f97316', '#3b82f6'],
                    borderWidth: 0,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        position: 'bottom'
                    }
                }
            }
        });
    </script>
    {{end}}
</body>
</html>`