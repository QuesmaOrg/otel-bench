# OpenTelemetry Tasks Summary

This document classifies all 26 OpenTelemetry instrumentation tasks by difficulty level.

> **Note:** There are 27 task directories, but `go-log` is not included in benchmark results because it is incomplete (contains only instruction.md without source code, tests, or configuration).

## Summary

| Difficulty | Count | Percentage |
|------------|-------|------------|
| Easy       | 4     | 15.4%      |
| Medium     | 17    | 65.4%      |
| Hard       | 5     | 19.2%      |

## Authors

| Author | Tasks Created |
|--------|---------------|
| Rafal Strzalinski | 13 |
| Przemek Delewski | 13 |

---

## Easy Tasks (4)

Simple single-service instrumentation, basic tracing setup.

| Task | Language | Author | Description |
|------|----------|--------|-------------|
| cpp-simple | C++ | Przemek Delewski | Instrument a simple app with 3 methods to generate JSON trace output with parent-child span relationships |
| java-simple | Java | Przemek Delewski | Instrument a simple app with 3 methods to generate JSON trace output with parent-child span relationships |
| go-http-tracing | Go | Przemek Delewski | Instrument HTTP server and client with W3C context propagation |
| go-microservices-traces-simple | Go | Rafal Strzalinski | Add basic OTEL tracing to microservices following conventions |

---

## Medium Tasks (17)

Multiple services, context propagation, moderate complexity, logging + tracing.

### Distributed Context Propagation

| Task | Language | Author | Description |
|------|----------|--------|-------------|
| go-distributed-context-propagation | Go | Przemek Delewski | HTTP server/client with distributed tracing and W3C context propagation |
| java-distributed-context-propagation | Java | Przemek Delewski | HTTP server/client with OTLP export and distributed tracing |
| php-distributed-context-propagation | PHP | Przemek Delewski | HTTP server/client with OpenTelemetry SDK and context propagation |
| python-distributed-context-propagation | Python | Przemek Delewski | HTTP server/client with OpenTelemetry SDK and context propagation |
| rust-distributed-context-propagation | Rust | Przemek Delewski | Actix-web server and Reqwest client with async patterns |

### Microservices Instrumentation

| Task | Language | Author | Description |
|------|----------|--------|-------------|
| go-microservices | Go | Rafal Strzalinski | Add OTEL tracing and logging with lifecycle management |
| go-microservices-logs | Go | Rafal Strzalinski | Add OTEL logging with lifecycle and HTTP field logging |
| go-microservices-traces | Go | Rafal Strzalinski | Add OTEL tracing with business domain instrumentation |
| java-microservices | Java | Rafal Strzalinski | Add OTEL tracing and logging to Java microservices |
| js-microservices | JavaScript | Rafal Strzalinski | Add OTEL tracing and logging to Node.js microservices |
| net-microservices | .NET/C# | Rafal Strzalinski | Add OTEL tracing and logging to .NET microservices |
| php-microservices | PHP | Rafal Strzalinski | Add OTEL tracing and logging to PHP microservices |
| python-microservices | Python | Rafal Strzalinski | Add OTEL tracing and logging to Python microservices |
| ruby-microservices | Ruby | Rafal Strzalinski | Add OTEL tracing and logging to Ruby microservices |
| rust-microservices | Rust | Rafal Strzalinski | Add OTEL tracing and logging with async patterns |
| erlang-microservices | Erlang | Rafal Strzalinski | Add OTEL tracing and logging to Erlang/OTP microservices |

### Workflow Tracing

| Task | Language | Author | Description |
|------|----------|--------|-------------|
| go-workflow-tracing | Go | Przemek Delewski | HTTP server/client focusing on complete workflow tracing |

---

## Hard Tasks (5)

Complex distributed systems, advanced features, multi-threading, error handling.

| Task | Language | Author | Description |
|------|----------|--------|-------------|
| cpp-advanced | C++ | Przemek Delewski | Multi-threaded web service with async operations, error handling, context propagation across threads, 15-20 spans |
| java-advanced | Java | Przemek Delewski | Multi-threaded web service with CompletableFuture async, error handling, span links, 15-20 spans |
| cpp-distributed-context-propagation | C++ | Przemek Delewski | HTTP server/client with cpp-httplib, CMake build, complex SDK integration |
| go-grpc-fix | Go | Przemek Delewski | Debug and fix failing gRPC test in compile-time instrumentation project |
| swift-microservices | Swift | Rafal Strzalinski | Add OTEL tracing and logging with async/await patterns (less mature SDK) |

---

## Difficulty Criteria

### Easy
- Single service instrumentation
- Basic span creation with parent-child relationships
- Simple JSON or OTLP output
- Minimal configuration required

### Medium
- Multiple services with context propagation
- Both tracing and logging instrumentation
- HTTP/gRPC instrumentation
- Lifecycle management
- Standard SDK usage patterns

### Hard
- Multi-threading with context propagation across thread boundaries
- Async operations with span links
- Error handling and exception events
- Complex build systems (CMake, etc.)
- Debugging existing instrumentation code
- Less mature SDK ecosystems (Swift, C++)
- 15+ spans with complex relationships

---

## Classification Methodology

Tasks were classified by analyzing their characteristics against key differentiators:

| Factor | Easy | Medium | Hard |
|--------|------|--------|------|
| Services | 1 | 2+ | 2+ with complex interactions |
| Threading | Single | Single/Simple | Multi-threaded |
| SDK maturity | Any | Mature | Less mature (C++, Swift) |
| Task type | Instrument from scratch | Standard patterns | Debug/fix or advanced patterns |
| Build complexity | Simple | Standard | Complex (CMake) |

### How Tasks Were Identified

**Easy Tasks** - Identified by:
- Single service/application to instrument
- Basic span creation with simple parent-child relationships
- Output to JSON or simple OTLP export
- Task names like `*-simple` or basic HTTP tracing

**Medium Tasks** - Identified by:
- Multiple services requiring context propagation
- Both tracing AND logging instrumentation needed
- Standard HTTP client/server patterns
- Well-supported language SDKs (Go, Java, Python, etc.)
- Task names with `distributed-context-propagation` or `microservices`

**Hard Tasks** - Identified by:
- Multi-threading with context propagation across thread boundaries
- Async operations (CompletableFuture, async/await)
- Complex build systems (CMake for C++)
- Less mature SDK ecosystems (Swift, C++)
- Debugging existing code rather than writing new
- Task names with `advanced` or known difficult languages

> **Note:** The classification is somewhat subjective. For example, `go-http-tracing` could arguably be Medium, but was classified as Easy because it focuses on basic HTTP instrumentation with a mature Go SDK.

---

## Task Categories

### By Type

**Single Service Instrumentation:**
- cpp-simple, java-simple (Easy)
- cpp-advanced, java-advanced (Hard)

**Distributed Context Propagation:**
- go, java, php, python, rust (Medium)
- cpp (Hard)

**Microservices Instrumentation:**
- go, js, net, php, python, ruby, rust, erlang (Medium)
- swift (Hard)

**Specialized:**
- go-http-tracing (Easy)
- go-workflow-tracing (Medium)
- go-grpc-fix (Hard - debugging)

### By Language

| Language | Easy | Medium | Hard | Total |
|----------|------|--------|------|-------|
| Go       | 2    | 5      | 1    | 8     |
| C++      | 1    | 0      | 2    | 3     |
| Java     | 1    | 2      | 1    | 4     |
| Python   | 0    | 2      | 0    | 2     |
| PHP      | 0    | 2      | 0    | 2     |
| Rust     | 0    | 2      | 0    | 2     |
| JavaScript | 0  | 1      | 0    | 1     |
| .NET     | 0    | 1      | 0    | 1     |
| Ruby     | 0    | 1      | 0    | 1     |
| Erlang   | 0    | 1      | 0    | 1     |
| Swift    | 0    | 0      | 1    | 1     |

### By Author

**Przemek Delewski (13 tasks):**
- cpp-simple, cpp-advanced, cpp-distributed-context-propagation
- java-simple, java-advanced, java-distributed-context-propagation
- go-distributed-context-propagation, go-workflow-tracing, go-http-tracing, go-grpc-fix
- php-distributed-context-propagation, python-distributed-context-propagation, rust-distributed-context-propagation

**Rafal Strzalinski (13 tasks):**
- go-microservices, go-microservices-logs, go-microservices-traces, go-microservices-traces-simple
- java-microservices, js-microservices, net-microservices, php-microservices
- python-microservices, ruby-microservices, rust-microservices, erlang-microservices, swift-microservices

> **Note:** Rafal Strzalinski also created `go-log` which is excluded from benchmark results.