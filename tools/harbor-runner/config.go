package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Model represents an LLM model configuration
type Model struct {
	Name        string  `yaml:"name"`
	DisplayName string  `yaml:"display_name,omitempty"`
	Provider    string  `yaml:"provider,omitempty"` // anthropic, openrouter, openai
	CostPer1KInput  float64 `yaml:"cost_per_1k_input,omitempty"`
	CostPer1KOutput float64 `yaml:"cost_per_1k_output,omitempty"`
}

// Config holds the benchmark configuration
type Config struct {
	DatasetPath  string   `yaml:"dataset_path"`
	JobsDir      string   `yaml:"jobs_dir"`
	Agent        string   `yaml:"agent"`
	Parallel     int      `yaml:"parallel"`
	Attempts     int      `yaml:"attempts"`
	OutputDir    string   `yaml:"output_dir"`
	ForceBuild   bool     `yaml:"force_build"`
	TaskPatterns []string `yaml:"task_patterns"`
	Models       []Model  `yaml:"models"`
}

// DefaultModels returns a default set of models from simple to sophisticated
func DefaultModels() []Model {
	return []Model{
		{
			Name:        "claude-haiku-4-5-20251001",
			DisplayName: "Claude Haiku 4.5",
			Provider:    "anthropic",
		},
		{
			Name:        "claude-sonnet-4-5-20250929",
			DisplayName: "Claude Sonnet 4.5",
			Provider:    "anthropic",
		},
		{
			Name:        "claude-opus-4-5-20251101",
			DisplayName: "Claude Opus 4.5",
			Provider:    "anthropic",
		},
	}
}

// LoadConfig loads configuration from a YAML file
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config file: %w", err)
	}

	return cfg, nil
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if c.DatasetPath == "" {
		return fmt.Errorf("dataset_path is required")
	}
	if _, err := os.Stat(c.DatasetPath); os.IsNotExist(err) {
		return fmt.Errorf("dataset path does not exist: %s", c.DatasetPath)
	}
	if len(c.Models) == 0 {
		return fmt.Errorf("at least one model is required")
	}
	if c.Parallel < 1 {
		c.Parallel = 1
	}
	if c.Attempts < 1 {
		c.Attempts = 1
	}
	return nil
}

// DiscoverTasks finds all tasks matching the given patterns
func DiscoverTasks(datasetPath string, patterns []string) ([]string, error) {
	var tasks []string
	seen := make(map[string]bool)

	entries, err := os.ReadDir(datasetPath)
	if err != nil {
		return nil, fmt.Errorf("reading dataset directory: %w", err)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		taskPath := filepath.Join(datasetPath, entry.Name())

		// Check if it's a valid task (has instruction.md or task.toml)
		if !isValidTask(taskPath) {
			continue
		}

		// Match against patterns
		for _, pattern := range patterns {
			matched, err := filepath.Match(pattern, entry.Name())
			if err != nil {
				return nil, fmt.Errorf("invalid pattern %q: %w", pattern, err)
			}
			if matched && !seen[taskPath] {
				tasks = append(tasks, taskPath)
				seen[taskPath] = true
				break
			}
		}
	}

	return tasks, nil
}

func isValidTask(path string) bool {
	// Check for instruction.md
	if _, err := os.Stat(filepath.Join(path, "instruction.md")); err == nil {
		return true
	}
	// Check for task.toml
	if _, err := os.Stat(filepath.Join(path, "task.toml")); err == nil {
		return true
	}
	return false
}

// BuildHarborCommand constructs the harbor run command for a single task (legacy)
func BuildHarborCommand(taskPath string, model Model, cfg *Config) []string {
	args := []string{
		"run",
		"-p", taskPath,
		"--agent", cfg.Agent,
		"--model", model.Name,
		"--no-delete",
	}

	if cfg.ForceBuild {
		args = append(args, "--force-build")
	}

	return args
}

// BuildHarborBatchCommand constructs harbor run command for multiple tasks
// Uses harbor's native concurrency with -t flags for tasks and -n for parallelism
func BuildHarborBatchCommand(datasetPath string, taskNames []string, model Model, cfg *Config) []string {
	args := []string{
		"run",
		"-p", datasetPath,
		"--agent", cfg.Agent,
		"--model", model.Name,
		"--no-delete",
		"-n", fmt.Sprintf("%d", cfg.Parallel),
	}

	// Add each task with -t flag
	for _, taskName := range taskNames {
		args = append(args, "-t", taskName)
	}

	// Add attempts with -k flag
	if cfg.Attempts > 1 {
		args = append(args, "-k", fmt.Sprintf("%d", cfg.Attempts))
	}

	if cfg.ForceBuild {
		args = append(args, "--force-build")
	}

	return args
}

// GetModelDisplayName returns a display name for a model
func (m Model) GetDisplayName() string {
	if m.DisplayName != "" {
		return m.DisplayName
	}
	// Generate from name
	name := m.Name
	name = strings.ReplaceAll(name, "claude-", "Claude ")
	name = strings.ReplaceAll(name, "gpt-", "GPT-")
	name = strings.ReplaceAll(name, "-", " ")
	return name
}

// ExampleConfig returns an example configuration YAML
func ExampleConfig() string {
	return `# Harbor Benchmark Runner Configuration
#
# Dataset and output settings
dataset_path: datasets/opentelemetry
jobs_dir: jobs
output_dir: benchmark-results

# Execution settings
agent: terminus-2
parallel: 2
attempts: 1
force_build: false

# Task patterns to match (glob patterns)
task_patterns:
  - "go-otel-*"
  - "cpp-otel-simple"
  - "java-otel-simple"

# Models to benchmark (from simple to sophisticated)
models:
  # Fast and cheap - good for simple tasks
  - name: claude-haiku-4-5-20251001
    display_name: Claude Haiku 4.5
    provider: anthropic

  # Balanced performance
  - name: claude-sonnet-4-5-20250929
    display_name: Claude Sonnet 4.5
    provider: anthropic

  # Most capable
  - name: claude-opus-4-5-20251101
    display_name: Claude Opus 4.5
    provider: anthropic

  # OpenRouter example (uncomment to use)
  # - name: openrouter/anthropic/claude-3.5-sonnet
  #   display_name: Claude 3.5 Sonnet (OpenRouter)
  #   provider: openrouter
`
}