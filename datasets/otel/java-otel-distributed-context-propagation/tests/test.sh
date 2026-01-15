#!/bin/bash

echo "Running Java OpenTelemetry workflow tracing test..."

cd /workdir

# Verify Java is available
if ! command -v java &> /dev/null; then
    echo "ERROR: java not found in PATH"
    echo 0 > /logs/verifier/reward.txt
    exit 1
fi

echo "Using Java: $(java -version 2>&1 | head -1)"
echo "Using Maven: $(mvn -version 2>&1 | head -1)"

# Check if pom.xml has OpenTelemetry
echo "Checking pom.xml configuration..."
if ! grep -qi "opentelemetry" pom.xml; then
    echo "Warning: OpenTelemetry not found in pom.xml"
fi

# Build the applications
echo "Building applications with Maven..."
mvn clean package -DskipTests > maven_output.txt 2>&1
if [ $? -ne 0 ]; then
    echo "Build failed"
    echo "Maven output:"
    cat maven_output.txt
    echo ""
    echo "Server source code review:"
    echo "--- Server.java (last 30 lines) ---"
    tail -30 /workdir/src/main/java/com/example/Server.java
    echo "--- End of Server.java ---"
    echo 0 > /logs/verifier/reward.txt
    exit 1
fi
echo "Build successful"

# Kill any existing processes using collector ports
echo "Cleaning up any existing processes on collector ports..."
for port in 4317 4318 8888 8080; do
    if command -v lsof &> /dev/null; then
        lsof -ti:$port | xargs kill -9 2>/dev/null || true
    fi
    # Also try fuser as fallback
    if command -v fuser &> /dev/null; then
        fuser -k $port/tcp 2>/dev/null || true
    fi
done
sleep 2

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
    echo "WARNING: Continuing without collector - traces may not be captured"
    COLLECTOR_FAILED=1
else
    echo "OpenTelemetry Collector started"
    COLLECTOR_FAILED=0
fi

# Check if port 8080 is already in use
if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Warning: Port 8080 is already in use, trying to free it..."
    # Try to kill any process using port 8080
    lsof -ti:8080 | xargs kill -9 2>/dev/null || true
    sleep 2
fi

# Build classpath
CLASSPATH="target/classes"
for jar in target/lib/*.jar; do
    if [ -f "$jar" ]; then
        CLASSPATH="$CLASSPATH:$jar"
    fi
done
echo "Using classpath: $CLASSPATH"

# Start the server in background
echo "Starting server..."
java -cp "$CLASSPATH" com.example.Server > server_output.txt 2>&1 &
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
    echo "Server started successfully"
    SERVER_FAILED=0
fi

# Run the client with timeout to prevent hanging on tracer shutdown
echo "Running client..."
timeout 60 java -cp "$CLASSPATH" com.example.Client > client_output.txt 2>&1
CLIENT_EXIT=$?

if [ $CLIENT_EXIT -eq 124 ]; then
    echo "WARNING: Client timed out after 60 seconds"
fi

# Kill the server
echo "Stopping server..."
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

mkdir -p /logs/verifier/debug
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