package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	// CLI flags
	configFile := flag.String("config", "", "Path to YAML config file")
	tasksFlag := flag.String("tasks", "", "Comma-separated task patterns (e.g., 'go-otel-*,cpp-otel-simple')")
	modelsFlag := flag.String("models", "", "Comma-separated models (e.g., 'claude-haiku-4-5-20251001,claude-sonnet-4-5-20250929')")
	datasetPath := flag.String("dataset", "datasets/opentelemetry", "Path to dataset directory")
	jobsDir := flag.String("jobs-dir", "jobs", "Directory for job outputs")
	agent := flag.String("agent", "terminus-2", "Agent to use")
	parallel := flag.Int("parallel", 4, "Harbor's internal concurrency (-n flag)")
	attempts := flag.Int("attempts", 1, "Number of attempts per task/model combination")
	outputDir := flag.String("output", "benchmark-results", "Output directory for dashboard")
	dryRun := flag.Bool("dry-run", false, "Print commands without executing")
	forceBuild := flag.Bool("force-build", false, "Force rebuild docker images")
	analyzeOnly := flag.String("analyze", "", "Only analyze existing jobs directory (skip running)")
	mergeResults := flag.String("merge", "", "Merge new results with existing results.json file")
	fromJobs := flag.String("from-jobs", "", "Generate dashboard from multiple job directories (comma-separated)")
	errorDashboard := flag.Bool("error-dashboard", false, "Generate error analysis dashboard (errors.html)")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Harbor Benchmark Runner

A tool to run OpenTelemetry benchmark tasks across multiple models and generate comparison dashboards.

Usage:
  %s [flags]

Examples:
  # Run with config file
  %s -config benchmark.yaml

  # Run specific tasks with specific models
  %s -tasks "go-otel-*" -models "claude-haiku-4-5-20251001,claude-sonnet-4-5-20250929"

  # Analyze existing results only
  %s -analyze jobs/2025-12-18__11-32-00

  # Run new models and merge with existing results
  %s -config benchmark.yaml -merge benchmark-results/results.json

  # Dry run to see what would be executed
  %s -tasks "go-otel-simple" -models "claude-haiku-4-5-20251001" -dry-run

  # Generate dashboard from a directory containing job subdirectories
  %s -from-jobs ./benchmark-jobs

  # Or from comma-separated list of job directories
  %s -from-jobs "jobs/2025-12-23__15-36-53,jobs/2025-12-24__13-38-44"

Flags:
`, os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0])
		flag.PrintDefaults()
	}

	flag.Parse()

	// Load configuration
	cfg := &Config{
		DatasetPath: *datasetPath,
		JobsDir:     *jobsDir,
		Agent:       *agent,
		Parallel:    *parallel,
		Attempts:    *attempts,
		OutputDir:   *outputDir,
		ForceBuild:  *forceBuild,
	}

	// Load from config file if provided
	if *configFile != "" {
		fileCfg, err := LoadConfig(*configFile)
		if err != nil {
			log.Fatalf("Failed to load config: %v", err)
		}
		cfg = mergeConfigs(cfg, fileCfg)
	}

	// Override with CLI flags (these take precedence over config file)
	if *tasksFlag != "" {
		cfg.TaskPatterns = strings.Split(*tasksFlag, ",")
	}
	if *modelsFlag != "" {
		cfg.Models = parseModels(*modelsFlag)
	}
	// Check if parallel flag was explicitly set (not just default)
	parallelSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "parallel" {
			parallelSet = true
		}
	})
	if parallelSet {
		cfg.Parallel = *parallel
	}
	// Same for attempts
	attemptsSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "attempts" {
			attemptsSet = true
		}
	})
	if attemptsSet {
		cfg.Attempts = *attempts
	}
	// Same for force-build
	forceBuildSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "force-build" {
			forceBuildSet = true
		}
	})
	if forceBuildSet {
		cfg.ForceBuild = *forceBuild
	}

	// Set defaults if not specified
	if len(cfg.Models) == 0 {
		cfg.Models = DefaultModels()
	}
	if len(cfg.TaskPatterns) == 0 {
		cfg.TaskPatterns = []string{"*"}
	}

	// Analyze only mode
	if *analyzeOnly != "" {
		log.Printf("Analyzing existing jobs in: %s", *analyzeOnly)
		results, err := ParseJobsDirectory(*analyzeOnly)
		if err != nil {
			log.Fatalf("Failed to parse jobs: %v", err)
		}
		if err := GenerateDashboard(results, cfg.OutputDir); err != nil {
			log.Fatalf("Failed to generate dashboard: %v", err)
		}
		log.Printf("Dashboard generated at: %s/index.html", cfg.OutputDir)
		if *errorDashboard {
			if err := GenerateErrorDashboard(results, cfg.OutputDir); err != nil {
				log.Fatalf("Failed to generate error dashboard: %v", err)
			}
			log.Printf("Error dashboard generated at: %s/errors.html", cfg.OutputDir)
		}
		return
	}

	// Generate from multiple jobs directories mode
	if *fromJobs != "" {
		var jobDirs []string

		// Check if it's a single directory containing job subdirectories
		if !strings.Contains(*fromJobs, ",") {
			// Single path - check if it contains job subdirectories (DATE__TIME format)
			entries, err := os.ReadDir(*fromJobs)
			if err != nil {
				log.Fatalf("Failed to read directory %s: %v", *fromJobs, err)
			}

			for _, entry := range entries {
				if entry.IsDir() {
					// Check if directory name matches job format (YYYY-MM-DD__HH-MM-SS)
					name := entry.Name()
					if len(name) >= 19 && name[4] == '-' && name[7] == '-' && name[10] == '_' && name[11] == '_' {
						jobDirs = append(jobDirs, filepath.Join(*fromJobs, name))
					}
				}
			}

			if len(jobDirs) == 0 {
				// No subdirectories found, treat as single job directory
				jobDirs = []string{*fromJobs}
			} else {
				log.Printf("Found %d job directories in %s", len(jobDirs), *fromJobs)
			}
		} else {
			// Comma-separated list
			for _, dir := range strings.Split(*fromJobs, ",") {
				dir = strings.TrimSpace(dir)
				if dir != "" {
					jobDirs = append(jobDirs, dir)
				}
			}
		}

		var allResults []TaskResult

		for _, jobDir := range jobDirs {
			log.Printf("Parsing jobs from: %s", jobDir)
			results, err := ParseJobsDirectory(jobDir)
			if err != nil {
				log.Printf("Warning: Failed to parse %s: %v", jobDir, err)
				continue
			}
			log.Printf("  Found %d results", len(results))
			allResults = append(allResults, results...)
		}

		if len(allResults) == 0 {
			log.Fatalf("No results found in any of the specified job directories")
		}

		log.Printf("Total results collected: %d", len(allResults))

		if err := GenerateDashboard(allResults, cfg.OutputDir); err != nil {
			log.Fatalf("Failed to generate dashboard: %v", err)
		}

		log.Printf("Dashboard generated at: %s/index.html", cfg.OutputDir)
		log.Printf("Results: %d passed, %d failed", countPassed(allResults), countFailed(allResults))
		if *errorDashboard {
			if err := GenerateErrorDashboard(allResults, cfg.OutputDir); err != nil {
				log.Fatalf("Failed to generate error dashboard: %v", err)
			}
			log.Printf("Error dashboard generated at: %s/errors.html", cfg.OutputDir)
		}
		return
	}

	// Validate configuration
	if err := cfg.Validate(); err != nil {
		log.Fatalf("Invalid configuration: %v", err)
	}

	// Discover tasks
	tasks, err := DiscoverTasks(cfg.DatasetPath, cfg.TaskPatterns)
	if err != nil {
		log.Fatalf("Failed to discover tasks: %v", err)
	}

	if len(tasks) == 0 {
		log.Fatalf("No tasks found matching patterns: %v", cfg.TaskPatterns)
	}

	log.Printf("Found %d tasks to run", len(tasks))
	log.Printf("Models: %v", modelNames(cfg.Models))
	log.Printf("Attempts per combination: %d", cfg.Attempts)
	log.Printf("Total runs: %d", len(tasks)*len(cfg.Models)*cfg.Attempts)

	if *dryRun {
		fmt.Println("\n=== DRY RUN - Commands that would be executed ===\n")
		fmt.Println("Note: Uses Harbor's native concurrency. One command per model with all tasks.")
		fmt.Println()

		// Extract task names from full paths
		taskNames := make([]string, len(tasks))
		for i, task := range tasks {
			taskNames[i] = filepath.Base(task)
		}

		for _, model := range cfg.Models {
			cmd := BuildHarborBatchCommand(cfg.DatasetPath, taskNames, model, cfg)
			fmt.Printf("harbor %s\n\n", strings.Join(cmd, " "))
		}
		return
	}

	// Create job directory for this benchmark run
	timestamp := time.Now().Format("2006-01-02__15-04-05")
	runJobsDir := filepath.Join(cfg.JobsDir, timestamp)

	// Run benchmark
	runner := NewRunner(cfg, runJobsDir)
	results, err := runner.Run(tasks)
	if err != nil {
		log.Printf("Warning: Some tasks failed: %v", err)
	}

	// Merge with existing results if requested
	if *mergeResults != "" {
		existingResults, err := loadResultsJSON(*mergeResults)
		if err != nil {
			log.Printf("Warning: Could not load existing results from %s: %v", *mergeResults, err)
		} else {
			log.Printf("Merging %d new results with %d existing results", len(results), len(existingResults))
			results = append(existingResults, results...)
		}
	}

	// Generate dashboard
	if err := GenerateDashboard(results, cfg.OutputDir); err != nil {
		log.Fatalf("Failed to generate dashboard: %v", err)
	}

	log.Printf("Benchmark complete!")
	log.Printf("Results: %d passed, %d failed", countPassed(results), countFailed(results))
	log.Printf("Dashboard: %s/index.html", cfg.OutputDir)

	if *errorDashboard {
		if err := GenerateErrorDashboard(results, cfg.OutputDir); err != nil {
			log.Fatalf("Failed to generate error dashboard: %v", err)
		}
		log.Printf("Error dashboard generated at: %s/errors.html", cfg.OutputDir)
	}
}

func parseModels(s string) []Model {
	parts := strings.Split(s, ",")
	models := make([]Model, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			models = append(models, Model{Name: p})
		}
	}
	return models
}

func modelNames(models []Model) []string {
	names := make([]string, len(models))
	for i, m := range models {
		names[i] = m.Name
	}
	return names
}

func countPassed(results []TaskResult) int {
	count := 0
	for _, r := range results {
		if r.Passed {
			count++
		}
	}
	return count
}

func countFailed(results []TaskResult) int {
	count := 0
	for _, r := range results {
		if !r.Passed {
			count++
		}
	}
	return count
}

func mergeConfigs(base, override *Config) *Config {
	if override.DatasetPath != "" {
		base.DatasetPath = override.DatasetPath
	}
	if override.JobsDir != "" {
		base.JobsDir = override.JobsDir
	}
	if override.Agent != "" {
		base.Agent = override.Agent
	}
	if override.Parallel > 0 {
		base.Parallel = override.Parallel
	}
	if override.Attempts > 0 {
		base.Attempts = override.Attempts
	}
	if override.OutputDir != "" {
		base.OutputDir = override.OutputDir
	}
	if len(override.TaskPatterns) > 0 {
		base.TaskPatterns = override.TaskPatterns
	}
	if len(override.Models) > 0 {
		base.Models = override.Models
	}
	base.ForceBuild = base.ForceBuild || override.ForceBuild
	return base
}

// loadResultsJSON loads existing results from a JSON file
func loadResultsJSON(path string) ([]TaskResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading results file: %w", err)
	}

	var results []TaskResult
	if err := json.Unmarshal(data, &results); err != nil {
		return nil, fmt.Errorf("parsing results JSON: %w", err)
	}

	return results, nil
}