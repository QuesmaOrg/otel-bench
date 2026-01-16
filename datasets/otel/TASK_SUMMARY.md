# All Benchmark Tasks - Description and Analysis

This document describes all 24 benchmark tasks, explaining what each task requires and analyzing pass/fail patterns.

---

## Summary Table

| Task | Pass Rate | Category | Difficulty |
|------|-----------|----------|------------|
| cpp-otel-simple | 74.4% | C++ Tracing | Easy |
| go-otel-microservices-traces | 51.3% | Go Tracing | Medium |
| go-otel-grpc-fix | 46.2% | Go Bug Fix | Medium |
| cpp-otel-advanced | 33.3% | C++ Advanced | Hard |
| python-otel-microservices | 33.3% | Python Full | Medium |
| go-otel-microservices-logs | 25.6% | Go Logging | Medium |
| js-otel-microservices | 17.9% | JavaScript Full | Medium |
| go-otel-microservices | 10.3% | Go Full | Hard |
| net-otel-microservices | 10.3% | .NET Full | Hard |
| php-otel-distributed-context-propagation | 10.3% | PHP Context | Hard |
| cpp-otel-distributed-context-propagation | 2.6% | C++ Context | Hard |
| go-otel-distributed-context-propagation | 2.6% | Go Context | Hard |
| php-otel-microservices | 2.6% | PHP Full | Hard |
| rust-otel-distributed-context-propagation | 2.6% | Rust Context | Hard |
| erlang-otel-microservices | 0% | Erlang Full | Very Hard |
| go-otel-log | 0% | Go Logging | N/A (Broken) |
| go-otel-microservices-traces-simple | 0% | Go Tracing | N/A (Broken) |
| go-otel-workflow-tracing | 0% | Go Tracing | Hard |
| java-otel-distributed-context-propagation | 0% | Java Context | Hard |
| java-otel-microservices | 0% | Java Full | Very Hard |
| python-otel-distributed-context-propagation | 0% | Python Context | Hard |
| ruby-otel-microservices | 0% | Ruby Full | Very Hard |
| rust-otel-microservices | 0% | Rust Full | N/A (Env Issue) |
| swift-otel-microservices | 0% | Swift Full | Very Hard |

---

## Task Descriptions

### 1. cpp-otel-simple (74.4% pass rate)

**What It Is:**
Instrument a simple C++ application with 3 methods (`work`, `fastOp`, `slowOp`) to generate OpenTelemetry-compatible trace output. Create OTEL implementation that outputs JSON traces with parent-child span relationships.

**Why It Succeeds:**
- Simple, well-defined scope (3 spans only)
- No external dependencies or network calls
- Clear output format requirements

**Common Failure Reasons:**
- Missing parent-child relationships

---

### 2. cpp-otel-advanced (33.3% pass rate)

**What It Is:**
Instrument a complex multi-threaded C++ application simulating a web service with database operations, message queue, and background workers. Requires comprehensive tracing including error handling, async operations, and context propagation across threads.

**Why It's Harder:**
- Multi-threaded context propagation
- Error handling and exception recording
- Multiple service components (DB, MQ, workers)
- Requires 15-20 spans with correct relationships
- Async span linking

**Common Failure Reasons:**
- Context lost across thread boundaries
- Missing error event recording
- Incomplete span relationships

---

### 3. cpp-otel-distributed-context-propagation (2.6% pass rate)

**What It Is:**
Instrument a C++ client-server application using httplib. Client makes search requests, receives tokens, retrieves results. Must demonstrate distributed tracing with context propagation between client and server, producing exactly 2 trace IDs.

**Why It Fails:**
- C++ OTEL SDK is complex to configure
- Context propagation via HTTP headers is tricky
- Test expects exactly 2 trace IDs (strict)
- CMake build configuration challenges

---

### 4. erlang-otel-microservices (0% pass rate)

**What It Is:**
Add OTEL tracing and logging to Erlang microservices (gateway, order, stock). Export telemetry to OTLP endpoint, log lifecycle events and HTTP requests.

**Why It Fails:**
Models hallucinate non-existent Erlang packages. The Erlang OTEL ecosystem is poorly documented, leading to packages like `opentelemetry 1.4.2` that don't exist in Hex.

**Example Error:**
```
===> Package not found in any repo: opentelemetry 1.4.2
```

---

### 5. go-otel-distributed-context-propagation (2.6% pass rate)

**What It Is:**
Instrument a Go client-server application with OTEL tracing. Client makes HTTP requests, must propagate trace context to server. Test expects exactly 2 unique trace IDs.

**Why It Mostly Fails:**
- Strict assertion: exactly 2 trace IDs required
- Models often produce 1 (too much propagation) or 3+ (not enough)
- Requires understanding of when to create new vs. continue traces

---

### 6. go-otel-grpc-fix (46.2% pass rate)

**What It Is:**
Debug and fix a failing gRPC end-to-end test in the OpenTelemetry Go compile-time instrumentation project. The instrumentation code isn't being properly injected during compilation.

**Why It Has Moderate Success:**
- Clear problem definition (fix failing test)
- Existing codebase with working examples to compare
- Test output provides debugging clues

**Common Failure Reasons:**
- Incorrect hook configuration
- Missing gRPC-specific instrumentation points
- Code generation errors

---

### 7. go-otel-microservices (10.3% pass rate)

**What It Is:**
Add both OTEL tracing AND logging to Go microservices (gateway, order, stock). Must use OTEL SDK v1.39.0, export to OTLP endpoint, log lifecycle and HTTP events, work without collector.

**Why It's Hard:**
- Dual requirement (tracing + logging)
- Specific SDK version required
- Multiple services to instrument
- Graceful degradation when collector unavailable

---

### 8. go-otel-microservices-logs (25.6% pass rate)

**What It Is:**
Add OTEL logging only to Go microservices. Log lifecycle events, HTTP requests, and ensure graceful degradation without collector.

**Why It Has Better Success Than Full:**
- Single focus (logging only, no tracing)
- Simpler than dual instrumentation
- Go logging APIs are well-documented

---

### 9. go-otel-microservices-traces (51.3% pass rate)

**What It Is:**
Add OTEL tracing only to Go microservices. Follow conventions and use recent OTEL SDK.

**Why It Has Good Success:**
- Single focus (tracing only, no logging)
- Go OTEL tracing is well-documented
- Fewer requirements than full instrumentation

---

### 10. go-otel-workflow-tracing (0% pass rate)

**What It Is:**
Instrument a Go client-server search workflow with focused OTEL tracing. Must trace only essential HTTP operations (client workflow, requests, server handlers) with **at most 6 spans**.

**Why It Fails:**
Models over-instrument, creating 11+ spans by adding spans for internal operations (`process_query`, `lookup_token`, etc.). The task explicitly requires minimal, focused instrumentation.

**Example Error:**
```
AssertionError: Too many spans: 11 (expected at most 6)
```

---

### 11. java-otel-distributed-context-propagation (0% pass rate)

**What It Is:**
Instrument a Java client-server application with minimal OTEL tracing. Client makes two workflows (valid token, invalid token). Must produce exactly 2 trace IDs.

**Why It Fails:**
- Test expects exactly 2 trace IDs, models produce 3
- Java OTEL SDK complexity
- Models create extra traces for initialization/startup

---

### 12. java-otel-microservices (0% pass rate)

**What It Is:**
Add OTEL tracing and logging to Java Spring Boot microservices (gateway, order, stock). Must use OTEL SDK v1.39.0, preserve Makefiles.

**Why It Fails:**
Models use incorrect Java OTEL SDK APIs:
- Non-existent packages (`opentelemetry-exporter-otlp-http-logs`)
- Wrong package paths (`io.opentelemetry.semconv.ResourceAttributes`)
- Wrong method signatures (`BatchSpanProcessor.create()`)
- Import conflicts (`Logger` ambiguous)
- Non-existent Spring classes (`ApplicationStoppingEvent`)

---

### 13. js-otel-microservices (17.9% pass rate)

**What It Is:**
Add OTEL tracing and logging to Node.js/JavaScript microservices. Use OTEL SDK v1.39.0, export to OTLP, log lifecycle and HTTP events.

**Why It Has Moderate Success:**
- JavaScript OTEL SDK is well-documented
- npm ecosystem is familiar to models
- Auto-instrumentation available

**Common Failure Reasons:**
- Version mismatches
- Missing lifecycle logging
- Async context propagation issues

---

### 14. net-otel-microservices (10.3% pass rate)

**What It Is:**
Add OTEL tracing and logging to .NET microservices (gateway, order, stock). Export to OTLP, log lifecycle and HTTP events, work without collector.

**Why It's Hard:**
- .NET OTEL SDK has specific patterns
- Multiple project files to configure
- NuGet package management
- Dual instrumentation requirement

**Common Failure Reasons:**
- Wrong package versions
- Missing lifecycle logging
- Services don't respond to requests

---

### 15. php-otel-distributed-context-propagation (10.3% pass rate)

**What It Is:**
Instrument a PHP client-server application with OTEL tracing. Demonstrate distributed context propagation, produce exactly 2 trace IDs.

**Why It Has Some Success:**
- PHP OTEL SDK is relatively straightforward
- Composer dependency management works well
- HTTP context propagation is simpler in PHP

**Common Failure Reasons:**
- Server output format mismatch (test expects "Server starting on :8080" but PHP dev server outputs different format)
- Only 1 trace ID produced instead of 2 (same issue as Python - context propagated across both workflows)

**Example Error:**
```
AssertionError: Expected at least 2 trace IDs, got 1
```

---

### 16. php-otel-microservices (2.6% pass rate)

**What It Is:**
Add OTEL tracing and logging to PHP Sinatra-style microservices. Export to OTLP, log lifecycle and HTTP events.

**Why It Mostly Fails:**
- PHP long-running process patterns differ
- Dual instrumentation complexity
- Less common use case for models

---

### 17. python-otel-distributed-context-propagation (0% pass rate)

**What It Is:**
Instrument a Python client-server application with OTEL tracing. Must produce exactly 2 trace IDs for two separate workflows.

**Why It Fails:**
Test expects 2 trace IDs but models produce only 1. Models propagate context "too well" - they continue the same trace across both workflows instead of creating separate traces for each.

**Example Error:**
```
AssertionError: Expected more than 1 trace ID, got 1
```

---

### 18. python-otel-microservices (33.3% pass rate)

**What It Is:**
Add OTEL tracing and logging to Python microservices. Export to OTLP, log lifecycle and HTTP events, preserve Makefile targets.

**Why It Has Good Success:**
- Python OTEL SDK is well-documented
- pip/requirements.txt is familiar
- Good auto-instrumentation support

**Common Failure Reasons:**
- Missing lifecycle logging
- Makefile targets broken
- Async context issues

---

### 19. ruby-otel-microservices (0% pass rate)

**What It Is:**
Add OTEL tracing and logging to Ruby Sinatra microservices (gateway, order, stock). Export to OTLP, log lifecycle and HTTP events.

**Why It Fails:**
Code compiles and dependencies install, but no telemetry is exported. Common issues:
- Wrong OTLP endpoint configuration
- Exporter not initialized properly
- Missing shutdown/flush calls

**Example Error:**
```
✓ All code compiled successfully
Found 0 rows in traces table
```

---

### 20. rust-otel-distributed-context-propagation (2.6% pass rate)

**What It Is:**
Instrument a Rust client-server application with OTEL tracing. Demonstrate context propagation, produce exactly 2 trace IDs.

**Why It Mostly Fails:**
- Rust OTEL SDK is complex
- Strict assertion on trace ID count
- Cargo dependency management challenges

---

### 21. rust-otel-microservices (0% pass rate)

**What It Is:**
Add OTEL tracing and logging to Rust microservices (gateway, order, stock). Export to OTLP, log lifecycle and HTTP events.

**Why It Fails:**
Docker environment missing system dependencies. The `openssl-sys` crate requires `pkg-config` and `libssl-dev`, which aren't installed.

**Example Error:**
```
Could not find openssl via pkg-config
The pkg-config command could not be found.
```

**Root Cause:** Environment configuration issue, not model failure.

---

### 22. swift-otel-microservices (0% pass rate)

**What It Is:**
Add OTEL tracing and logging to Swift microservices (gateway, order, stock). Export to OTLP, log lifecycle and HTTP events.

**Why It Fails:**
Swift services fail to compile or start. No `test_compile_all` test exists, so specific errors aren't captured. Swift OTEL SDK is immature and Swift Package Manager is complex.

---

## Task Categories

### By Language
| Language | Tasks | Avg Pass Rate |
|----------|-------|---------------|
| C++ | 3 | 36.8% |
| Go | 8 | 18.3% |
| Java | 2 | 0% |
| JavaScript | 1 | 17.9% |
| .NET | 1 | 10.3% |
| PHP | 2 | 6.5% |
| Python | 2 | 16.7% |
| Ruby | 1 | 0% |
| Rust | 2 | 1.3% |
| Swift | 1 | 0% |
| Erlang | 1 | 0% |

### By Task Type
| Type | Description | Avg Pass Rate |
|------|-------------|---------------|
| Simple Tracing | Basic span generation | 74.4% |
| Tracing Only | Add tracing to microservices | 38.8% |
| Logging Only | Add logging to microservices | 25.6% |
| Full (Tracing + Logging) | Both tracing and logging | 12.8% |
| Context Propagation | Distributed tracing with strict assertions | 3.1% |
| Bug Fix | Fix existing OTEL code | 46.2% |

### By Failure Category
| Category | Tasks | Notes |
|----------|-------|-------|
| Task/Environment Broken | go-otel-log, go-otel-microservices-traces-simple, rust-otel-microservices | Need fixing |
| Context Propagation Misunderstanding | java/python-otel-distributed-context-propagation, go-otel-workflow-tracing | Models fail to produce correct trace structure |
| LLM Knowledge Gaps | erlang, java-microservices, ruby, swift | SDK API issues |
| Working Well | cpp-simple, go-traces, go-grpc-fix, python-microservices | >30% pass rate |