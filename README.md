# OpenTelemetry Benchmark (OTelBench)

A benchmark suite for evaluating AI models on OpenTelemetry instrumentation tasks across multiple programming languages. Built on the [Harbor framework](https://harborframework.com).

## Overview

This repository contains:
- **Otel Dataset**: A comprehensive set of tasks testing AI models' ability to instrument applications with OpenTelemetry across 11+ programming languages

## Dataset

The OpenTelemetry dataset (`datasets/otel/`) contains tasks for:

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

## Disclaimer

- Tasks are internet dependent and require internet access to run
- Task solution instructions are not yet included (work in progress)

## License

See [LICENSE](LICENSE) for details.
