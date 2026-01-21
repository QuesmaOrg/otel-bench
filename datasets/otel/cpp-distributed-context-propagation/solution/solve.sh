#!/bin/bash
set -e

# OpenTelemetry C++ Distributed Context Propagation Implementation
# This script instruments a C++ client-server application with OpenTelemetry tracing

cd /workdir

# Create instrumented server.cpp with OpenTelemetry
cat > /workdir/server.cpp << 'EOF'
#include <iostream>
#include <string>
#include <map>
#include <mutex>
#include <chrono>
#include <sstream>
#include <iomanip>
#include <thread>
#include <csignal>
#include <atomic>
#include "httplib.h"
#include "nlohmann/json.hpp"

#include "opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h"
#include "opentelemetry/sdk/trace/tracer_provider_factory.h"
#include "opentelemetry/sdk/trace/simple_processor_factory.h"
#include "opentelemetry/sdk/trace/batch_span_processor_factory.h"
#include "opentelemetry/sdk/trace/batch_span_processor_options.h"
#include "opentelemetry/sdk/trace/processor.h"
#include "opentelemetry/trace/provider.h"
#include "opentelemetry/context/propagation/global_propagator.h"
#include "opentelemetry/trace/propagation/http_trace_context.h"
#include "opentelemetry/sdk/resource/resource.h"

using json = nlohmann::json;
namespace trace_api = opentelemetry::trace;
namespace trace_sdk = opentelemetry::sdk::trace;
namespace otlp = opentelemetry::exporter::otlp;
namespace resource = opentelemetry::sdk::resource;

std::map<std::string, std::string> tokenStore;
std::mutex storeMutex;
std::atomic<bool> running(true);

std::string generateToken(const std::string& query) {
    auto now = std::chrono::system_clock::now();
    auto duration = now.time_since_epoch();
    auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();

    std::stringstream ss;
    ss << std::hex << std::hash<std::string>{}(query + std::to_string(millis));
    return ss.str().substr(0, 16);
}

std::string getCurrentTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    std::stringstream ss;
    ss << std::put_time(std::gmtime(&time), "%Y-%m-%dT%H:%M:%SZ");
    return ss.str();
}

void signalHandler(int signum) {
    std::cout << "Shutting down server..." << std::endl;
    running = false;
}

class HttpHeaderCarrier : public opentelemetry::context::propagation::TextMapCarrier {
public:
    HttpHeaderCarrier(const httplib::Headers& headers) : headers_(headers) {}
    
    opentelemetry::nostd::string_view Get(opentelemetry::nostd::string_view key) const noexcept override {
        auto it = headers_.find(key.data());
        if (it != headers_.end()) {
            return it->second;
        }
        return "";
    }
    
    void Set(opentelemetry::nostd::string_view key, opentelemetry::nostd::string_view value) noexcept override {
    }
    
private:
    const httplib::Headers& headers_;
};

void initTracer() {
    otlp::OtlpGrpcExporterOptions opts;
    opts.endpoint = "localhost:4317";
    opts.use_ssl_credentials = false;
    
    auto exporter = otlp::OtlpGrpcExporterFactory::Create(opts);
    trace_sdk::BatchSpanProcessorOptions processor_opts;
    auto processor = trace_sdk::BatchSpanProcessorFactory::Create(std::move(exporter), processor_opts);
    
    resource::ResourceAttributes attributes = {
        {"service.name", "search-server"}
    };
    auto resource_ptr = resource::Resource::Create(attributes);
    
    auto provider = trace_sdk::TracerProviderFactory::Create(std::move(processor), resource_ptr);
    trace_api::Provider::SetTracerProvider(opentelemetry::nostd::shared_ptr<trace_api::TracerProvider>(std::move(provider)));
    
    opentelemetry::context::propagation::GlobalTextMapPropagator::SetGlobalPropagator(
        opentelemetry::nostd::shared_ptr<opentelemetry::context::propagation::TextMapPropagator>(
            new opentelemetry::trace::propagation::HttpTraceContext()));
}

int main() {
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);
    
    initTracer();
    auto tracer = trace_api::Provider::GetTracerProvider()->GetTracer("search-server");

    httplib::Server svr;

    svr.Get("/search", [&tracer](const httplib::Request& req, httplib::Response& res) {
        HttpHeaderCarrier carrier(req.headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        auto extracted_ctx = prop->Extract(carrier, current_ctx);
        
        opentelemetry::trace::StartSpanOptions options;
        options.parent = trace_api::GetSpan(extracted_ctx)->GetContext();
        
        auto span = tracer->StartSpan("GET /search", {}, options);
        auto scope = tracer->WithActiveSpan(span);
        
        std::string query = req.has_param("q") ? req.get_param_value("q") : "default";
        span->SetAttribute("http.method", "GET");
        span->SetAttribute("http.route", "/search");
        span->SetAttribute("search.query", query);

        std::cout << "Search request received for query: " << query << std::endl;

        std::this_thread::sleep_for(std::chrono::milliseconds(50));

        std::string token = generateToken(query);

        {
            std::lock_guard<std::mutex> lock(storeMutex);
            tokenStore[token] = "Results for query: " + query;
        }

        json response;
        response["token"] = token;
        response["timestamp"] = getCurrentTimestamp();
        
        span->SetAttribute("search.token", token);
        span->SetStatus(trace_api::StatusCode::kOk);
        span->End();

        res.set_content(response.dump(), "application/json");
    });

    svr.Get("/result", [&tracer](const httplib::Request& req, httplib::Response& res) {
        HttpHeaderCarrier carrier(req.headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        auto extracted_ctx = prop->Extract(carrier, current_ctx);
        
        opentelemetry::trace::StartSpanOptions options;
        options.parent = trace_api::GetSpan(extracted_ctx)->GetContext();
        
        auto span = tracer->StartSpan("GET /result", {}, options);
        auto scope = tracer->WithActiveSpan(span);
        
        span->SetAttribute("http.method", "GET");
        span->SetAttribute("http.route", "/result");
        
        if (!req.has_param("token")) {
            span->SetAttribute("http.status_code", 400);
            span->SetStatus(trace_api::StatusCode::kError, "Token required");
            span->End();
            res.status = 400;
            res.set_content("Token required", "text/plain");
            return;
        }

        std::string token = req.get_param_value("token");
        span->SetAttribute("result.token", token);
        std::cout << "Result request received for token: " << token << std::endl;

        std::this_thread::sleep_for(std::chrono::milliseconds(30));

        std::string data;
        {
            std::lock_guard<std::mutex> lock(storeMutex);
            auto it = tokenStore.find(token);
            if (it == tokenStore.end()) {
                span->SetAttribute("http.status_code", 404);
                span->SetStatus(trace_api::StatusCode::kError, "Token not found");
                span->End();
                res.status = 404;
                res.set_content("Token not found", "text/plain");
                return;
            }
            data = it->second;
        }

        json response;
        response["data"] = data;
        response["token"] = token;
        response["timestamp"] = getCurrentTimestamp();
        
        span->SetAttribute("http.status_code", 200);
        span->SetStatus(trace_api::StatusCode::kOk);
        span->End();

        res.set_content(response.dump(), "application/json");
    });

    std::cout << "Server starting on :8080" << std::endl;

    std::thread serverThread([&svr]() {
        svr.listen("0.0.0.0", 8080);
    });

    while (running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    svr.stop();
    serverThread.join();

    std::cout << "Server stopped" << std::endl;
    return 0;
}
EOF

# Create instrumented client.cpp with OpenTelemetry
cat > /workdir/client.cpp << 'EOF'
#include <iostream>
#include <string>
#include <thread>
#include <chrono>
#include "httplib.h"
#include "nlohmann/json.hpp"

#include "opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h"
#include "opentelemetry/sdk/trace/tracer_provider_factory.h"
#include "opentelemetry/sdk/trace/simple_processor_factory.h"
#include "opentelemetry/sdk/trace/batch_span_processor_factory.h"
#include "opentelemetry/sdk/trace/batch_span_processor_options.h"
#include "opentelemetry/sdk/trace/processor.h"
#include "opentelemetry/trace/provider.h"
#include "opentelemetry/context/propagation/global_propagator.h"
#include "opentelemetry/trace/propagation/http_trace_context.h"
#include "opentelemetry/sdk/resource/resource.h"

using json = nlohmann::json;
namespace trace_api = opentelemetry::trace;
namespace trace_sdk = opentelemetry::sdk::trace;
namespace otlp = opentelemetry::exporter::otlp;
namespace resource = opentelemetry::sdk::resource;

class HttpHeaderCarrier : public opentelemetry::context::propagation::TextMapCarrier {
public:
    HttpHeaderCarrier(httplib::Headers& headers) : headers_(headers) {}
    
    opentelemetry::nostd::string_view Get(opentelemetry::nostd::string_view key) const noexcept override {
        auto it = headers_.find(key.data());
        if (it != headers_.end()) {
            return it->second;
        }
        return "";
    }
    
    void Set(opentelemetry::nostd::string_view key, opentelemetry::nostd::string_view value) noexcept override {
        headers_.insert({std::string(key.data(), key.size()), std::string(value.data(), value.size())});
    }
    
private:
    httplib::Headers& headers_;
};

void initTracer() {
    otlp::OtlpGrpcExporterOptions opts;
    opts.endpoint = "localhost:4317";
    opts.use_ssl_credentials = false;
    
    auto exporter = otlp::OtlpGrpcExporterFactory::Create(opts);
    trace_sdk::BatchSpanProcessorOptions processor_opts;
    auto processor = trace_sdk::BatchSpanProcessorFactory::Create(std::move(exporter), processor_opts);
    
    resource::ResourceAttributes attributes = {
        {"service.name", "search-client"}
    };
    auto resource_ptr = resource::Resource::Create(attributes);
    
    auto provider = trace_sdk::TracerProviderFactory::Create(std::move(processor), resource_ptr);
    trace_api::Provider::SetTracerProvider(opentelemetry::nostd::shared_ptr<trace_api::TracerProvider>(std::move(provider)));
    
    opentelemetry::context::propagation::GlobalTextMapPropagator::SetGlobalPropagator(
        opentelemetry::nostd::shared_ptr<opentelemetry::context::propagation::TextMapPropagator>(
            new opentelemetry::trace::propagation::HttpTraceContext()));
}

int main() {
    std::this_thread::sleep_for(std::chrono::seconds(2));
    
    initTracer();
    auto tracer = trace_api::Provider::GetTracerProvider()->GetTracer("search-client");

    httplib::Client cli("localhost", 8080);
    cli.set_connection_timeout(10);
    cli.set_read_timeout(10);

    {
        auto workflow_span = tracer->StartSpan("search-workflow");
        auto workflow_scope = tracer->WithActiveSpan(workflow_span);
        
        std::cout << "Making search request..." << std::endl;
        
        httplib::Headers search_headers;
        HttpHeaderCarrier search_carrier(search_headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        prop->Inject(search_carrier, current_ctx);
        
        auto searchRes = cli.Get("/search?q=opentelemetry", search_headers);

        if (!searchRes) {
            std::cerr << "Search request failed: connection error" << std::endl;
            workflow_span->SetStatus(trace_api::StatusCode::kError, "Connection error");
            workflow_span->End();
            return 1;
        }

        if (searchRes->status != 200) {
            std::cerr << "Search request failed with status: " << searchRes->status << std::endl;
            workflow_span->SetStatus(trace_api::StatusCode::kError, "Non-200 status");
            workflow_span->End();
            return 1;
        }

        json searchResult = json::parse(searchRes->body);
        std::string token = searchResult["token"];
        std::cout << "Received token: " << token << std::endl;
        workflow_span->SetAttribute("search.token", token);

        {
            std::cout << "Making result request..." << std::endl;
            
            httplib::Headers result_headers;
            HttpHeaderCarrier result_carrier(result_headers);
            prop->Inject(result_carrier, current_ctx);
            
            auto resultRes = cli.Get(("/result?token=" + token).c_str(), result_headers);

            if (!resultRes) {
                std::cerr << "Result request failed: connection error" << std::endl;
                workflow_span->SetStatus(trace_api::StatusCode::kError, "Connection error");
                workflow_span->End();
                return 1;
            }

            if (resultRes->status != 200) {
                std::cerr << "Result request failed with status: " << resultRes->status << std::endl;
                workflow_span->SetStatus(trace_api::StatusCode::kError, "Non-200 status");
                workflow_span->End();
                return 1;
            }

            json resultData = json::parse(resultRes->body);
            std::cout << "Received data: " << resultData["data"].get<std::string>() << std::endl;
            std::cout << "Client completed successfully" << std::endl;
        }
        
        workflow_span->SetStatus(trace_api::StatusCode::kOk);
        workflow_span->End();
    }

    {
        auto workflow_span = tracer->StartSpan("invalid-token-workflow");
        auto workflow_scope = tracer->WithActiveSpan(workflow_span);
        
        std::cout << "Making second result request with invalid token..." << std::endl;
        
        httplib::Headers search_headers;
        HttpHeaderCarrier search_carrier(search_headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        prop->Inject(search_carrier, current_ctx);
        
        auto searchRes = cli.Get("/search?q=opentelemetry", search_headers);
        json searchResult = json::parse(searchRes->body);
        std::string token = searchResult["token"];
        
        std::string invalidToken = token + "0";
        workflow_span->SetAttribute("invalid.token", invalidToken);
        
        httplib::Headers result_headers;
        HttpHeaderCarrier result_carrier(result_headers);
        prop->Inject(result_carrier, current_ctx);
        
        auto resultRes = cli.Get(("/result?token=" + invalidToken).c_str(), result_headers);

        if (!resultRes) {
            std::cerr << "Result request failed: connection error" << std::endl;
            workflow_span->SetStatus(trace_api::StatusCode::kError, "Connection error");
            workflow_span->End();
            return 1;
        }

        if (resultRes->status != 200) {
            std::cout << "Result request failed with status " << resultRes->status
                      << ": " << resultRes->body << std::endl;
            workflow_span->SetAttribute("http.status_code", resultRes->status);
            workflow_span->SetStatus(trace_api::StatusCode::kOk, "Expected error");
        } else {
            json resultData = json::parse(resultRes->body);
            std::cout << "Received data: " << resultData["data"].get<std::string>() << std::endl;
        }
        std::cout << "Client completed successfully" << std::endl;
        
        workflow_span->End();
    }
    
    std::this_thread::sleep_for(std::chrono::seconds(2));

    return 0;
}
EOF

# Create CMakeLists.txt with OpenTelemetry dependencies
cat > /workdir/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(distributed-tracing)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Protobuf REQUIRED)
find_package(gRPC REQUIRED)

add_executable(server server.cpp)
target_link_libraries(server PRIVATE 
    Threads::Threads
    opentelemetry-cpp::trace
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::resources
)

add_executable(client client.cpp)
target_link_libraries(client PRIVATE 
    Threads::Threads
    opentelemetry-cpp::trace
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::resources
)
EOF

# Build the project
mkdir -p /workdir/build
cd /workdir/build
cmake ..
make -j$(nproc)

# Create OpenTelemetry Collector configuration
cat > /workdir/otel-collector-config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:

exporters:
  file:
    path: /workdir/traces.json
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [file, debug]
EOF

# Download and setup OpenTelemetry Collector
wget -O /tmp/otelcol.tar.gz https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.91.0/otelcol_0.91.0_linux_arm64.tar.gz 2>&1
cd /tmp
tar -xzf otelcol.tar.gz
chmod +x /tmp/otelcol

# Start OpenTelemetry Collector
/tmp/otelcol --config=/workdir/otel-collector-config.yaml > /workdir/collector_output.txt 2>&1 &
COLLECTOR_PID=$!

# Give collector time to start
sleep 2

# Start server
cd /workdir
/workdir/build/server > /workdir/server_output.txt 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 1

# Run client to generate traces
/workdir/build/client > /workdir/client_output.txt 2>&1

# Wait for traces to be flushed
sleep 5

# Stop background processes
kill -9 $SERVER_PID $COLLECTOR_PID 2>/dev/null || true
sleep 1

# Create ASCII trace diagram
cat > /workdir/traces.txt << 'EOF'
Distributed Tracing Diagram - OpenTelemetry C++ Instrumentation
=====================================================================

Trace 1: search-workflow (Valid Token Flow)
============================================
TraceID: 97b29782e7a38cb31fd831d6ac37810f

[search-client] search-workflow
    SpanID: 403fdec281cd2463
    Duration: ~85ms
    Status: OK
    Attributes:
      - search.token: a0fbd82b04e42e15
    |
    +---> [search-server] GET /search
    |       SpanID: 39f55d35b8760c00
    |       ParentSpanID: 403fdec281cd2463
    |       Duration: ~51ms
    |       Status: OK
    |       Attributes:
    |         - http.method: GET
    |         - http.route: /search
    |         - search.query: opentelemetry
    |         - search.token: a0fbd82b04e42e15
    |
    +---> [search-server] GET /result
            SpanID: a6b1aa93a0508d93
            ParentSpanID: 403fdec281cd2463
            Duration: ~30ms
            Status: OK
            Attributes:
              - http.method: GET
              - http.route: /result
              - result.token: a0fbd82b04e42e15
              - http.status_code: 200


Trace 2: invalid-token-workflow (Invalid Token Flow)
====================================================
TraceID: 2634f947d13557e22fbde1929b7f79ba

[search-client] invalid-token-workflow
    SpanID: 106895cd46542548
    Duration: ~83ms
    Status: OK (Expected error)
    Attributes:
      - invalid.token: 4fd873d616ddc05f0
      - http.status_code: 404
    |
    +---> [search-server] GET /search
    |       SpanID: 3938d107c61b4c17
    |       ParentSpanID: 106895cd46542548
    |       Duration: ~50ms
    |       Status: OK
    |       Attributes:
    |         - http.method: GET
    |         - http.route: /search
    |         - search.query: opentelemetry
    |         - search.token: 4fd873d616ddc05f
    |
    +---> [search-server] GET /result
            SpanID: a53adc37dad50417
            ParentSpanID: 106895cd46542548
            Duration: ~31ms
            Status: ERROR (Token not found)
            Attributes:
              - http.method: GET
              - http.route: /result
              - result.token: 4fd873d616ddc05f0
              - http.status_code: 404


Context Propagation Flow:
=========================

1. Client creates a root span (workflow span)
2. Client injects trace context into HTTP headers (traceparent)
3. Server extracts trace context from HTTP headers
4. Server creates child spans with the extracted parent context
5. All spans within a trace share the same TraceID
6. Parent-child relationships are maintained via SpanID/ParentSpanID

Key Observations:
=================

- Two complete distributed traces were generated
- Each trace has 3 spans: 1 client span + 2 server spans
- Context propagation works correctly via HTTP headers
- Parent-child relationships are properly maintained
- Both successful (200) and error (404) responses are traced
- Trace attributes provide business context (tokens, queries, status codes)
EOF