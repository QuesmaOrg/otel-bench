FROM php:8.2-cli-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    lsof \
    git \
    unzip \
    libzip-dev \
    libcurl4-openssl-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions
RUN docker-php-ext-install zip curl

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

WORKDIR /workdir

# Create composer.json (basic, without OpenTelemetry - agent will add those)
RUN cat > /workdir/composer.json << 'EOF'
{
    "name": "otel/distributed-tracing",
    "description": "OpenTelemetry distributed tracing example",
    "require": {
        "php": ">=8.2"
    },
    "autoload": {
        "psr-4": {
            "App\\": "src/"
        }
    }
}
EOF

# Create the server application
RUN cat > /workdir/server.php << 'SERVEREOF'
<?php

$tokenStore = [];

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
    global $tokenStore;

    $query = $params['q'] ?? 'default';
    fwrite(STDERR, "Search request received for query: $query\n");

    // Simulate processing
    usleep(50000);

    // Generate token
    $token = generateToken($query);

    // Store result (using file for persistence across requests)
    $storeFile = '/tmp/token_store.json';
    $store = file_exists($storeFile) ? json_decode(file_get_contents($storeFile), true) : [];
    $store[$token] = "Results for query: $query";
    file_put_contents($storeFile, json_encode($store));

    $response = [
        'token' => $token,
        'timestamp' => getTimestamp()
    ];

    sendJsonResponse(200, $response);
}

function handleResult(array $params): void {
    $token = $params['token'] ?? null;

    if (!$token) {
        sendTextResponse(400, 'Token required');
        return;
    }

    fwrite(STDERR, "Result request received for token: $token\n");

    // Simulate processing
    usleep(30000);

    // Read from persistent store
    $storeFile = '/tmp/token_store.json';
    $store = file_exists($storeFile) ? json_decode(file_get_contents($storeFile), true) : [];

    if (!isset($store[$token])) {
        sendTextResponse(404, 'Token not found');
        return;
    }

    $data = $store[$token];

    $response = [
        'data' => $data,
        'token' => $token,
        'timestamp' => getTimestamp()
    ];

    sendJsonResponse(200, $response);
}

// Simple routing
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$queryString = $_SERVER['QUERY_STRING'] ?? '';
parse_str($queryString, $params);

fwrite(STDERR, "Server starting on :8080\n");

if ($path === '/search') {
    handleSearch($params);
} elseif ($path === '/result') {
    handleResult($params);
} else {
    sendTextResponse(404, 'Not Found');
}
SERVEREOF

# Create the client application
RUN cat > /workdir/client.php << 'CLIENTEOF'
<?php

function httpGet(string $url): array {
    $context = stream_context_create([
        'http' => [
            'method' => 'GET',
            'header' => "Accept: application/json\r\n",
            'timeout' => 10,
            'ignore_errors' => true
        ]
    ]);

    $response = @file_get_contents($url, false, $context);

    // Get HTTP response code from headers
    $statusCode = 0;
    if (isset($http_response_header)) {
        foreach ($http_response_header as $header) {
            if (preg_match('/HTTP\/\d+\.?\d*\s+(\d+)/', $header, $matches)) {
                $statusCode = (int)$matches[1];
                break;
            }
        }
    }

    if ($response === false || $statusCode >= 400) {
        throw new Exception("HTTP request failed with status $statusCode");
    }

    return json_decode($response, true);
}

function main(): void {
    // Wait for server to start
    sleep(2);

    // Make search request
    echo "Making search request...\n";
    $searchResult = httpGet("http://localhost:8080/search?q=opentelemetry");
    $token = $searchResult['token'];
    echo "Received token: $token\n";

    // Make result request with token
    echo "Making result request...\n";
    $resultData = httpGet("http://localhost:8080/result?token=$token");
    echo "Received data: " . $resultData['data'] . "\n";
    echo "Client completed successfully\n";

    // Make second result request with invalid token
    echo "Making second result request with invalid token...\n";
    $invalidToken = $token . "0";
    try {
        $resultData = httpGet("http://localhost:8080/result?token=$invalidToken");
        echo "Received data: " . $resultData['data'] . "\n";
    } catch (Exception $e) {
        echo "Result request failed with status 404: Not Found\n";
    }
    echo "Client completed successfully\n";
}

main();
CLIENTEOF

# Make scripts readable
RUN chmod 644 /workdir/server.php /workdir/client.php

# Create a README
RUN cat > /workdir/README.md << 'EOF'
# OpenTelemetry PHP Distributed Context Propagation Task

This directory contains a distributed system consisting of:
- server.php: HTTP server with /search and /result endpoints
- client.php: HTTP client that performs a complete workflow
- composer.json: PHP dependencies (add OpenTelemetry dependencies)

## Your Goal

Understand the workflow and instrument both applications to create comprehensive tracing that shows:
1. The complete client workflow
2. Server-side processing
3. The relationship between operations
4. Distributed context propagation

## Running the applications

Without instrumentation:
```bash
# Install dependencies
composer install

# Start server (using PHP built-in server)
php -S localhost:8080 server.php

# Run client (in another terminal)
php client.php
```

With instrumentation:
- Add OpenTelemetry PHP SDK dependencies to composer.json
- Instrument both applications
- Export traces to /workdir/traces.json

## What to instrument

Think about:
- What operations are important to trace?
- How do the operations relate to each other?
- What attributes would help understand the system?
- How should context propagate between client and server?

The goal is not to create a specific number of spans, but to create meaningful tracing that provides insight into the distributed workflow.
EOF