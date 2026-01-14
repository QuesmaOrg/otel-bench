# Harbor OpenTelemetry Benchmark

A benchmark suite for evaluating AI models on OpenTelemetry instrumentation tasks across multiple programming languages. Built on the [Harbor framework](https://harborframework.com).

## Overview

This repository contains:
- **OpenTelemetry Dataset**: A comprehensive set of tasks testing AI models' ability to instrument applications with OpenTelemetry across 11+ programming languages
- **Benchmark Runner**: A tool to run benchmarks across multiple models and generate comparison dashboards

## Quick Start

### Prerequisites

- [Harbor](https://harborframework.com) installed (`uv tool install harbor`)
- `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` environment variable set

### Run a single task

```bash
harbor run -p "datasets/opentelemetry/go-otel-simple" --agent terminus-2 --model claude-sonnet-4-5-20250929
```

### Run benchmarks across multiple models

```bash
cd tools/harbor-runner
go build -o harbor-runner .
./harbor-runner -tasks "go-otel-*" -models "openrouter/anthropic/claude-sonnet-4.5,openrouter/openai/gpt-5.2"
```

## Dataset

The OpenTelemetry dataset (`datasets/opentelemetry/`) contains tasks for:

| Language | Tasks |
|----------|-------|
| C++ | simple, advanced, distributed-context-propagation |
| Go | simple, http-tracing, distributed-context-propagation, workflow-tracing, microservices, grpc-fix |
| Java | simple, advanced, distributed-context-propagation, microservices |
| JavaScript | microservices |
| .NET | microservices |
| PHP | distributed-context-propagation, microservices |
| Python | distributed-context-propagation, microservices |
| Ruby | microservices |
| Rust | distributed-context-propagation, microservices |
| Erlang | microservices |
| Swift | microservices |

## Documentation

- **[Harbor Playground Guide](HARBOR.md)** - How to work with the Harbor framework, run tasks, and use the UI
- **[Benchmark Runner](tools/harbor-runner/Readme.md)** - Detailed documentation for the benchmark runner tool including configuration, CLI options, and dashboard generation

## Output

The benchmark runner generates HTML dashboards showing:
- Pass rates per model
- Model rankings
- Task-by-model matrix
- Error analysis (optional)

## License

See [LICENSE](LICENSE) for details.