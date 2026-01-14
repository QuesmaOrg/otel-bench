# Harbor Benchmark Runner

A tool to run benchmark tasks across multiple AI models and generate comparison dashboards. It wraps [Harbor](https://github.com/harbor-ai/harbor) to provide batch execution, result aggregation, and HTML dashboard generation.

> **Note:** Examples in this document use the OpenTelemetry instrumentation dataset, but the tool works with any Harbor-compatible task dataset.

## Prerequisites

- Go 1.21+
- [Harbor](https://github.com/harbor-ai/harbor) installed and configured
- `OPENROUTER_API_KEY` environment variable set (for OpenRouter models)

## Installation

```bash
cd tools/harbor-runner
go build -o harbor-runner .
```

## Quick Start

```bash
# Run all tasks with default models
./harbor-runner -config benchmark.yaml

# Run specific tasks with specific models
./harbor-runner -tasks "go-otel-simple" -models "openrouter/anthropic/claude-sonnet-4.5"

# Generate dashboard from existing job results
./harbor-runner -from-jobs ./benchmark-jobs -error-dashboard
```

## Command Line Options

| Flag | Default | Description |
|------|---------|-------------|
| `-config` | | Path to YAML configuration file |
| `-tasks` | `*` | Comma-separated task patterns (glob supported) |
| `-models` | | Comma-separated model names |
| `-dataset` | `datasets/opentelemetry` | Path to dataset directory |
| `-jobs-dir` | `jobs` | Directory for job outputs |
| `-output` | `benchmark-results` | Output directory for dashboard |
| `-agent` | `terminus-2` | Harbor agent to use |
| `-parallel` | `4` | Harbor's internal concurrency |
| `-attempts` | `1` | Number of attempts per task/model |
| `-dry-run` | `false` | Print commands without executing |
| `-force-build` | `false` | Force rebuild Docker images |
| `-analyze` | | Analyze existing jobs directory only |
| `-from-jobs` | | Generate dashboard from job directories |
| `-merge` | | Merge with existing results.json |
| `-error-dashboard` | `false` | Generate error analysis dashboard |

## Usage Examples

### Running Benchmarks

**Run all tasks from config file:**
```bash
./harbor-runner -config benchmark.yaml
```

**Run specific Go tasks:**
```bash
./harbor-runner -tasks "go-otel-*" -models "openrouter/anthropic/claude-sonnet-4.5"
```

**Run a single task with multiple models:**
```bash
./harbor-runner \
  -tasks "go-otel-distributed-context-propagation" \
  -models "openrouter/anthropic/claude-sonnet-4.5,openrouter/openai/gpt-5.2"
```

**Run all simple tasks:**
```bash
./harbor-runner -tasks "cpp-otel-simple,java-otel-simple,go-otel-http-tracing"
```

**Run with multiple attempts per task/model:**
```bash
./harbor-runner -config benchmark.yaml -attempts 3
```

**Dry run to preview commands:**
```bash
./harbor-runner \
  -tasks "go-otel-simple" \
  -models "openrouter/anthropic/claude-haiku-4.5" \
  -dry-run
```

### Generating Dashboards

**Generate dashboard from a directory of job runs:**
```bash
./harbor-runner -from-jobs ./benchmark-jobs -output ./results
```

**Generate dashboard with error analysis:**
```bash
./harbor-runner -from-jobs ./benchmark-jobs -error-dashboard -output ./results
```

**Generate from specific job directories:**
```bash
./harbor-runner -from-jobs "jobs/2025-12-23__15-36-53,jobs/2025-12-24__13-38-44"
```

**Analyze a single job run:**
```bash
./harbor-runner -analyze jobs/2025-12-23__15-36-53 -output ./results
```

### Incremental Benchmarking

**Run new models and merge with existing results:**
```bash
./harbor-runner \
  -tasks "go-otel-*" \
  -models "openrouter/openai/gpt-5.2" \
  -merge benchmark-results/results.json
```

## Configuration File

Create a `benchmark.yaml` file for reproducible benchmark runs:

```yaml
# Dataset and output settings
dataset_path: datasets/opentelemetry
jobs_dir: jobs
output_dir: benchmark-results

# Execution settings
agent: terminus-2
parallel: 12
attempts: 1
force_build: false

# Task patterns (glob supported)
task_patterns:
  - "go-otel-simple"
  - "go-otel-distributed-context-propagation"
  - "java-otel-*"
  - "cpp-otel-simple"

# Models to benchmark
models:
  - name: openrouter/anthropic/claude-sonnet-4.5
    display_name: Claude Sonnet 4.5
    provider: openrouter

  - name: openrouter/openai/gpt-5.2
    display_name: GPT-5.2
    provider: openrouter

  - name: openrouter/google/gemini-3-pro-preview
    display_name: Gemini 3 Pro
    provider: openrouter
```

## Task Patterns

Tasks follow the naming convention `<language>-otel-<description>`. Use glob patterns to select tasks:

| Pattern | Matches |
|---------|---------|
| `*` | All tasks |
| `go-otel-*` | All Go tasks |
| `*-simple` | All simple tasks (cpp-otel-simple, java-otel-simple) |
| `*-microservices` | All microservices tasks |
| `*-distributed-context-propagation` | All distributed context propagation tasks |

**Available OpenTelemetry tasks by language:**

- **C++**: `cpp-otel-simple`, `cpp-otel-advanced`, `cpp-otel-distributed-context-propagation`
- **Go**: `go-otel-simple`, `go-otel-http-tracing`, `go-otel-distributed-context-propagation`, `go-otel-workflow-tracing`, `go-otel-microservices`, `go-otel-microservices-logs`, `go-otel-microservices-traces`, `go-otel-microservices-traces-simple`, `go-otel-grpc-fix`
- **Java**: `java-otel-simple`, `java-otel-advanced`, `java-otel-distributed-context-propagation`, `java-otel-microservices`
- **JavaScript**: `js-otel-microservices`
- **.NET**: `net-otel-microservices`
- **PHP**: `php-otel-distributed-context-propagation`, `php-otel-microservices`
- **Python**: `python-otel-distributed-context-propagation`, `python-otel-microservices`
- **Ruby**: `ruby-otel-microservices`
- **Rust**: `rust-otel-distributed-context-propagation`, `rust-otel-microservices`
- **Erlang**: `erlang-otel-microservices`
- **Swift**: `swift-otel-microservices`

## Output

The runner generates:

| File | Description |
|------|-------------|
| `index.html` | Main benchmark dashboard with pass rates, rankings, and task matrix |
| `errors.html` | Error analysis dashboard (with `-error-dashboard` flag) |
| `results.json` | Raw results data |
| `summary.json` | Aggregated statistics |
| `errors.json` | Error analysis data |

## Directory Structure

```
harbor-experiments/
├── datasets/opentelemetry/      # Task definitions
│   ├── go-otel-simple/
│   ├── java-otel-advanced/
│   └── ...
├── jobs/                        # Raw Harbor job outputs
│   └── 2025-12-23__15-36-53/
│       ├── go-otel-simple__abc123/
│       └── java-otel-simple__def456/
├── benchmark-results/           # Generated dashboards
│   ├── index.html
│   ├── errors.html
│   └── results.json
└── tools/harbor-runner/         # This tool
```

## Examples by Use Case

### Quick test with a single easy task
```bash
./harbor-runner \
  -tasks "go-otel-http-tracing" \
  -models "openrouter/anthropic/claude-haiku-4.5" \
  -output ./quick-test
```

### Full benchmark of all Go tasks
```bash
./harbor-runner \
  -tasks "go-otel-*" \
  -models "openrouter/anthropic/claude-sonnet-4.5,openrouter/openai/gpt-5.2,openrouter/google/gemini-3-pro-preview" \
  -parallel 8 \
  -output ./go-benchmark
```

### Compare models on hard tasks only
```bash
./harbor-runner \
  -tasks "cpp-otel-advanced,java-otel-advanced,go-otel-grpc-fix,swift-otel-microservices" \
  -config benchmark.yaml \
  -output ./hard-tasks-results
```

### Regenerate dashboard after manual inspection
```bash
./harbor-runner \
  -from-jobs ./benchmark-jobs \
  -error-dashboard \
  -output ./benchmark-results
```