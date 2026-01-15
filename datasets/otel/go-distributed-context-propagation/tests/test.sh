#!/bin/bash

echo "Running Go OpenTelemetry workflow tracing test..."

cd /workdir

# Check if go.mod has been updated with dependencies
echo "Checking Go module dependencies..."
if ! grep -q "go.opentelemetry.io/otel" go.mod; then
    echo "Warning: OpenTelemetry dependencies not found in go.mod"
fi

# Download dependencies
go mod tidy
if [ $? -ne 0 ]; then
    echo "Failed to download dependencies"
    echo 0 > /logs/verifier/reward.txt
    exit 1
fi

# Build the applications
echo "Building server..."
go build -o server server.go 2> server_build_error.txt
if [ $? -ne 0 ]; then
    echo "Server compilation failed"
    echo "Build errors:"
    cat server_build_error.txt
    echo ""
    echo "Server source code review:"
    echo "--- server.go (last 20 lines) ---"
    tail -20 server.go
    echo "--- End of server.go ---"
    echo 0 > /logs/verifier/reward.txt
    exit 1
fi
echo "✓ Server compiled successfully"

echo "Building client..."
go build -o client client.go 2> client_build_error.txt
if [ $? -ne 0 ]; then
    echo "Client compilation failed"
    echo "Build errors:"
    cat client_build_error.txt
    echo ""
    echo "Client source code review:"
    echo "--- client.go (last 20 lines) ---"
    tail -20 client.go
    echo "--- End of client.go ---"
    echo "Common issues:"
    echo "  1. Check for syntax errors in function calls"
    echo "  2. Verify all imported packages are used"
    echo "  3. Check OpenTelemetry API usage (span.SetAttributes vs trace.WithAttributes)"
    echo 0 > /logs/verifier/reward.txt
    exit 1
fi
echo "✓ Client compiled successfully"

# Download and start OpenTelemetry Collector
echo "Setting up OpenTelemetry Collector..."
COLLECTOR_VERSION="0.91.0"
wget -q https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${COLLECTOR_VERSION}/otelcol_${COLLECTOR_VERSION}_linux_amd64.tar.gz
tar -xzf otelcol_${COLLECTOR_VERSION}_linux_amd64.tar.gz

# Create collector config
cat > /workdir/collector-config.yaml <<EOF
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

# Start collector in background
echo "Starting OpenTelemetry Collector..."
./otelcol --config /workdir/collector-config.yaml > /workdir/collector_output.txt 2>&1 &
COLLECTOR_PID=$!
sleep 5

# Check if collector is running
if ! kill -0 $COLLECTOR_PID 2>/dev/null; then
    echo "Collector failed to start"
    cat /workdir/collector_output.txt
    echo "Continuing without collector to provide test feedback..."
    COLLECTOR_FAILED=1
else
    echo "✓ OpenTelemetry Collector started"
    COLLECTOR_FAILED=0
fi

# Check if port 8080 is already in use
if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Warning: Port 8080 is already in use, trying to free it..."
    # Try to kill any process using port 8080
    lsof -ti:8080 | xargs kill -9 2>/dev/null || true
    sleep 2
fi

# Start the server in background
echo "Starting server..."
./server > server_output.txt 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start"
    cat server_output.txt
    echo "Continuing to run tests to provide feedback..."
    SERVER_FAILED=1
else
    echo "✓ Server started successfully"
    SERVER_FAILED=0
fi

# Run the client
echo "Running client..."
./client > client_output.txt 2>&1
CLIENT_EXIT=$?

# Kill the server and collector
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

# Give collector time to flush traces
sleep 2

kill $COLLECTOR_PID 2>/dev/null
wait $COLLECTOR_PID 2>/dev/null

# Check client exit code
if [ $CLIENT_EXIT -ne 0 ]; then
    echo "Client execution failed"
    echo "Server output:"
    cat server_output.txt
    echo "Client output:"
    cat client_output.txt
    echo "Continuing to run tests to provide detailed feedback..."
fi

# Display outputs
echo "Server output:"
cat server_output.txt
echo ""
echo "Client output:"
cat client_output.txt

# Check if traces.json was created
if [ ! -f /workdir/traces.json ]; then
    echo "Warning: traces.json not found"
    echo "Creating empty traces.json for test framework..."
    echo "{}" > /workdir/traces.json
fi

echo "Running Python tests..."

# Install test dependencies and run tests
apt-get update > /dev/null 2>&1
apt-get install -y python3-pip curl > /dev/null 2>&1

# Install UV for Python testing
curl -LsSf https://astral.sh/uv/0.9.7/install.sh | sh > /dev/null 2>&1
source $HOME/.local/bin/env 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"

sleep 10

mkdir /logs/verifier/debug
cp -r /workdir/ /logs/verifier/debug/

# Run pytest with simple, reliable tests
if command -v uvx &> /dev/null; then
    uvx \
      --with pytest==8.4.1 \
      --with pytest-json-ctrf==0.3.5 \
      pytest --ctrf /logs/verifier/ctrf.json /tests/test_simple.py -v
else
    # Fallback to pip
    pip3 install pytest==8.4.1 pytest-json-ctrf==0.3.5
    python3 -m pytest --ctrf /logs/verifier/ctrf.json /tests/test_simple.py -v
fi

if [ $? -eq 0 ]; then
    echo 1 > /logs/verifier/reward.txt
    echo "Test completed successfully!"
else
    echo 0 > /logs/verifier/reward.txt
    echo "Test failed!"
fi