#!/bin/bash
set -e

# Update composer.json with OpenTelemetry dependencies
cat > composer.json << 'EOF'
{
    "name": "otel/distributed-tracing",
    "description": "OpenTelemetry distributed tracing example",
    "require": {
        "php": ">=8.2",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "guzzlehttp/guzzle": "^7.0",
        "http-interop/http-factory-guzzle": "^1.0"
    },
    "autoload": {
        "psr-4": {
            "App\\": "src/"
        }
    }
}
EOF

# Install dependencies
composer install --no-interaction

# Create OpenTelemetry collector configuration
cat > otel-collector-config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317

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

# Create instrumented server.php with context propagation and file-based token storage
cat > server.php << 'PHPEOF'
<?php

require 'vendor/autoload.php';

use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\SDK\Trace\SpanProcessor\SimpleSpanProcessor;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\Context\Context;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SDK\Resource\ResourceInfoFactory;
use OpenTelemetry\SemConv\ResourceAttributes;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;

// Initialize OpenTelemetry
$resource = ResourceInfo::create(Attributes::create([
    ResourceAttributes::SERVICE_NAME => 'search-server',
]));

$transport = PsrTransportFactory::discover()->create('http://localhost:4318/v1/traces', 'application/json');
$exporter = new SpanExporter($transport);
$tracerProvider = TracerProvider::builder()
    ->addSpanProcessor(new SimpleSpanProcessor($exporter))
    ->setResource($resource)
    ->build();

$tracer = $tracerProvider->getTracer('search-server');
$propagator = TraceContextPropagator::getInstance();

define('TOKEN_STORE_FILE', '/tmp/token_store.json');

function loadTokenStore(): array {
    if (file_exists(TOKEN_STORE_FILE)) {
        $data = file_get_contents(TOKEN_STORE_FILE);
        return json_decode($data, true) ?: [];
    }
    return [];
}

function saveTokenStore(array $store): void {
    file_put_contents(TOKEN_STORE_FILE, json_encode($store));
}

function generateToken(string $query): string {
    $timestamp = (string) hrtime(true);
    $data = $query . $timestamp;
    return substr(hash('sha256', $data), 0, 16);
}

function getTimestamp(): string {
    return gmdate('Y-m-d\TH:i:s\Z');
}

function sendJsonResponse(int $status, array $data): void {
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($data);
}

function sendTextResponse(int $status, string $text): void {
    http_response_code($status);
    header('Content-Type: text/plain');
    echo $text;
}

function handleSearch(array $params): void {
    global $tracer, $propagator;

    // Extract context from HTTP headers
    $carrier = [];
    foreach ($_SERVER as $key => $value) {
        if (strpos($key, 'HTTP_') === 0) {
            $header = str_replace('HTTP_', '', $key);
            $header = str_replace('_', '-', $header);
            $carrier[strtolower($header)] = $value;
        }
    }
    
    $context = $propagator->extract($carrier);
    $scope = $context->activate();
    
    $span = $tracer->spanBuilder('POST /search')
        ->startSpan();
    $spanScope = $span->activate();

    $query = $params['q'] ?? 'default';
    $span->setAttribute('http.method', 'GET');
    $span->setAttribute('http.route', '/search');
    $span->setAttribute('search.query', $query);

    // Simulate processing
    usleep(50000);

    // Generate token
    $token = generateToken($query);

    // Store result
    $tokenStore = loadTokenStore();
    $tokenStore[$token] = "Results for query: $query";
    saveTokenStore($tokenStore);

    $response = [
        'token' => $token,
        'timestamp' => getTimestamp()
    ];

    sendJsonResponse(200, $response);
    
    $span->end();
    $spanScope->detach();
    $scope->detach();
}

function handleResult(array $params): void {
    global $tracer, $propagator;

    // Extract context from HTTP headers
    $carrier = [];
    foreach ($_SERVER as $key => $value) {
        if (strpos($key, 'HTTP_') === 0) {
            $header = str_replace('HTTP_', '', $key);
            $header = str_replace('_', '-', $header);
            $carrier[strtolower($header)] = $value;
        }
    }
    
    $context = $propagator->extract($carrier);
    $scope = $context->activate();
    
    $span = $tracer->spanBuilder('GET /result')
        ->startSpan();
    $spanScope = $span->activate();

    $token = $params['token'] ?? null;

    $span->setAttribute('http.method', 'GET');
    $span->setAttribute('http.route', '/result');
    if ($token) {
        $span->setAttribute('result.token', $token);
    }

    if (!$token) {
        $span->setAttribute('http.status_code', 400);
        sendTextResponse(400, 'Token required');
        $span->end();
        $spanScope->detach();
        $scope->detach();
        return;
    }

    // Simulate processing
    usleep(30000);

    $tokenStore = loadTokenStore();
    if (!isset($tokenStore[$token])) {
        $span->setAttribute('http.status_code', 404);
        sendTextResponse(404, 'Token not found');
        $span->end();
        $spanScope->detach();
        $scope->detach();
        return;
    }

    $data = $tokenStore[$token];

    $response = [
        'data' => $data,
        'token' => $token,
        'timestamp' => getTimestamp()
    ];

    $span->setAttribute('http.status_code', 200);
    sendJsonResponse(200, $response);
    
    $span->end();
    $spanScope->detach();
    $scope->detach();
}

// Simple routing
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$queryString = $_SERVER['QUERY_STRING'] ?? '';
parse_str($queryString, $params);

if ($path === '/search') {
    handleSearch($params);
} elseif ($path === '/result') {
    handleResult($params);
} else {
    sendTextResponse(404, 'Not Found');
}
PHPEOF

# Create instrumented client.php with context injection
cat > client.php << 'PHPEOF'
<?php

require 'vendor/autoload.php';

use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\SDK\Trace\SpanProcessor\SimpleSpanProcessor;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SemConv\ResourceAttributes;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;

// Initialize OpenTelemetry
$resource = ResourceInfo::create(Attributes::create([
    ResourceAttributes::SERVICE_NAME => 'search-client',
]));

$transport = PsrTransportFactory::discover()->create('http://localhost:4318/v1/traces', 'application/json');
$exporter = new SpanExporter($transport);
$tracerProvider = TracerProvider::builder()
    ->addSpanProcessor(new SimpleSpanProcessor($exporter))
    ->setResource($resource)
    ->build();

$tracer = $tracerProvider->getTracer('search-client');
$propagator = TraceContextPropagator::getInstance();

function httpGet(string $url, $tracer, $propagator): array {
    $span = $tracer->spanBuilder('HTTP GET')
        ->startSpan();
    $scope = $span->activate();
    
    $span->setAttribute('http.method', 'GET');
    $span->setAttribute('http.url', $url);
    
    // Inject trace context into HTTP headers
    $carrier = [];
    $propagator->inject($carrier);
    
    $headers = "Accept: application/json\r\n";
    foreach ($carrier as $key => $value) {
        $headers .= "$key: $value\r\n";
    }
    
    $context = stream_context_create([
        'http' => [
            'method' => 'GET',
            'header' => $headers,
            'timeout' => 10
        ]
    ]);

    $response = file_get_contents($url, false, $context);

    if ($response === false) {
        $span->setAttribute('error', true);
        $span->end();
        $scope->detach();
        throw new Exception("HTTP request failed");
    }
    
    $span->setAttribute('http.status_code', 200);
    $span->end();
    $scope->detach();

    return json_decode($response, true);
}

function main(): void {
    global $tracer, $propagator, $tracerProvider;
    
    // Wait for server to start
    sleep(2);

    // First workflow
    $workflowSpan = $tracer->spanBuilder('search-workflow')
        ->startSpan();
    $workflowScope = $workflowSpan->activate();

    // Make search request
    echo "Making search request...\n";
    $searchResult = httpGet("http://localhost:8080/search?q=opentelemetry", $tracer, $propagator);
    $token = $searchResult['token'];
    echo "Received token: $token\n";

    // Make result request with token
    echo "Making result request...\n";
    $resultData = httpGet("http://localhost:8080/result?token=$token", $tracer, $propagator);
    echo "Received data: " . $resultData['data'] . "\n";
    echo "Client completed successfully\n";
    
    $workflowSpan->end();
    $workflowScope->detach();

    // Second workflow - invalid token
    $workflow2Span = $tracer->spanBuilder('search-workflow-invalid')
        ->startSpan();
    $workflow2Scope = $workflow2Span->activate();
    
    // Make second result request with invalid token
    echo "Making second result request with invalid token...\n";
    $invalidToken = $token . "0";
    try {
        $resultData = httpGet("http://localhost:8080/result?token=$invalidToken", $tracer, $propagator);
        echo "Received data: " . $resultData['data'] . "\n";
    } catch (Exception $e) {
        echo "Result request failed: " . $e->getMessage() . "\n";
    }
    echo "Client completed successfully\n";
    
    $workflow2Span->end();
    $workflow2Scope->detach();
    
    $tracerProvider->shutdown();
}

main();
PHPEOF

# Download and setup OpenTelemetry Collector
wget -q https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.91.0/otelcol-contrib_0.91.0_linux_amd64.tar.gz
tar -xzf otelcol-contrib_0.91.0_linux_amd64.tar.gz
chmod +x otelcol-contrib

# Clear token store
rm -f /tmp/token_store.json

# Start OpenTelemetry Collector
./otelcol-contrib --config=otel-collector-config.yaml > collector_output.txt 2>&1 &
COLLECTOR_PID=$!

# Start PHP server
php -S localhost:8080 server.php > server_output.txt 2>&1 &
SERVER_PID=$!

# Run client
php client.php

# Wait for traces to be flushed
sleep 3

# Generate ASCII trace diagram
python3 << 'PYEOF' > traces.txt
import json

# Read traces
with open('traces.json', 'r') as f:
    lines = f.readlines()

traces = {}
for line in lines:
    data = json.loads(line)
    for rs in data.get('resourceSpans', []):
        service = rs['resource']['attributes'][0]['value']['stringValue']
        for ss in rs.get('scopeSpans', []):
            for span in ss.get('spans', []):
                trace_id = span['traceId']
                if trace_id not in traces:
                    traces[trace_id] = []
                span['service'] = service
                traces[trace_id].append(span)

# Find the two main traces from the final client run
main_traces = []
for tid, spans in traces.items():
    # Look for traces with workflow spans
    has_workflow = any('workflow' in s.get('name', '') for s in spans)
    if has_workflow:
        main_traces.append((tid, spans))

# Sort to get consistent order
main_traces.sort(key=lambda x: min(int(s['startTimeUnixNano']) for s in x[1]))

print("OpenTelemetry Distributed Tracing - PHP Application")
print("="*70)
print()

for idx, (trace_id, spans) in enumerate(main_traces[-2:], 1):
    print(f"Trace {idx}: {trace_id}")
    print("-"*70)
    
    # Build parent-child relationships
    span_map = {s['spanId']: s for s in spans}
    
    # Find root span
    root = None
    for s in spans:
        if not s.get('parentSpanId') or s['parentSpanId'] == '':
            root = s
            break
    
    def print_span(span, indent=0):
        service = span['service']
        name = span['name']
        duration_ns = int(span['endTimeUnixNano']) - int(span['startTimeUnixNano'])
        duration_ms = duration_ns / 1_000_000
        
        prefix = "  " * indent
        arrow = "└─" if indent > 0 else ""
        
        attrs = []
        for attr in span.get('attributes', []):
            key = attr['key']
            if key in ['http.method', 'http.route', 'http.url', 'http.status_code', 'search.query', 'result.token', 'error']:
                val = attr['value']
                if 'stringValue' in val:
                    attrs.append(f"{key}={val['stringValue']}")
                elif 'intValue' in val:
                    attrs.append(f"{key}={val['intValue']}")
                elif 'boolValue' in val:
                    attrs.append(f"{key}={val['boolValue']}")
        
        attr_str = ", ".join(attrs[:3]) if attrs else ""
        print(f"{prefix}{arrow}[{service}] {name} ({duration_ms:.2f}ms)")
        if attr_str:
            print(f"{prefix}  {attr_str}")
        
        # Find children
        children = [s for s in spans if s.get('parentSpanId') == span['spanId']]
        # Sort by start time
        children.sort(key=lambda x: int(x['startTimeUnixNano']))
        for child in children:
            print_span(child, indent + 1)
    
    if root:
        print_span(root)
    print()

print()
print("Trace Flow Diagram:")
print("="*70)
print()
print("Workflow 1: Successful Search and Result Retrieval")
print()
print("  Client (search-client)                Server (search-server)")
print("       |                                         |")
print("       |  search-workflow (root span)            |")
print("       |-------------------------------------->  |")
print("       |                                         |")
print("       |  HTTP GET /search?q=opentelemetry       |")
print("       |-------------------------------------->  |")
print("       |                                         |")
print("       |                          POST /search   |")
print("       |                          (generate token)|")
print("       |  <--------------------------------------| ")
print("       |  Response: {token: ...}                 |")
print("       |                                         |")
print("       |  HTTP GET /result?token=...             |")
print("       |-------------------------------------->  |")
print("       |                                         |")
print("       |                          GET /result    |")
print("       |                          (lookup token) |")
print("       |  <--------------------------------------| ")
print("       |  Response: {data: ...}                  |")
print("       |                                         |")
print()
print("Workflow 2: Invalid Token Request")
print()
print("  Client (search-client)                Server (search-server)")
print("       |                                         |")
print("       |  search-workflow-invalid (root span)    |")
print("       |-------------------------------------->  |")
print("       |                                         |")
print("       |  HTTP GET /result?token=invalid         |")
print("       |-------------------------------------->  |")
print("       |                                         |")
print("       |                          GET /result    |")
print("       |                          (404 Not Found)|")
print("       |  <--------------------------------------| ")
print("       |  Error: Token not found                 |")
print("       |                                         |")
print()
print("Key Observations:")
print("-" * 70)
print("1. Context Propagation: Trace context flows from client to server")
print("   via HTTP headers (traceparent), linking all spans in each trace.")
print()
print("2. Two Distinct Traces: Each workflow creates a separate trace with")
print("   its own trace ID, demonstrating independent transaction tracking.")
print()
print("3. Parent-Child Relationships: Server spans are children of client")
print("   HTTP request spans, showing the distributed nature of the calls.")
print()
print("4. Minimal Instrumentation: Only essential operations are traced:")
print("   - Workflow orchestration (client root spans)")
print("   - HTTP requests (client spans)")
print("   - Request handlers (server spans)")
print()
PYEOF

# Stop background processes
kill -9 $SERVER_PID $COLLECTOR_PID 2>/dev/null || true