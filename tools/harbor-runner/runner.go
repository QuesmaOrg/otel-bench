package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// TaskResult holds the result of a task execution
type TaskResult struct {
	TaskName     string
	TaskPath     string
	ModelName    string
	ModelDisplay string
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
	TrialDir     string
}

// Runner executes benchmark tasks
type Runner struct {
	cfg *Config
}

// NewRunner creates a new benchmark runner
func NewRunner(cfg *Config, jobsDir string) *Runner {
	return &Runner{
		cfg: cfg,
	}
}

// Run executes all tasks using Harbor's native concurrency
// For each model, runs one harbor command with all tasks using -t flags
// Models are run sequentially to avoid resource contention
func (r *Runner) Run(tasks []string) ([]TaskResult, error) {
	// Extract task names from full paths
	taskNames := make([]string, len(tasks))
	for i, task := range tasks {
		taskNames[i] = filepath.Base(task)
	}

	totalRuns := len(tasks) * len(r.cfg.Models) * r.cfg.Attempts
	log.Printf("Starting benchmark: %d tasks x %d models x %d attempts = %d total runs",
		len(tasks), len(r.cfg.Models), r.cfg.Attempts, totalRuns)
	log.Printf("Using Harbor's native concurrency with -n %d", r.cfg.Parallel)

	var allResults []TaskResult

	// Run each model sequentially (harbor handles task parallelism internally)
	for modelIdx, model := range r.cfg.Models {
		log.Printf("\n=== Model %d/%d: %s ===", modelIdx+1, len(r.cfg.Models), model.GetDisplayName())

		results, err := r.runModelBatch(model, taskNames)
		if err != nil {
			log.Printf("Warning: Error running model %s: %v", model.Name, err)
		}

		allResults = append(allResults, results...)

		// Log progress
		passed := 0
		for _, res := range results {
			if res.Passed {
				passed++
			}
		}
		log.Printf("Model %s completed: %d/%d passed", model.GetDisplayName(), passed, len(results))
	}

	return allResults, nil
}

// runModelBatch runs all tasks for a single model using harbor's batch mode
func (r *Runner) runModelBatch(model Model, taskNames []string) ([]TaskResult, error) {
	// Build the harbor command with all tasks
	args := BuildHarborBatchCommand(r.cfg.DatasetPath, taskNames, model, r.cfg)

	log.Printf("Executing: harbor %s", strings.Join(args, " "))

	startTime := time.Now()

	// Execute harbor command
	cmd := exec.Command("harbor", args...)
	cmd.Env = os.Environ()

	output, err := cmd.CombinedOutput()
	duration := time.Since(startTime)

	log.Printf("Harbor finished in %v, output length: %d bytes", duration, len(output))

	if err != nil {
		log.Printf("Harbor command returned error: %v", err)
		// Continue to parse results even if harbor returns non-zero exit
	}

	// Parse the output to find the jobs directory
	jobsDir := findJobsDirFromOutput(string(output))
	if jobsDir == "" {
		// Try to find the most recent jobs directory
		jobsDir = findLatestJobsDir(r.cfg.JobsDir)
	}

	if jobsDir == "" {
		log.Printf("Could not find jobs directory. Harbor output:\n%s", truncate(string(output), 2000))
		return nil, fmt.Errorf("could not find jobs directory")
	}

	log.Printf("Parsing results from: %s", jobsDir)

	// Parse all results from the jobs directory
	results, err := r.parseJobsResults(jobsDir, model)
	if err != nil {
		return nil, fmt.Errorf("parsing results: %w", err)
	}

	return results, nil
}

// parseJobsResults parses all result.json files from a jobs directory
func (r *Runner) parseJobsResults(jobsDir string, model Model) ([]TaskResult, error) {
	var results []TaskResult

	// List all trial directories in the jobs directory
	entries, err := os.ReadDir(jobsDir)
	if err != nil {
		return nil, fmt.Errorf("reading jobs directory: %w", err)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		trialDir := filepath.Join(jobsDir, entry.Name())
		resultFile := filepath.Join(trialDir, "result.json")

		// Check if result.json exists
		if _, err := os.Stat(resultFile); os.IsNotExist(err) {
			continue
		}

		// Parse the result file
		parsed, err := ParseResultFile(resultFile)
		if err != nil {
			log.Printf("Warning: Failed to parse %s: %v", resultFile, err)
			continue
		}

		// Extract task name from trial name (format: taskname__hash)
		taskName := extractTaskName(entry.Name())

		result := TaskResult{
			TaskName:     taskName,
			TaskPath:     filepath.Join(r.cfg.DatasetPath, taskName),
			ModelName:    model.Name,
			ModelDisplay: model.GetDisplayName(),
			Attempt:      parsed.Attempt,
			Passed:       parsed.Passed,
			Reward:       parsed.Reward,
			CostUSD:      parsed.CostUSD,
			InputTokens:  parsed.InputTokens,
			OutputTokens: parsed.OutputTokens,
			CacheTokens:  parsed.CacheTokens,
			Turns:        parsed.Turns,
			Duration:     parsed.Duration,
			StartedAt:    parsed.StartedAt,
			FinishedAt:   parsed.FinishedAt,
			Error:        parsed.Error,
			TrialDir:     trialDir,
		}

		results = append(results, result)

		status := "PASS"
		if !result.Passed {
			status = "FAIL"
		}
		log.Printf("  %s %s - $%.4f, %d tokens", status, taskName, result.CostUSD, result.InputTokens+result.OutputTokens)
	}

	return results, nil
}

// extractTaskName extracts the task name from a trial directory name
// Trial names have format: taskname__hash (e.g., "cpp-otel-simple__VekPgQC")
func extractTaskName(trialName string) string {
	// Find the last occurrence of "__" and take everything before it
	if idx := strings.LastIndex(trialName, "__"); idx > 0 {
		return trialName[:idx]
	}
	return trialName
}

// findJobsDirFromOutput extracts the jobs directory from harbor output
func findJobsDirFromOutput(output string) string {
	// Look for patterns like "Trial: file:///path/to/jobs/DATE__TIME/trial__hash"
	// or "trials_dir: jobs/DATE__TIME"
	lines := strings.Split(output, "\n")

	// Pattern for jobs directory (e.g., jobs/2025-12-22__15-30-00)
	jobsDirPattern := regexp.MustCompile(`jobs/\d{4}-\d{2}-\d{2}__\d{2}-\d{2}-\d{2}`)

	for _, line := range lines {
		if matches := jobsDirPattern.FindString(line); matches != "" {
			// Verify it exists
			if info, err := os.Stat(matches); err == nil && info.IsDir() {
				return matches
			}
		}

		// Also check for file:// URIs
		if strings.Contains(line, "Trial:") || strings.Contains(line, "trial_uri") {
			if idx := strings.Index(line, "file://"); idx >= 0 {
				path := line[idx+7:]
				path = strings.TrimSpace(path)
				path = strings.Trim(path, "\"',")

				// Extract the jobs/DATE__TIME part
				if matches := jobsDirPattern.FindString(path); matches != "" {
					if info, err := os.Stat(matches); err == nil && info.IsDir() {
						return matches
					}
				}
			}
		}
	}

	return ""
}

// findLatestJobsDir finds the most recent jobs directory
func findLatestJobsDir(baseJobsDir string) string {
	entries, err := os.ReadDir(baseJobsDir)
	if err != nil {
		return ""
	}

	var latestDir string
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() > latestDir {
			// Check if it looks like a jobs directory (DATE__TIME format)
			if matched, _ := regexp.MatchString(`^\d{4}-\d{2}-\d{2}__\d{2}-\d{2}-\d{2}$`, entry.Name()); matched {
				latestDir = entry.Name()
			}
		}
	}

	if latestDir != "" {
		return filepath.Join(baseJobsDir, latestDir)
	}
	return ""
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}