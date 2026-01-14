package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// ModelRanking holds ranking data for a model
type ModelRanking struct {
	Rank        int
	Model       string
	PassRate    float64
	Passed      int
	Failed      int
	Runs        int
	TotalCost   float64
	AvgCost     float64
	TotalTime   time.Duration
	AvgTime     time.Duration
	TotalTokens int
}

// ChartPoint represents a point on the scatter chart
type ChartPoint struct {
	Model    string  `json:"model"`
	X        float64 `json:"x"`
	Y        float64 `json:"y"`
	PassRate float64 `json:"passRate"`
	Cost     float64 `json:"cost"`
	Time     float64 `json:"time"`
}

// GenerateDashboard creates an HTML dashboard from results
func GenerateDashboard(results []TaskResult, outputDir string) error {
	// Create output directory
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("creating output directory: %w", err)
	}

	// Aggregate results
	agg := Aggregate(results)

	// Generate rankings
	rankings := generateRankings(agg)

	// Generate chart data
	costChartData := generateCostChartData(rankings)
	speedChartData := generateSpeedChartData(rankings)

	// Calculate summary stats
	totalTokens := 0
	for _, r := range results {
		totalTokens += r.InputTokens + r.OutputTokens
	}

	// Generate main dashboard
	if err := generateMainDashboard(agg, results, rankings, costChartData, speedChartData, totalTokens, outputDir); err != nil {
		return err
	}

	// Export raw data as JSON
	if err := exportJSON(results, agg, outputDir); err != nil {
		return err
	}

	return nil
}

func generateRankings(agg *AggregateResults) []ModelRanking {
	var rankings []ModelRanking

	for model, stats := range agg.Summary.ByModel {
		totalTokens := 0
		var totalTime time.Duration
		for _, results := range agg.ByTaskModel {
			if modelResults, ok := results[model]; ok {
				for _, r := range modelResults {
					totalTokens += r.InputTokens + r.OutputTokens
					totalTime += r.Duration
				}
			}
		}

		rankings = append(rankings, ModelRanking{
			Model:       stats.Model,
			PassRate:    stats.PassRate,
			Passed:      stats.Passed,
			Failed:      stats.Failed,
			Runs:        stats.Runs,
			TotalCost:   stats.TotalCost,
			AvgCost:     stats.AvgCost,
			TotalTime:   totalTime,
			AvgTime:     stats.AvgDuration,
			TotalTokens: totalTokens,
		})
	}

	// Sort by pass rate descending
	sort.Slice(rankings, func(i, j int) bool {
		if rankings[i].PassRate != rankings[j].PassRate {
			return rankings[i].PassRate > rankings[j].PassRate
		}
		return rankings[i].TotalCost < rankings[j].TotalCost
	})

	// Assign ranks
	for i := range rankings {
		rankings[i].Rank = i + 1
	}

	return rankings
}

func generateCostChartData(rankings []ModelRanking) []ChartPoint {
	var points []ChartPoint
	for _, r := range rankings {
		if r.TotalCost > 0 {
			points = append(points, ChartPoint{
				Model:    r.Model,
				X:        r.TotalCost,
				Y:        r.PassRate,
				PassRate: r.PassRate,
				Cost:     r.TotalCost,
			})
		}
	}
	return points
}

func generateSpeedChartData(rankings []ModelRanking) []ChartPoint {
	var points []ChartPoint
	for _, r := range rankings {
		if r.TotalTime > 0 {
			points = append(points, ChartPoint{
				Model:    r.Model,
				X:        r.TotalTime.Seconds(),
				Y:        r.PassRate,
				PassRate: r.PassRate,
				Time:     r.TotalTime.Seconds(),
			})
		}
	}
	return points
}

func generateMainDashboard(agg *AggregateResults, results []TaskResult, rankings []ModelRanking, costChart, speedChart []ChartPoint, totalTokens int, outputDir string) error {
	tmpl := template.Must(template.New("dashboard").Funcs(template.FuncMap{
		"formatDuration": func(d time.Duration) string {
			if d < time.Minute {
				return fmt.Sprintf("%.1fs", d.Seconds())
			}
			if d < time.Hour {
				return fmt.Sprintf("%.1fm", d.Minutes())
			}
			hours := int(d.Hours())
			mins := int(d.Minutes()) % 60
			secs := int(d.Seconds()) % 60
			return fmt.Sprintf("%dh%02dm%02ds", hours, mins, secs)
		},
		"formatCost": func(c float64) string {
			return fmt.Sprintf("$%.4f", c)
		},
		"formatCostShort": func(c float64) string {
			if c >= 1 {
				return fmt.Sprintf("$%.2f", c)
			}
			return fmt.Sprintf("$%.4f", c)
		},
		"formatRate": func(r float64) string {
			return fmt.Sprintf("%.1f%%", r)
		},
		"formatTokens": func(t int) string {
			if t >= 1000000 {
				return fmt.Sprintf("%.1fM", float64(t)/1000000)
			}
			if t >= 1000 {
				return fmt.Sprintf("%.1fK", float64(t)/1000)
			}
			return fmt.Sprintf("%d", t)
		},
		"passClass": func(passed bool) string {
			if passed {
				return "pass"
			}
			return "fail"
		},
		"json": func(v interface{}) template.JS {
			b, _ := json.Marshal(v)
			return template.JS(b)
		},
		"passRate": func(passed, total int) float64 {
			if total == 0 {
				return 0
			}
			return float64(passed) / float64(total) * 100
		},
		"rateColor": func(rate float64) string {
			if rate >= 80 {
				return "text-green-600"
			}
			if rate >= 50 {
				return "text-yellow-600"
			}
			return "text-red-600"
		},
		"rateBgColor": func(rate float64) string {
			if rate >= 80 {
				return "bg-green-500"
			}
			if rate >= 50 {
				return "bg-yellow-500"
			}
			return "bg-red-500"
		},
		"truncate": func(s string, max int) string {
			if len(s) <= max {
				return s
			}
			return s[:max] + "..."
		},
		"add": func(a, b int) int {
			return a + b
		},
	}).Parse(dashboardTemplate))

	data := struct {
		GeneratedAt    time.Time
		Aggregate      *AggregateResults
		Results        []TaskResult
		Rankings       []ModelRanking
		CostChartData  []ChartPoint
		SpeedChartData []ChartPoint
		TotalTokens    int
		TotalRequests  int
	}{
		GeneratedAt:    time.Now(),
		Aggregate:      agg,
		Results:        results,
		Rankings:       rankings,
		CostChartData:  costChart,
		SpeedChartData: speedChart,
		TotalTokens:    totalTokens,
		TotalRequests:  len(results),
	}

	f, err := os.Create(filepath.Join(outputDir, "index.html"))
	if err != nil {
		return fmt.Errorf("creating dashboard file: %w", err)
	}
	defer f.Close()

	return tmpl.Execute(f, data)
}

func exportJSON(results []TaskResult, agg *AggregateResults, outputDir string) error {
	// Export results
	resultsJSON, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling results: %w", err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "results.json"), resultsJSON, 0644); err != nil {
		return fmt.Errorf("writing results.json: %w", err)
	}

	// Export summary
	summaryJSON, err := json.MarshalIndent(agg.Summary, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling summary: %w", err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "summary.json"), summaryJSON, 0644); err != nil {
		return fmt.Errorf("writing summary.json: %w", err)
	}

	return nil
}

const dashboardTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenTelemetry Benchmark Results</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', system-ui, sans-serif; }
        .pass { background-color: #dcfce7; color: #166534; }
        .fail { background-color: #fee2e2; color: #991b1b; }
        .progress-bar { height: 8px; border-radius: 4px; overflow: hidden; }
        .progress-fill { height: 100%; transition: width 0.3s ease; }
        .chart-container { position: relative; height: 350px; }
        .stat-highlight {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .card { @apply bg-white rounded-xl shadow-sm border border-gray-200; }
        .table-row:hover { background-color: #f9fafb; }
        .rank-badge {
            width: 28px;
            height: 28px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 600;
            font-size: 12px;
        }
        .rank-1 { background: linear-gradient(135deg, #ffd700, #ffec8b); color: #92400e; }
        .rank-2 { background: linear-gradient(135deg, #c0c0c0, #e8e8e8); color: #374151; }
        .rank-3 { background: linear-gradient(135deg, #cd7f32, #daa06d); color: #fff; }
        .rank-other { background: #f3f4f6; color: #6b7280; }
    </style>
</head>
<body class="bg-gray-50 min-h-screen">
    <!-- Header Banner with Stats -->
    <div class="bg-gradient-to-r from-indigo-600 via-purple-600 to-pink-500 text-white">
        <div class="container mx-auto px-6 py-8">
            <h1 class="text-3xl font-bold mb-2">OpenTelemetry Benchmark</h1>
            <p class="text-indigo-100 mb-6">AI Model Performance on OpenTelemetry Instrumentation Tasks</p>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-indigo-100 text-sm">Total Spent</div>
                    <div class="text-2xl font-bold">{{formatCostShort .Aggregate.Summary.TotalCost}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-indigo-100 text-sm">LLM Requests</div>
                    <div class="text-2xl font-bold">{{.TotalRequests}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-indigo-100 text-sm">Total Tokens</div>
                    <div class="text-2xl font-bold">{{formatTokens .TotalTokens}}</div>
                </div>
                <div class="bg-white/10 backdrop-blur rounded-lg p-4">
                    <div class="text-indigo-100 text-sm">Benchmark Time</div>
                    <div class="text-2xl font-bold">{{formatDuration .Aggregate.Summary.TotalDuration}}</div>
                </div>
            </div>
        </div>
    </div>

    <div class="container mx-auto px-6 py-8 max-w-7xl">
        <!-- Success Rate Ranking -->
        <div class="card p-6 mb-8">
            <h2 class="text-xl font-semibold text-gray-900 mb-6">Success Rate Ranking</h2>
            <div class="overflow-x-auto">
                <table class="w-full">
                    <thead>
                        <tr class="text-left text-sm text-gray-500 border-b">
                            <th class="pb-3 pl-2">Rank</th>
                            <th class="pb-3">Model</th>
                            <th class="pb-3 text-center" style="width: 300px;">Pass Rate</th>
                            <th class="pb-3 text-right">Passed</th>
                            <th class="pb-3 text-right">Failed</th>
                            <th class="pb-3 text-right">Cost</th>
                            <th class="pb-3 text-right">Time</th>
                        </tr>
                    </thead>
                    <tbody>
                        {{range .Rankings}}
                        <tr class="table-row border-b border-gray-100">
                            <td class="py-4 pl-2">
                                <div class="rank-badge {{if eq .Rank 1}}rank-1{{else if eq .Rank 2}}rank-2{{else if eq .Rank 3}}rank-3{{else}}rank-other{{end}}">
                                    {{.Rank}}
                                </div>
                            </td>
                            <td class="py-4">
                                <div class="font-medium text-gray-900">{{.Model}}</div>
                            </td>
                            <td class="py-4 px-4">
                                <div class="flex items-center gap-3">
                                    <div class="progress-bar bg-gray-200 flex-1">
                                        <div class="progress-fill {{rateBgColor .PassRate}}" style="width: {{.PassRate}}%"></div>
                                    </div>
                                    <span class="font-semibold {{rateColor .PassRate}}" style="min-width: 50px;">{{formatRate .PassRate}}</span>
                                </div>
                            </td>
                            <td class="py-4 text-right">
                                <span class="text-green-600 font-medium">{{.Passed}}</span>
                            </td>
                            <td class="py-4 text-right">
                                <span class="text-red-600 font-medium">{{.Failed}}</span>
                            </td>
                            <td class="py-4 text-right font-mono text-sm text-gray-600">{{formatCostShort .TotalCost}}</td>
                            <td class="py-4 text-right font-mono text-sm text-gray-600">{{formatDuration .TotalTime}}</td>
                        </tr>
                        {{end}}
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Charts Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
            <!-- Cost vs Accuracy Chart -->
            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Cost vs Accuracy</h2>
                <p class="text-sm text-gray-500 mb-4">Lower cost + higher accuracy = better (top-left is ideal)</p>
                <div class="chart-container">
                    <canvas id="costChart"></canvas>
                </div>
            </div>

            <!-- Speed vs Accuracy Chart -->
            <div class="card p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Speed vs Accuracy</h2>
                <p class="text-sm text-gray-500 mb-4">Lower time + higher accuracy = better (top-left is ideal)</p>
                <div class="chart-container">
                    <canvas id="speedChart"></canvas>
                </div>
            </div>
        </div>

        <!-- Task Results Matrix -->
        <div class="card p-6 mb-8">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Task Results Matrix</h2>
            <div class="overflow-x-auto">
                <table class="w-full text-sm">
                    <thead>
                        <tr class="text-left text-gray-500 border-b">
                            <th class="pb-3 pr-4">Task</th>
                            {{range .Aggregate.Models}}
                            <th class="pb-3 px-2 text-center">{{truncate . 15}}</th>
                            {{end}}
                        </tr>
                    </thead>
                    <tbody>
                        {{range $task := .Aggregate.Tasks}}
                        <tr class="border-b border-gray-100">
                            <td class="py-3 pr-4 font-medium text-gray-900">{{$task}}</td>
                            {{range $model := $.Aggregate.Models}}
                            <td class="py-3 px-2 text-center">
                                {{with index (index $.Aggregate.ByTaskModel $task) $model}}
                                {{range .}}
                                <span class="inline-block w-5 h-5 rounded {{if .Passed}}bg-green-500{{else}}bg-red-500{{end}}" title="{{if .Passed}}Pass{{else}}Fail{{end}} - {{formatCost .CostUSD}}"></span>
                                {{end}}
                                {{else}}
                                <span class="text-gray-300">—</span>
                                {{end}}
                            </td>
                            {{end}}
                        </tr>
                        {{end}}
                    </tbody>
                </table>
            </div>
            <div class="mt-4 flex gap-6 text-sm text-gray-500">
                <span class="flex items-center"><span class="w-3 h-3 rounded bg-green-500 mr-2"></span> Pass</span>
                <span class="flex items-center"><span class="w-3 h-3 rounded bg-red-500 mr-2"></span> Fail</span>
            </div>
        </div>

        <!-- Detailed Attempts Table -->
        <div class="card p-6">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">All Attempts</h2>
            <div class="overflow-x-auto">
                <table class="w-full text-sm">
                    <thead>
                        <tr class="text-left text-gray-500 border-b">
                            <th class="pb-3">Model</th>
                            <th class="pb-3">Task</th>
                            <th class="pb-3 text-right">Cost</th>
                            <th class="pb-3 text-right">Duration</th>
                            <th class="pb-3 text-right">Tokens</th>
                            <th class="pb-3 text-center">Status</th>
                            <th class="pb-3">Error</th>
                        </tr>
                    </thead>
                    <tbody>
                        {{range .Results}}
                        <tr class="table-row border-b border-gray-100">
                            <td class="py-3">
                                <div class="font-medium text-gray-900">{{.ModelDisplay}}</div>
                            </td>
                            <td class="py-3">
                                <a href="#" class="text-indigo-600 hover:underline">{{.TaskName}}</a>
                            </td>
                            <td class="py-3 text-right font-mono">{{formatCost .CostUSD}}</td>
                            <td class="py-3 text-right font-mono">{{formatDuration .Duration}}</td>
                            <td class="py-3 text-right font-mono text-gray-500">{{formatTokens (add .InputTokens .OutputTokens)}}</td>
                            <td class="py-3 text-center">
                                {{if .Passed}}
                                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                                    PASS
                                </span>
                                {{else}}
                                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                                    FAIL
                                </span>
                                {{end}}
                            </td>
                            <td class="py-3 text-gray-500 text-xs max-w-xs truncate" title="{{.Error}}">
                                {{if .Error}}{{truncate .Error 50}}{{else}}-{{end}}
                            </td>
                        </tr>
                        {{end}}
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Footer -->
        <div class="mt-8 text-center text-gray-500 text-sm">
            <p>Generated: {{.GeneratedAt.Format "2006-01-02 15:04:05"}} |
               <a href="results.json" class="text-indigo-500 hover:underline">Download JSON</a>
            </p>
        </div>
    </div>

    <script>
        // Chart data
        const costData = {{json .CostChartData}};
        const speedData = {{json .SpeedChartData}};

        // Color palette for models
        const colors = [
            '#6366f1', '#8b5cf6', '#d946ef', '#ec4899', '#f43f5e',
            '#f97316', '#eab308', '#84cc16', '#22c55e', '#14b8a6',
            '#06b6d4', '#0ea5e9', '#3b82f6', '#6366f1'
        ];

        function getColor(index) {
            return colors[index % colors.length];
        }

        // Cost vs Accuracy Chart
        const costCtx = document.getElementById('costChart').getContext('2d');
        new Chart(costCtx, {
            type: 'scatter',
            data: {
                datasets: [{
                    label: 'Models',
                    data: costData.map((d, i) => ({
                        x: d.x,
                        y: d.y,
                        model: d.model
                    })),
                    backgroundColor: costData.map((_, i) => getColor(i)),
                    pointRadius: 10,
                    pointHoverRadius: 12,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        callbacks: {
                            label: (ctx) => {
                                const d = costData[ctx.dataIndex];
                                return d.model + ': ' + d.y.toFixed(1) + '% @ $' + d.x.toFixed(4);
                            }
                        }
                    }
                },
                scales: {
                    x: {
                        type: 'logarithmic',
                        title: { display: true, text: 'Total Cost ($)' },
                        ticks: {
                            callback: (v) => '$' + v.toFixed(2)
                        }
                    },
                    y: {
                        min: 0,
                        max: 100,
                        title: { display: true, text: 'Success Rate (%)' },
                        ticks: {
                            callback: (v) => v + '%'
                        }
                    }
                }
            }
        });

        // Speed vs Accuracy Chart
        const speedCtx = document.getElementById('speedChart').getContext('2d');
        new Chart(speedCtx, {
            type: 'scatter',
            data: {
                datasets: [{
                    label: 'Models',
                    data: speedData.map((d, i) => ({
                        x: d.x,
                        y: d.y,
                        model: d.model
                    })),
                    backgroundColor: speedData.map((_, i) => getColor(i)),
                    pointRadius: 10,
                    pointHoverRadius: 12,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        callbacks: {
                            label: (ctx) => {
                                const d = speedData[ctx.dataIndex];
                                const time = d.x < 60 ? d.x.toFixed(1) + 's' : (d.x/60).toFixed(1) + 'm';
                                return d.model + ': ' + d.y.toFixed(1) + '% @ ' + time;
                            }
                        }
                    }
                },
                scales: {
                    x: {
                        type: 'logarithmic',
                        title: { display: true, text: 'Total Time (seconds)' },
                        ticks: {
                            callback: (v) => v < 60 ? v + 's' : (v/60).toFixed(0) + 'm'
                        }
                    },
                    y: {
                        min: 0,
                        max: 100,
                        title: { display: true, text: 'Success Rate (%)' },
                        ticks: {
                            callback: (v) => v + '%'
                        }
                    }
                }
            }
        });
    </script>
</body>
</html>`