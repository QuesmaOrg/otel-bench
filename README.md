# OpenTelemetry Benchmark (OTelBench) by Quesma

A open-source benchmark for evaluating AI models on OpenTelemetry instrumentation tasks across multiple programming languages.

* Benchmark: [OTelBench results](https://quesma.com/benchmarks/otel/)
* Blog post: [Benchmarking OpenTelemetry: Can AI trace your failed login?](https://quesma.com/blog/introducing-otel-bench/)

## Quick start

Requires [Harbor](https://harborframework.com) (`uv tool install harbor`), Docker, and relevant API KEYs.
You need your own API keys - be it `ANTHROPIC_API_KEY`.

By default, we use `terminus-2` agent (default for Harbor) agents via [OpenRouter](https://openrouter.ai/) to compare models.
You are free to use other, including well-known CLI AI Agents like Claude Code, Codex and Cursor CLI.

You need to cone this repo:

```bash
git clone git@github.com:QuesmaOrg/otel-bench.git
cd otel-bench
```

Run a single tasks, for a single model:

```bash
export ANTHROPIC_API_KEY=...
harbor run \ 
  --path datasets/otel \ 
  --task cpp-simple \ 
  --agent claude-code \  # only for Claude models
  --model anthropic/claude-opus-4-5-20251101
```

Task names allow wildcards, so if you want to run all Go tasks in Cursor CLI, it works like:

```bash
export OPENAI_API_KEY=...
harbor run \ 
  --path datasets/otel \ 
  --task go-* \ 
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

The OpenTelemetry dataset (`datasets/otel/`) contains set of tasks testing AI models' ability to instrument applications with OpenTelemetry across 11 programming languages.
So far, it contains the following tasks:

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

## Notes

* Tasks are internet dependent and require internet access to run
* Task solution instructions are not yet included (work in progress)

## License

Apache 2.0, see [LICENSE](LICENSE) for details.
