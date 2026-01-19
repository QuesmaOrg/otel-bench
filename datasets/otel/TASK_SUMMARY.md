# All Benchmark Tasks - Description and Analysis

This document summarizes all 24 benchmark tasks. For detailed task descriptions, see `task_data.yaml`.

---

## Summary Table

| Task                                   | Pass Rate | Category        | Difficulty      |
| -------------------------------------- | --------- | --------------- | --------------- |
| cpp-simple                             | 74.4%     | C++ Tracing     | Easy            |
| go-microservices-traces                | 51.3%     | Go Tracing      | Medium          |
| go-grpc-fix                            | 46.2%     | Go Bug Fix      | Medium          |
| cpp-advanced                           | 33.3%     | C++ Advanced    | Hard            |
| python-microservices                   | 33.3%     | Python Full     | Medium          |
| go-microservices-logs                  | 25.6%     | Go Logging      | Medium          |
| js-microservices                       | 17.9%     | JavaScript Full | Medium          |
| go-microservices                       | 10.3%     | Go Full         | Hard            |
| net-microservices                      | 10.3%     | .NET Full       | Hard            |
| php-distributed-context-propagation    | 10.3%     | PHP Context     | Hard            |
| cpp-distributed-context-propagation    | 2.6%      | C++ Context     | Hard            |
| go-distributed-context-propagation     | 2.6%      | Go Context      | Hard            |
| php-microservices                      | 2.6%      | PHP Full        | Hard            |
| rust-distributed-context-propagation   | 2.6%      | Rust Context    | Hard            |
| erlang-microservices                   | 0%        | Erlang Full     | Very Hard       |
| go-log                                 | 0%        | Go Logging      | N/A (Broken)    |
| go-microservices-traces-simple         | 0%        | Go Tracing      | N/A (Broken)    |
| go-workflow-tracing                    | 0%        | Go Tracing      | Hard            |
| java-distributed-context-propagation   | 0%        | Java Context    | Hard            |
| java-microservices                     | 0%        | Java Full       | Very Hard       |
| python-distributed-context-propagation | 0%        | Python Context  | Hard            |
| ruby-microservices                     | 0%        | Ruby Full       | Very Hard       |
| rust-microservices                     | 0%        | Rust Full       | N/A (Env Issue) |
| swift-microservices                    | 0%        | Swift Full      | Very Hard       |

---

## Task Categories

### By Language

| Language   | Tasks | Avg Pass Rate |
| ---------- | ----- | ------------- |
| C++        | 3     | 36.8%         |
| Go         | 8     | 18.3%         |
| Java       | 2     | 0%            |
| JavaScript | 1     | 17.9%         |
| .NET       | 1     | 10.3%         |
| PHP        | 2     | 6.5%          |
| Python     | 2     | 16.7%         |
| Ruby       | 1     | 0%            |
| Rust       | 2     | 1.3%          |
| Swift      | 1     | 0%            |
| Erlang     | 1     | 0%            |

### By Task Type

| Type                     | Description                                | Avg Pass Rate |
| ------------------------ | ------------------------------------------ | ------------- |
| Simple Tracing           | Basic span generation                      | 74.4%         |
| Tracing Only             | Add tracing to microservices               | 38.8%         |
| Logging Only             | Add logging to microservices               | 25.6%         |
| Full (Tracing + Logging) | Both tracing and logging                   | 12.8%         |
| Context Propagation      | Distributed tracing with strict assertions | 3.1%          |
| Bug Fix                  | Fix existing OTEL code                     | 46.2%         |

### By Failure Category

| Category                             | Tasks                                                            | Notes                                          |
| ------------------------------------ | ---------------------------------------------------------------- | ---------------------------------------------- |
| Task/Environment Broken              | go-log, go-microservices-traces-simple, rust-microservices       | Need fixing                                    |
| Context Propagation Misunderstanding | java/python-distributed-context-propagation, go-workflow-tracing | Models fail to produce correct trace structure |
| LLM Knowledge Gaps                   | erlang, java-microservices, ruby, swift                          | SDK API issues                                 |
| Working Well                         | cpp-simple, go-traces, go-grpc-fix, python-microservices         | >30% pass rate                                 |
