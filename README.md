# OpenTelemetry Benchmark (OTelBench) by Quesma

An open-source benchmark for evaluating AI models on OpenTelemetry instrumentation tasks across multiple programming languages.

* Benchmark: [OTelBench results](https://quesma.com/benchmarks/otel/)
* Blog post: [Benchmarking OpenTelemetry: Can AI trace your failed login?](https://quesma.com/blog/introducing-otel-bench/)

## Quick start

Requires [Harbor](https://harborframework.com) (`uv tool install harbor`), Docker, and relevant API KEYs.

By default, we use the `terminus-2` agent (default for Harbor) via [OpenRouter](https://openrouter.ai/) to compare models.
You are free to use others, including well-known CLI AI Agents like Claude Code, Codex, or Cursor CLI.

You need to clone this repo:

```bash
git clone git@github.com:QuesmaOrg/otel-bench.git
cd otel-bench
```

Run a single task, for a single model:

```bash
export ANTHROPIC_API_KEY=...
harbor run \ 
  --path datasets/otel \ 
  --task-name cpp-simple \ 
  --agent claude-code \  # only for Claude models
  --model anthropic/claude-opus-4-5-20251101
```

Task names allow wildcards, so if you want to run all Go tasks in Cursor CLI, it works like:

```bash
export OPENAI_API_KEY=...
harbor run \ 
  --path datasets/otel \ 
  --task-name go-* \ 
  --agent cursor-cli \ 
  --model openai/gpt-5.2
```

Run all tasks with a few models, with 3 attempts per model-task combination:

```bash
export OPENROUTER_API_KEY=...
harbor run \ 
  --path datasets/otel \ 
  --agent terminus-2 \ 
  --model openrouter/google/gemini-3-pro-preview \ 
  --model openrouter/anthropic/claude-opus-4-5 \ 
  --model openrouter/openai/gpt-5.2-codex \ 
  --n-attempts 3
```

You can view trajectories (interactions between the agent and the system) via `harbor view jobs`.
Our overview of Harbor in [Migrating CompileBench to Harbor: standardizing AI agent evals](https://quesma.com/blog/compilebench-in-harbor/).

## Content

The OpenTelemetry dataset [datasets/otel](./datasets/otel) contains a set of tasks testing AI models' ability to instrument applications with OpenTelemetry across 11 programming languages.
So far, it contains the following tasks:

* **C++**: [simple](https://quesma.com/benchmarks/otel/tasks/cpp-simple), [advanced](https://quesma.com/benchmarks/otel/tasks/cpp-advanced), [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/cpp-distributed-context-propagation)
* **Go**: [http-tracing](https://quesma.com/benchmarks/otel/tasks/go-http-tracing), [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/go-distributed-context-propagation), [workflow-tracing](https://quesma.com/benchmarks/otel/tasks/go-workflow-tracing), [microservices](https://quesma.com/benchmarks/otel/tasks/go-microservices), [grpc-fix](https://quesma.com/benchmarks/otel/tasks/go-grpc-fix), [microservices-logs](https://quesma.com/benchmarks/otel/tasks/go-microservices-logs), [microservices-traces](https://quesma.com/benchmarks/otel/tasks/go-microservices-traces), [microservices-traces-simple](https://quesma.com/benchmarks/otel/tasks/go-microservices-traces-simple)
* **Java**: [simple](https://quesma.com/benchmarks/otel/tasks/java-simple), [advanced](https://quesma.com/benchmarks/otel/tasks/java-advanced), [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/java-distributed-context-propagation), [microservices](https://quesma.com/benchmarks/otel/tasks/java-microservices)
* **JavaScript**: [microservices](https://quesma.com/benchmarks/otel/tasks/js-microservices)
* **.NET**: [microservices](https://quesma.com/benchmarks/otel/tasks/net-microservices)
* **PHP**: [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/php-distributed-context-propagation), [microservices](https://quesma.com/benchmarks/otel/tasks/php-microservices)
* **Python**: [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/python-distributed-context-propagation), [microservices](https://quesma.com/benchmarks/otel/tasks/python-microservices)
* **Ruby**: [microservices](https://quesma.com/benchmarks/otel/tasks/ruby-microservices)
* **Rust**: [distributed-context-propagation](https://quesma.com/benchmarks/otel/tasks/rust-distributed-context-propagation), [microservices](https://quesma.com/benchmarks/otel/tasks/rust-microservices)
* **Erlang**: [microservices](https://quesma.com/benchmarks/otel/tasks/erlang-microservices)
* **Swift**: [microservices](https://quesma.com/benchmarks/otel/tasks/swift-microservices)

## Notes

* Tasks are internet dependent and require internet access to run
* Task solution instructions are not yet included (work in progress)
* Results are in [benchmark-results/otel](./benchmark-results/otel), for reference and comparison - we generate these from `jobs` (so far pipeline is no included).

## License

Apache 2.0, see [LICENSE](LICENSE) for details.
