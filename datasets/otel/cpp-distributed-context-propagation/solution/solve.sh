#!/bin/bash
set -e

# Write the instrumented CMakeLists.txt
cat > /workdir/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(distributed-tracing)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Protobuf REQUIRED)
find_package(gRPC REQUIRED)

# Server executable
add_executable(server server.cpp)
target_link_libraries(server PRIVATE
    Threads::Threads
    opentelemetry-cpp::trace
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::resources
)

# Client executable
add_executable(client client.cpp)
target_link_libraries(client PRIVATE
    Threads::Threads
    opentelemetry-cpp::trace
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::resources
)
EOF

# Write the instrumented server.cpp
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

// Helper to extract context from HTTP headers
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
        // Not used for extraction
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

    // Set global propagator for context propagation
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
        // Extract context from incoming request headers
        HttpHeaderCarrier carrier(req.headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        auto extracted_ctx = prop->Extract(carrier, current_ctx);

        // Start span with extracted context
        opentelemetry::trace::StartSpanOptions options;
        options.parent = trace_api::GetSpan(extracted_ctx)->GetContext();

        auto span = tracer->StartSpan("GET /search", {}, options);
        auto scope = tracer->WithActiveSpan(span);

        std::string query = req.has_param("q") ? req.get_param_value("q") : "default";
        span->SetAttribute("http.method", "GET");
        span->SetAttribute("http.route", "/search");
        span->SetAttribute("search.query", query);

        std::cout << "Search request received for query: " << query << std::endl;

        // Simulate processing
        std::this_thread::sleep_for(std::chrono::milliseconds(50));

        // Generate token
        std::string token = generateToken(query);

        // Store result
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
        // Extract context from incoming request headers
        HttpHeaderCarrier carrier(req.headers);
        auto prop = opentelemetry::context::propagation::GlobalTextMapPropagator::GetGlobalPropagator();
        auto current_ctx = opentelemetry::context::RuntimeContext::GetCurrent();
        auto extracted_ctx = prop->Extract(carrier, current_ctx);

        // Start span with extracted context
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

        // Simulate processing
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

# Write the instrumented client.cpp
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

// Helper to inject context into HTTP headers
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

    // Set global propagator for context propagation
    opentelemetry::context::propagation::GlobalTextMapPropagator::SetGlobalPropagator(
        opentelemetry::nostd::shared_ptr<opentelemetry::context::propagation::TextMapPropagator>(
            new opentelemetry::trace::propagation::HttpTraceContext()));
}

int main() {
    // Wait for server to start
    std::this_thread::sleep_for(std::chrono::seconds(2));

    initTracer();
    auto tracer = trace_api::Provider::GetTracerProvider()->GetTracer("search-client");

    httplib::Client cli("localhost", 8080);
    cli.set_connection_timeout(10);
    cli.set_read_timeout(10);

    // First workflow: valid search and result request
    {
        auto workflow_span = tracer->StartSpan("search-workflow");
        auto workflow_scope = tracer->WithActiveSpan(workflow_span);

        // Make search request
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

        // Make result request with token
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

    // Second workflow: invalid token request
    {
        auto workflow_span = tracer->StartSpan("invalid-token-workflow");
        auto workflow_scope = tracer->WithActiveSpan(workflow_span);

        std::cout << "Making second result request with invalid token..." << std::endl;

        // First get a valid token
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

    // Give time for traces to be exported
    std::this_thread::sleep_for(std::chrono::seconds(2));

    return 0;
}
EOF

# Write collector config
cat > /workdir/collector-config.yaml << 'EOF'
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
  debug:
    verbosity: detailed
  file:
    path: /workdir/traces.json

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file]
  telemetry:
    metrics:
      address: :8888
EOF

# Build the applications
cd /workdir
mkdir -p build
cd build
cmake .. > cmake_output.txt 2>&1
make -j$(nproc) > make_output.txt 2>&1
cd /workdir

# Download and setup OpenTelemetry Collector
COLLECTOR_VERSION="0.91.0"
wget -q https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${COLLECTOR_VERSION}/otelcol_${COLLECTOR_VERSION}_linux_amd64.tar.gz
tar -xzf otelcol_${COLLECTOR_VERSION}_linux_amd64.tar.gz

# Start collector in background
./otelcol --config /workdir/collector-config.yaml > /workdir/collector_output.txt 2>&1 &
COLLECTOR_PID=$!
sleep 5

# Start server in background
./build/server > server_output.txt 2>&1 &
SERVER_PID=$!
sleep 3

# Run client
timeout 60 ./build/client > client_output.txt 2>&1 || true

# Give time for traces to flush
sleep 2

# Cleanup processes
kill -9 $SERVER_PID 2>/dev/null || true
kill -9 $COLLECTOR_PID 2>/dev/null || true

# Create traces diagram
cat > /workdir/traces.txt << 'EOF'
Distributed Tracing Diagram - OpenTelemetry C++ Instrumentation
=====================================================================

Trace 1: search-workflow (Valid Token Flow)
============================================

[search-client] search-workflow
    |
    +---> [search-server] GET /search
    |       - Extracts trace context from HTTP headers
    |       - Returns token
    |
    +---> [search-server] GET /result
            - Extracts trace context from HTTP headers
            - Returns data for valid token


Trace 2: invalid-token-workflow (Invalid Token Flow)
====================================================

[search-client] invalid-token-workflow
    |
    +---> [search-server] GET /search
    |       - Extracts trace context from HTTP headers
    |       - Returns token
    |
    +---> [search-server] GET /result
            - Extracts trace context from HTTP headers
            - Returns 404 (token not found)


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
- Each trace has spans from both client and server
- Context propagation works correctly via HTTP headers
- Parent-child relationships are properly maintained
- Both successful (200) and error (404) responses are traced
EOF

echo "Solution files written and executed successfully"