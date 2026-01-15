package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// HarborResult represents the structure of result.json
type HarborResult struct {
	ID         string `json:"id"`
	TaskName   string `json:"task_name"`
	TrialName  string `json:"trial_name"`
	TrialURI   string `json:"trial_uri"`
	TaskID     struct {
		Path string `json:"path"`
	} `json:"task_id"`
	Config struct {
		Agent struct {
			Name      string `json:"name"`
			ModelName string `json:"model_name"`
		} `json:"agent"`
	} `json:"config"`
	AgentResult *struct {
		NInputTokens  int     `json:"n_input_tokens"`
		NCacheTokens  int     `json:"n_cache_tokens"`
		NOutputTokens int     `json:"n_output_tokens"`
		CostUSD       float64 `json:"cost_usd"`
		Metadata      struct {
			NEpisodes int `json:"n_episodes"`
		} `json:"metadata"`
	} `json:"agent_result"`
	VerifierResult *struct {
		Rewards struct {
			Reward float64 `json:"reward"`
		} `json:"rewards"`
	} `json:"verifier_result"`
	ExceptionInfo *struct {
		Type      string `json:"exception_type"`
		Message   string `json:"exception_message"`
		Traceback string `json:"exception_traceback"`
	} `json:"exception_info"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at"`
}

// ParsedResult is the simplified parsed result
type ParsedResult struct {
	TaskName     string
	ModelName    string
	Attempt      int
	Passed       bool
	Reward       float64
	CostUSD      float64
	InputTokens  int
	OutputTokens int
	CacheTokens  int
	Turns        int
	Duration     time.Duration
	StartedAt    time.Time
	FinishedAt   time.Time
	Error        string
}

// ParseResultFile parses a single result.json file
func ParseResultFile(path string) (*ParsedResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading result file: %w", err)
	}

	var hr HarborResult
	if err := json.Unmarshal(data, &hr); err != nil {
		return nil, fmt.Errorf("parsing result JSON: %w", err)
	}

	result := &ParsedResult{
		TaskName:  hr.TaskName,
		ModelName: hr.Config.Agent.ModelName,
	}

	// Parse timestamps
	if hr.StartedAt != "" {
		result.StartedAt, _ = time.Parse("2006-01-02T15:04:05.000000", hr.StartedAt)
	}
	if hr.FinishedAt != "" {
		result.FinishedAt, _ = time.Parse("2006-01-02T15:04:05.000000", hr.FinishedAt)
	}
	if !result.StartedAt.IsZero() && !result.FinishedAt.IsZero() {
		result.Duration = result.FinishedAt.Sub(result.StartedAt)
	}

	// Parse agent result
	if hr.AgentResult != nil {
		result.InputTokens = hr.AgentResult.NInputTokens
		result.OutputTokens = hr.AgentResult.NOutputTokens
		result.CacheTokens = hr.AgentResult.NCacheTokens
		result.CostUSD = hr.AgentResult.CostUSD
		result.Turns = hr.AgentResult.Metadata.NEpisodes
	}

	// Parse verifier result
	if hr.VerifierResult != nil {
		result.Reward = hr.VerifierResult.Rewards.Reward
		result.Passed = result.Reward >= 1.0
	}

	// Check for exceptions
	if hr.ExceptionInfo != nil && hr.ExceptionInfo.Message != "" {
		result.Error = hr.ExceptionInfo.Message
	}

	return result, nil
}

// ParseJobsDirectory parses all results in a jobs directory
func ParseJobsDirectory(jobsDir string) ([]TaskResult, error) {
	var results []TaskResult

	// Walk the jobs directory
	err := filepath.Walk(jobsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip if not result.json
		if info.IsDir() || info.Name() != "result.json" {
			return nil
		}

		// Skip job-level result.json (we want trial-level)
		// Job directories have format: YYYY-MM-DD__HH-MM-SS
		// Trial directories have format: taskname__hash
		parent := filepath.Base(filepath.Dir(path))
		if !strings.Contains(parent, "__") {
			return nil
		}
		// Skip if parent looks like a job directory (starts with date pattern)
		if len(parent) >= 10 && parent[4] == '-' && parent[7] == '-' {
			return nil
		}

		parsed, err := ParseResultFile(path)
		if err != nil {
			// Log but continue
			fmt.Printf("Warning: Could not parse %s: %v\n", path, err)
			return nil
		}

		result := TaskResult{
			TaskName:     parsed.TaskName,
			TaskPath:     filepath.Dir(path),
			ModelName:    parsed.ModelName,
			ModelDisplay: formatModelName(parsed.ModelName),
			Attempt:      1, // Could be parsed from directory name
			Passed:       parsed.Passed,
			Reward:       parsed.Reward,
			CostUSD:      parsed.CostUSD,
			InputTokens:  parsed.InputTokens,
			OutputTokens: parsed.OutputTokens,
			CacheTokens:  parsed.CacheTokens,
			Duration:     parsed.Duration,
			StartedAt:    parsed.StartedAt,
			FinishedAt:   parsed.FinishedAt,
			Error:        parsed.Error,
			TrialDir:     filepath.Dir(path),
		}

		results = append(results, result)
		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("walking jobs directory: %w", err)
	}

	// Sort by task name, then model, then start time
	sort.Slice(results, func(i, j int) bool {
		if results[i].TaskName != results[j].TaskName {
			return results[i].TaskName < results[j].TaskName
		}
		if results[i].ModelName != results[j].ModelName {
			return results[i].ModelName < results[j].ModelName
		}
		return results[i].StartedAt.Before(results[j].StartedAt)
	})

	return results, nil
}

func formatModelName(name string) string {
	name = strings.ReplaceAll(name, "claude-", "Claude ")
	name = strings.ReplaceAll(name, "gpt-", "GPT-")
	name = strings.ReplaceAll(name, "openrouter/", "")
	name = strings.ReplaceAll(name, "anthropic/", "")

	// Remove date suffixes
	parts := strings.Split(name, "-")
	var cleaned []string
	for _, p := range parts {
		// Skip if it looks like a date (all digits and length > 4)
		isDate := true
		for _, c := range p {
			if c < '0' || c > '9' {
				isDate = false
				break
			}
		}
		if isDate && len(p) >= 8 {
			continue
		}
		cleaned = append(cleaned, p)
	}

	return strings.Join(cleaned, " ")
}

// AggregateResults groups results by task and model
type AggregateResults struct {
	Tasks       []string
	Models      []string
	ByTaskModel map[string]map[string][]TaskResult
	Summary     BenchmarkSummary
}

// BenchmarkSummary holds overall statistics
type BenchmarkSummary struct {
	TotalRuns       int
	TotalPassed     int
	TotalFailed     int
	TotalCost       float64
	TotalDuration   time.Duration
	ByModel         map[string]ModelSummary
	ByTask          map[string]TaskSummary
}

// ModelSummary holds per-model statistics
type ModelSummary struct {
	Model       string
	Runs        int
	Passed      int
	Failed      int
	PassRate    float64
	TotalCost   float64
	AvgCost     float64
	AvgDuration time.Duration
}

// TaskSummary holds per-task statistics
type TaskSummary struct {
	Task      string
	Runs      int
	Passed    int
	Failed    int
	PassRate  float64
	TotalCost float64
	BestModel string
}

// Aggregate creates aggregated results from raw results
func Aggregate(results []TaskResult) *AggregateResults {
	agg := &AggregateResults{
		ByTaskModel: make(map[string]map[string][]TaskResult),
		Summary: BenchmarkSummary{
			ByModel: make(map[string]ModelSummary),
			ByTask:  make(map[string]TaskSummary),
		},
	}

	taskSet := make(map[string]bool)
	modelSet := make(map[string]bool)

	for _, r := range results {
		taskSet[r.TaskName] = true
		modelSet[r.ModelName] = true

		if agg.ByTaskModel[r.TaskName] == nil {
			agg.ByTaskModel[r.TaskName] = make(map[string][]TaskResult)
		}
		agg.ByTaskModel[r.TaskName][r.ModelName] = append(agg.ByTaskModel[r.TaskName][r.ModelName], r)

		// Update summary
		agg.Summary.TotalRuns++
		if r.Passed {
			agg.Summary.TotalPassed++
		} else {
			agg.Summary.TotalFailed++
		}
		agg.Summary.TotalCost += r.CostUSD
		agg.Summary.TotalDuration += r.Duration

		// Update model summary
		ms := agg.Summary.ByModel[r.ModelName]
		ms.Model = r.ModelName
		ms.Runs++
		if r.Passed {
			ms.Passed++
		} else {
			ms.Failed++
		}
		ms.TotalCost += r.CostUSD
		ms.AvgDuration += r.Duration
		agg.Summary.ByModel[r.ModelName] = ms

		// Update task summary
		ts := agg.Summary.ByTask[r.TaskName]
		ts.Task = r.TaskName
		ts.Runs++
		if r.Passed {
			ts.Passed++
		} else {
			ts.Failed++
		}
		ts.TotalCost += r.CostUSD
		agg.Summary.ByTask[r.TaskName] = ts
	}

	// Convert sets to sorted slices
	for t := range taskSet {
		agg.Tasks = append(agg.Tasks, t)
	}
	sort.Strings(agg.Tasks)

	for m := range modelSet {
		agg.Models = append(agg.Models, m)
	}
	sort.Strings(agg.Models)

	// Calculate averages and rates
	for name, ms := range agg.Summary.ByModel {
		if ms.Runs > 0 {
			ms.PassRate = float64(ms.Passed) / float64(ms.Runs) * 100
			ms.AvgCost = ms.TotalCost / float64(ms.Runs)
			ms.AvgDuration = ms.AvgDuration / time.Duration(ms.Runs)
		}
		agg.Summary.ByModel[name] = ms
	}

	for name, ts := range agg.Summary.ByTask {
		if ts.Runs > 0 {
			ts.PassRate = float64(ts.Passed) / float64(ts.Runs) * 100
		}
		// Find best model for this task
		bestRate := -1.0
		for model, results := range agg.ByTaskModel[name] {
			passed := 0
			for _, r := range results {
				if r.Passed {
					passed++
				}
			}
			rate := float64(passed) / float64(len(results))
			if rate > bestRate {
				bestRate = rate
				ts.BestModel = model
			}
		}
		agg.Summary.ByTask[name] = ts
	}

	return agg
}