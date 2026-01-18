#!/bin/bash
set -e

cat > stock/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.2",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "open-telemetry/transport-grpc": "^1.0",
        "php-http/guzzle7-adapter": "^1.0",
        "guzzlehttp/guzzle": "^7.9"
    },
    "autoload": {
        "psr-4": {
            "Stock\\": "src/"
        }
    }
}
EOF

mkdir -p stock/src

cat > stock/src/Telemetry.php << 'EOF'
<?php

declare(strict_types=1);

namespace Stock;

use Monolog\Handler\StreamHandler;
use Monolog\Level;
use Monolog\Logger;
use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Logs\LogRecord;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use OpenTelemetry\Context\Context;
use OpenTelemetry\Contrib\Otlp\LogsExporter;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;
use OpenTelemetry\SDK\Logs\LoggerProvider;
use OpenTelemetry\SDK\Logs\Processor\SimpleLogRecordProcessor;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SDK\Resource\ResourceInfoFactory;
use OpenTelemetry\SDK\Trace\Sampler\AlwaysOnSampler;
use OpenTelemetry\SDK\Trace\SpanProcessor\SimpleSpanProcessor;
use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\SemConv\ResourceAttributes;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Log\LoggerInterface;

class Telemetry
{
    private const SERVICE_NAME = 'stock-service';
    private static ?Telemetry $instance = null;
    private TracerProvider $tracerProvider;
    private LoggerProvider $loggerProvider;
    private LoggerInterface $logger;
    private string $otlpEndpoint;
    private bool $otelEnabled;

    private function __construct()
    {
        $this->otlpEndpoint = getenv('OTEL_EXPORTER_OTLP_ENDPOINT') ?: '';
        $this->otelEnabled = !empty($this->otlpEndpoint);
        
        $this->logger = new Logger(self::SERVICE_NAME);
        $this->logger->pushHandler(new StreamHandler('php://stderr', Level::Debug));
        
        $this->initializeOtel();
    }

    public static function getInstance(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function initializeOtel(): void
    {
        $resource = ResourceInfoFactory::defaultResource()->merge(
            ResourceInfo::create(Attributes::create([
                ResourceAttributes::SERVICE_NAME => self::SERVICE_NAME,
                ResourceAttributes::SERVICE_VERSION => '1.0.0',
            ]))
        );

        if ($this->otelEnabled) {
            $transportFactory = PsrTransportFactory::discover();
            
            // Traces
            $spanExporter = new SpanExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/traces', 'application/json')
            );
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->addSpanProcessor(new SimpleSpanProcessor($spanExporter))
                ->setSampler(new AlwaysOnSampler())
                ->build();

            // Logs
            $logsExporter = new LogsExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/logs', 'application/json')
            );
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->addLogRecordProcessor(new SimpleLogRecordProcessor($logsExporter))
                ->build();
        } else {
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->build();
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->build();
        }
    }

    public function getTracer(): \OpenTelemetry\API\Trace\TracerInterface
    {
        return $this->tracerProvider->getTracer(self::SERVICE_NAME);
    }

    public function getLogger(): LoggerInterface
    {
        return $this->logger;
    }

    public function logInfo(string $message, array $context = []): void
    {
        $this->logger->info($message, $context);
        $this->emitOtelLog($message, 'Info', $context);
    }

    public function logError(string $message, array $context = []): void
    {
        $this->logger->error($message, $context);
        $this->emitOtelLog($message, 'Error', $context);
    }

    private function emitOtelLog(string $message, string $severityText, array $context): void
    {
        if (!$this->otelEnabled) {
            return;
        }
        $otelLogger = $this->loggerProvider->getLogger(self::SERVICE_NAME);
        $record = (new LogRecord($message))
            ->setSeverityText($severityText)
            ->setAttributes($context);
        $otelLogger->emit($record);
    }

    public function logServiceStart(): void
    {
        $status = $this->otelEnabled 
            ? "OTEL instrumentation enabled, sending data to: {$this->otlpEndpoint}"
            : "OTEL instrumentation disabled (OTEL_EXPORTER_OTLP_ENDPOINT not set)";
        
        $this->logInfo(self::SERVICE_NAME . ' starting', [
            'service.name' => self::SERVICE_NAME,
            'otel.enabled' => $this->otelEnabled,
            'otel.endpoint' => $this->otlpEndpoint,
        ]);
        $this->logger->info($status);
    }

    public function logServiceStop(): void
    {
        $this->logInfo(self::SERVICE_NAME . ' stopping', [
            'service.name' => self::SERVICE_NAME,
        ]);
    }

    public function shutdown(): void
    {
        $this->logServiceStop();
        $this->tracerProvider->shutdown();
        $this->loggerProvider->shutdown();
    }

    public function createSpan(string $name, SpanKind $kind = SpanKind::KIND_INTERNAL): \OpenTelemetry\API\Trace\SpanInterface
    {
        return $this->getTracer()->spanBuilder($name)->setSpanKind($kind)->startSpan();
    }

    public function extractContext(Request $request): \OpenTelemetry\Context\ContextInterface
    {
        $carrier = [];
        foreach ($request->getHeaders() as $name => $values) {
            $carrier[strtolower($name)] = $values[0] ?? '';
        }
        return TraceContextPropagator::getInstance()->extract($carrier);
    }
}
EOF

cat > stock/public/index.php << 'ENDOFFILE'
<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;
use Stock\Telemetry;

$products = [
    'SKU001' => 100,
    'SKU002' => 50,
    'SKU003' => 200,
];

$telemetry = Telemetry::getInstance();
$telemetry->logServiceStart();

$app = AppFactory::create();
$app->addBodyParsingMiddleware();

$app->post('/check', function (Request $request, Response $response) use (&$products, $telemetry) {
    $parentContext = $telemetry->extractContext($request);
    $span = $telemetry->getTracer()
        ->spanBuilder('POST /check')
        ->setParent($parentContext)
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();

    try {
        $data = $request->getParsedBody();
        $sku = $data['sku'] ?? '';
        $quantity = (int)($data['quantity'] ?? 0);

        $span->setAttribute('stock.sku', $sku);
        $span->setAttribute('stock.quantity_requested', $quantity);

        $current = $products[$sku] ?? 0;
        $available = isset($products[$sku]) && $current >= $quantity;

        $span->setAttribute('stock.current', $current);
        $span->setAttribute('stock.available', $available);

        $telemetry->logInfo('Stock check performed', [
            'sku' => $sku,
            'quantity_requested' => $quantity,
            'current_stock' => $current,
            'available' => $available,
        ]);

        $span->setStatus(StatusCode::STATUS_OK);

        $response->getBody()->write(json_encode([
            'available' => $available,
            'current' => $current,
        ]));
        return $response->withHeader('Content-Type', 'application/json');
    } catch (\Throwable $e) {
        $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
        $span->recordException($e);
        $telemetry->logError('Stock check failed', ['error' => $e->getMessage()]);
        throw $e;
    } finally {
        $scope->detach();
        $span->end();
    }
});

$app->post('/decrease', function (Request $request, Response $response) use (&$products, $telemetry) {
    $parentContext = $telemetry->extractContext($request);
    $span = $telemetry->getTracer()
        ->spanBuilder('POST /decrease')
        ->setParent($parentContext)
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();

    try {
        $data = $request->getParsedBody();
        $sku = $data['sku'] ?? '';
        $quantity = (int)($data['quantity'] ?? 0);

        $span->setAttribute('stock.sku', $sku);
        $span->setAttribute('stock.quantity_requested', $quantity);

        $current = $products[$sku] ?? 0;
        $success = isset($products[$sku]) && $current >= $quantity;

        if ($success) {
            $products[$sku] = $current - $quantity;
            $current = $products[$sku];
        }

        $span->setAttribute('stock.current', $current);
        $span->setAttribute('stock.success', $success);

        $telemetry->logInfo('Stock decrease attempted', [
            'sku' => $sku,
            'quantity_requested' => $quantity,
            'current_stock' => $current,
            'success' => $success,
        ]);

        $span->setStatus(StatusCode::STATUS_OK);

        $response->getBody()->write(json_encode([
            'success' => $success,
            'current' => $current,
        ]));
        return $response->withHeader('Content-Type', 'application/json');
    } catch (\Throwable $e) {
        $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
        $span->recordException($e);
        $telemetry->logError('Stock decrease failed', ['error' => $e->getMessage()]);
        throw $e;
    } finally {
        $scope->detach();
        $span->end();
    }
});

$app->post('/increase', function (Request $request, Response $response) use (&$products, $telemetry) {
    $parentContext = $telemetry->extractContext($request);
    $span = $telemetry->getTracer()
        ->spanBuilder('POST /increase')
        ->setParent($parentContext)
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();

    try {
        $data = $request->getParsedBody();
        $sku = $data['sku'] ?? '';
        $quantity = (int)($data['quantity'] ?? 0);

        $span->setAttribute('stock.sku', $sku);
        $span->setAttribute('stock.quantity_requested', $quantity);

        $products[$sku] = ($products[$sku] ?? 0) + $quantity;
        $current = $products[$sku];

        $span->setAttribute('stock.current', $current);
        $span->setAttribute('stock.success', true);

        $telemetry->logInfo('Stock increase performed', [
            'sku' => $sku,
            'quantity_added' => $quantity,
            'current_stock' => $current,
        ]);

        $span->setStatus(StatusCode::STATUS_OK);

        $response->getBody()->write(json_encode([
            'success' => true,
            'current' => $current,
        ]));
        return $response->withHeader('Content-Type', 'application/json');
    } catch (\Throwable $e) {
        $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
        $span->recordException($e);
        $telemetry->logError('Stock increase failed', ['error' => $e->getMessage()]);
        throw $e;
    } finally {
        $scope->detach();
        $span->end();
    }
});

register_shutdown_function(function () use ($telemetry) {
    $telemetry->shutdown();
});

$app->run();
ENDOFFILE

cat > order/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.2",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "guzzlehttp/guzzle": "^7.9",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "open-telemetry/transport-grpc": "^1.0",
        "php-http/guzzle7-adapter": "^1.0"
    },
    "autoload": {
        "psr-4": {
            "Order\\": "src/"
        }
    }
}
EOF

mkdir -p order/src

cat > order/src/Telemetry.php << 'EOF'
<?php

declare(strict_types=1);

namespace Order;

use Monolog\Handler\StreamHandler;
use Monolog\Level;
use Monolog\Logger;
use OpenTelemetry\API\Logs\LogRecord;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use OpenTelemetry\Context\Context;
use OpenTelemetry\Contrib\Otlp\LogsExporter;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;
use OpenTelemetry\SDK\Logs\LoggerProvider;
use OpenTelemetry\SDK\Logs\Processor\SimpleLogRecordProcessor;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SDK\Resource\ResourceInfoFactory;
use OpenTelemetry\SDK\Trace\Sampler\AlwaysOnSampler;
use OpenTelemetry\SDK\Trace\SpanProcessor\SimpleSpanProcessor;
use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\SemConv\ResourceAttributes;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Log\LoggerInterface;

class Telemetry
{
    private const SERVICE_NAME = 'order-service';
    private static ?Telemetry $instance = null;
    private TracerProvider $tracerProvider;
    private LoggerProvider $loggerProvider;
    private LoggerInterface $logger;
    private string $otlpEndpoint;
    private bool $otelEnabled;

    private function __construct()
    {
        $this->otlpEndpoint = getenv('OTEL_EXPORTER_OTLP_ENDPOINT') ?: '';
        $this->otelEnabled = !empty($this->otlpEndpoint);

        $this->logger = new Logger(self::SERVICE_NAME);
        $this->logger->pushHandler(new StreamHandler('php://stderr', Level::Debug));

        $this->initializeOtel();
    }

    public static function getInstance(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function initializeOtel(): void
    {
        $resource = ResourceInfoFactory::defaultResource()->merge(
            ResourceInfo::create(Attributes::create([
                ResourceAttributes::SERVICE_NAME => self::SERVICE_NAME,
                ResourceAttributes::SERVICE_VERSION => '1.0.0',
            ]))
        );

        if ($this->otelEnabled) {
            $transportFactory = PsrTransportFactory::discover();

            $spanExporter = new SpanExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/traces', 'application/json')
            );
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->addSpanProcessor(new SimpleSpanProcessor($spanExporter))
                ->setSampler(new AlwaysOnSampler())
                ->build();

            $logsExporter = new LogsExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/logs', 'application/json')
            );
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->addLogRecordProcessor(new SimpleLogRecordProcessor($logsExporter))
                ->build();
        } else {
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->build();
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->build();
        }
    }

    public function getTracer(): \OpenTelemetry\API\Trace\TracerInterface
    {
        return $this->tracerProvider->getTracer(self::SERVICE_NAME);
    }

    public function getLogger(): LoggerInterface
    {
        return $this->logger;
    }

    public function logInfo(string $message, array $context = []): void
    {
        $this->logger->info($message, $context);
        $this->emitOtelLog($message, 'Info', $context);
    }

    public function logError(string $message, array $context = []): void
    {
        $this->logger->error($message, $context);
        $this->emitOtelLog($message, 'Error', $context);
    }

    private function emitOtelLog(string $message, string $severityText, array $context): void
    {
        if (!$this->otelEnabled) {
            return;
        }
        $otelLogger = $this->loggerProvider->getLogger(self::SERVICE_NAME);
        $record = (new LogRecord($message))
            ->setSeverityText($severityText)
            ->setAttributes($context);
        $otelLogger->emit($record);
    }

    public function logServiceStart(): void
    {
        $status = $this->otelEnabled
            ? "OTEL instrumentation enabled, sending data to: {$this->otlpEndpoint}"
            : "OTEL instrumentation disabled (OTEL_EXPORTER_OTLP_ENDPOINT not set)";

        $this->logInfo(self::SERVICE_NAME . ' starting', [
            'service.name' => self::SERVICE_NAME,
            'otel.enabled' => $this->otelEnabled,
            'otel.endpoint' => $this->otlpEndpoint,
        ]);
        $this->logger->info($status);
    }

    public function logServiceStop(): void
    {
        $this->logInfo(self::SERVICE_NAME . ' stopping', [
            'service.name' => self::SERVICE_NAME,
        ]);
    }

    public function shutdown(): void
    {
        $this->logServiceStop();
        $this->tracerProvider->shutdown();
        $this->loggerProvider->shutdown();
    }

    public function createSpan(string $name, SpanKind $kind = SpanKind::KIND_INTERNAL): \OpenTelemetry\API\Trace\SpanInterface
    {
        return $this->getTracer()->spanBuilder($name)->setSpanKind($kind)->startSpan();
    }

    public function extractContext(Request $request): \OpenTelemetry\Context\ContextInterface
    {
        $carrier = [];
        foreach ($request->getHeaders() as $name => $values) {
            $carrier[strtolower($name)] = $values[0] ?? '';
        }
        return TraceContextPropagator::getInstance()->extract($carrier);
    }

    public function injectContext(array &$headers): void
    {
        TraceContextPropagator::getInstance()->inject($headers);
    }
}
EOF

cat > order/public/index.php << 'EOF'
<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use GuzzleHttp\Client;
use GuzzleHttp\Exception\GuzzleException;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;
use Order\Telemetry;

$orders = [];
$orderCounter = 0;
$stockApiUrl = 'http://localhost:8081';
$httpClient = new Client();

$telemetry = Telemetry::getInstance();
$telemetry->logServiceStart();

$app = AppFactory::create();
$app->addBodyParsingMiddleware();

$app->post('/create', function (Request $request, Response $response) use (&$orders, &$orderCounter, $stockApiUrl, $httpClient, $telemetry) {
    $parentContext = $telemetry->extractContext($request);
    $span = $telemetry->getTracer()
        ->spanBuilder('POST /create')
        ->setParent($parentContext)
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();

    try {
        $data = $request->getParsedBody();
        $sku = $data['sku'] ?? '';
        $quantity = (int)($data['quantity'] ?? 0);
        $userId = $data['user_id'] ?? '';

        $span->setAttribute('order.sku', $sku);
        $span->setAttribute('order.quantity', $quantity);
        $span->setAttribute('order.user_id', $userId);

        // Create child span for stock service call
        $stockSpan = $telemetry->getTracer()
            ->spanBuilder('HTTP POST stock-service/decrease')
            ->setSpanKind(SpanKind::KIND_CLIENT)
            ->startSpan();
        $stockScope = $stockSpan->activate();

        try {
            $stockSpan->setAttribute('http.method', 'POST');
            $stockSpan->setAttribute('http.url', $stockApiUrl . '/decrease');
            $stockSpan->setAttribute('peer.service', 'stock-service');

            // Inject trace context into outgoing request headers
            $headers = [];
            TraceContextPropagator::getInstance()->inject($headers);

            $stockResponse = $httpClient->post($stockApiUrl . '/decrease', [
                'json' => ['sku' => $sku, 'quantity' => $quantity],
                'headers' => $headers,
            ]);
            $stockData = json_decode($stockResponse->getBody()->getContents(), true);

            $stockSpan->setAttribute('http.status_code', $stockResponse->getStatusCode());
            $stockSpan->setStatus(StatusCode::STATUS_OK);
        } catch (GuzzleException $e) {
            $stockSpan->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
            $stockSpan->recordException($e);

            $telemetry->logError('Stock service unavailable', [
                'error' => $e->getMessage(),
                'sku' => $sku,
            ]);

            $response->getBody()->write(json_encode([
                'success' => false,
                'error' => 'stock service unavailable',
            ]));
            $span->setStatus(StatusCode::STATUS_ERROR, 'stock service unavailable');
            return $response->withHeader('Content-Type', 'application/json');
        } finally {
            $stockScope->detach();
            $stockSpan->end();
        }

        if (!($stockData['success'] ?? false)) {
            $telemetry->logInfo('Order creation failed - insufficient stock', [
                'sku' => $sku,
                'quantity' => $quantity,
                'user_id' => $userId,
            ]);

            $response->getBody()->write(json_encode([
                'success' => false,
                'error' => 'insufficient stock',
            ]));
            $span->setStatus(StatusCode::STATUS_OK);
            return $response->withHeader('Content-Type', 'application/json');
        }

        $orderCounter++;
        $parcelNumber = 'PARCEL-' . $orderCounter;
        $orders[$parcelNumber] = [
            'sku' => $sku,
            'quantity' => $quantity,
            'user_id' => $userId,
        ];

        $span->setAttribute('order.parcel_number', $parcelNumber);
        $span->setAttribute('order.success', true);

        $telemetry->logInfo('Order created successfully', [
            'parcel_number' => $parcelNumber,
            'sku' => $sku,
            'quantity' => $quantity,
            'user_id' => $userId,
        ]);

        $span->setStatus(StatusCode::STATUS_OK);

        $response->getBody()->write(json_encode([
            'success' => true,
            'parcel_number' => $parcelNumber,
        ]));
        return $response->withHeader('Content-Type', 'application/json');
    } catch (\Throwable $e) {
        $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
        $span->recordException($e);
        $telemetry->logError('Order creation failed', ['error' => $e->getMessage()]);
        throw $e;
    } finally {
        $scope->detach();
        $span->end();
    }
});

register_shutdown_function(function () use ($telemetry) {
    $telemetry->shutdown();
});

$app->run();
EOF

cat > gateway/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.2",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "guzzlehttp/guzzle": "^7.9",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "open-telemetry/transport-grpc": "^1.0",
        "php-http/guzzle7-adapter": "^1.0"
    },
    "autoload": {
        "psr-4": {
            "Gateway\\": "src/"
        }
    }
}
EOF

mkdir -p gateway/src

cat > gateway/src/Telemetry.php << 'EOF'
<?php

declare(strict_types=1);

namespace Gateway;

use Monolog\Handler\StreamHandler;
use Monolog\Level;
use Monolog\Logger;
use OpenTelemetry\API\Logs\LogRecord;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use OpenTelemetry\Context\Context;
use OpenTelemetry\Contrib\Otlp\LogsExporter;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;
use OpenTelemetry\SDK\Logs\LoggerProvider;
use OpenTelemetry\SDK\Logs\Processor\SimpleLogRecordProcessor;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SDK\Resource\ResourceInfoFactory;
use OpenTelemetry\SDK\Trace\Sampler\AlwaysOnSampler;
use OpenTelemetry\SDK\Trace\SpanProcessor\SimpleSpanProcessor;
use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\SemConv\ResourceAttributes;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Log\LoggerInterface;

class Telemetry
{
    private const SERVICE_NAME = 'gateway-service';
    private static ?Telemetry $instance = null;
    private TracerProvider $tracerProvider;
    private LoggerProvider $loggerProvider;
    private LoggerInterface $logger;
    private string $otlpEndpoint;
    private bool $otelEnabled;

    private function __construct()
    {
        $this->otlpEndpoint = getenv('OTEL_EXPORTER_OTLP_ENDPOINT') ?: '';
        $this->otelEnabled = !empty($this->otlpEndpoint);

        $this->logger = new Logger(self::SERVICE_NAME);
        $this->logger->pushHandler(new StreamHandler('php://stderr', Level::Debug));

        $this->initializeOtel();
    }

    public static function getInstance(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function initializeOtel(): void
    {
        $resource = ResourceInfoFactory::defaultResource()->merge(
            ResourceInfo::create(Attributes::create([
                ResourceAttributes::SERVICE_NAME => self::SERVICE_NAME,
                ResourceAttributes::SERVICE_VERSION => '1.0.0',
            ]))
        );

        if ($this->otelEnabled) {
            $transportFactory = PsrTransportFactory::discover();

            $spanExporter = new SpanExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/traces', 'application/json')
            );
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->addSpanProcessor(new SimpleSpanProcessor($spanExporter))
                ->setSampler(new AlwaysOnSampler())
                ->build();

            $logsExporter = new LogsExporter(
                $transportFactory->create($this->otlpEndpoint . '/v1/logs', 'application/json')
            );
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->addLogRecordProcessor(new SimpleLogRecordProcessor($logsExporter))
                ->build();
        } else {
            $this->tracerProvider = TracerProvider::builder()
                ->setResource($resource)
                ->build();
            $this->loggerProvider = LoggerProvider::builder()
                ->setResource($resource)
                ->build();
        }
    }

    public function getTracer(): \OpenTelemetry\API\Trace\TracerInterface
    {
        return $this->tracerProvider->getTracer(self::SERVICE_NAME);
    }

    public function getLogger(): LoggerInterface
    {
        return $this->logger;
    }

    public function logInfo(string $message, array $context = []): void
    {
        $this->logger->info($message, $context);
        $this->emitOtelLog($message, 'Info', $context);
    }

    public function logError(string $message, array $context = []): void
    {
        $this->logger->error($message, $context);
        $this->emitOtelLog($message, 'Error', $context);
    }

    private function emitOtelLog(string $message, string $severityText, array $context): void
    {
        if (!$this->otelEnabled) {
            return;
        }
        $otelLogger = $this->loggerProvider->getLogger(self::SERVICE_NAME);
        $record = (new LogRecord($message))
            ->setSeverityText($severityText)
            ->setAttributes($context);
        $otelLogger->emit($record);
    }

    public function logServiceStart(): void
    {
        $status = $this->otelEnabled
            ? "OTEL instrumentation enabled, sending data to: {$this->otlpEndpoint}"
            : "OTEL instrumentation disabled (OTEL_EXPORTER_OTLP_ENDPOINT not set)";

        $this->logInfo(self::SERVICE_NAME . ' starting', [
            'service.name' => self::SERVICE_NAME,
            'otel.enabled' => $this->otelEnabled,
            'otel.endpoint' => $this->otlpEndpoint,
        ]);
        $this->logger->info($status);
    }

    public function logServiceStop(): void
    {
        $this->logInfo(self::SERVICE_NAME . ' stopping', [
            'service.name' => self::SERVICE_NAME,
        ]);
    }

    public function shutdown(): void
    {
        $this->logServiceStop();
        $this->tracerProvider->shutdown();
        $this->loggerProvider->shutdown();
    }

    public function createSpan(string $name, SpanKind $kind = SpanKind::KIND_INTERNAL): \OpenTelemetry\API\Trace\SpanInterface
    {
        return $this->getTracer()->spanBuilder($name)->setSpanKind($kind)->startSpan();
    }

    public function extractContext(Request $request): \OpenTelemetry\Context\ContextInterface
    {
        $carrier = [];
        foreach ($request->getHeaders() as $name => $values) {
            $carrier[strtolower($name)] = $values[0] ?? '';
        }
        return TraceContextPropagator::getInstance()->extract($carrier);
    }

    public function injectContext(array &$headers): void
    {
        TraceContextPropagator::getInstance()->inject($headers);
    }

    public function logHttpRequest(Request $request, int $statusCode, float $duration): void
    {
        $this->logInfo('HTTP Request', [
            'http.method' => $request->getMethod(),
            'http.url' => (string) $request->getUri(),
            'http.target' => $request->getUri()->getPath(),
            'http.status_code' => $statusCode,
            'http.user_agent' => $request->getHeaderLine('User-Agent'),
            'http.request_content_length' => $request->getHeaderLine('Content-Length') ?: '0',
            'http.duration_ms' => round($duration * 1000, 2),
            'net.peer.ip' => $request->getServerParams()['REMOTE_ADDR'] ?? '',
        ]);
    }
}
EOF

cat > gateway/public/index.php << 'EOF'
<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use GuzzleHttp\Client;
use GuzzleHttp\Exception\GuzzleException;
use OpenTelemetry\API\Trace\Propagation\TraceContextPropagator;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\RequestHandlerInterface as RequestHandler;
use Slim\Factory\AppFactory;
use Gateway\Telemetry;

$stockApiUrl = 'http://localhost:8081';
$orderApiUrl = 'http://localhost:8082';
$httpClient = new Client();

$telemetry = Telemetry::getInstance();
$telemetry->logServiceStart();

$app = AppFactory::create();
$app->addBodyParsingMiddleware();

// HTTP Request Logging Middleware
$app->add(function (Request $request, RequestHandler $handler) use ($telemetry) {
    $startTime = microtime(true);
    $response = $handler->handle($request);
    $duration = microtime(true) - $startTime;
    
    $telemetry->logHttpRequest($request, $response->getStatusCode(), $duration);
    
    return $response;
});

$app->post('/order', function (Request $request, Response $response) use ($stockApiUrl, $orderApiUrl, $httpClient, $telemetry) {
    $parentContext = $telemetry->extractContext($request);
    $span = $telemetry->getTracer()
        ->spanBuilder('POST /order')
        ->setParent($parentContext)
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();

    try {
        $data = $request->getParsedBody();
        $sku = $data['sku'] ?? '';
        $quantity = (int)($data['quantity'] ?? 0);
        $userId = $data['user_id'] ?? '';

        $span->setAttribute('order.sku', $sku);
        $span->setAttribute('order.quantity', $quantity);
        $span->setAttribute('order.user_id', $userId);

        // Check stock availability
        $stockCheckSpan = $telemetry->getTracer()
            ->spanBuilder('HTTP POST stock-service/check')
            ->setSpanKind(SpanKind::KIND_CLIENT)
            ->startSpan();
        $stockCheckScope = $stockCheckSpan->activate();

        try {
            $stockCheckSpan->setAttribute('http.method', 'POST');
            $stockCheckSpan->setAttribute('http.url', $stockApiUrl . '/check');
            $stockCheckSpan->setAttribute('peer.service', 'stock-service');

            $headers = [];
            TraceContextPropagator::getInstance()->inject($headers);

            $stockResponse = $httpClient->post($stockApiUrl . '/check', [
                'json' => ['sku' => $sku, 'quantity' => $quantity],
                'headers' => $headers,
            ]);
            $stockData = json_decode($stockResponse->getBody()->getContents(), true);

            $stockCheckSpan->setAttribute('http.status_code', $stockResponse->getStatusCode());
            $stockCheckSpan->setStatus(StatusCode::STATUS_OK);
        } catch (GuzzleException $e) {
            $stockCheckSpan->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
            $stockCheckSpan->recordException($e);

            $telemetry->logError('Stock service unavailable', [
                'error' => $e->getMessage(),
                'operation' => 'check',
            ]);

            $response->getBody()->write(json_encode([
                'success' => false,
                'error' => 'stock service unavailable',
            ]));
            $span->setStatus(StatusCode::STATUS_ERROR, 'stock service unavailable');
            return $response->withHeader('Content-Type', 'application/json');
        } finally {
            $stockCheckScope->detach();
            $stockCheckSpan->end();
        }

        if (!($stockData['available'] ?? false)) {
            $telemetry->logInfo('Order rejected - product not available', [
                'sku' => $sku,
                'quantity' => $quantity,
                'current_stock' => $stockData['current'] ?? 0,
            ]);

            $response->getBody()->write(json_encode([
                'success' => false,
                'error' => 'product not available',
            ]));
            $span->setStatus(StatusCode::STATUS_OK);
            return $response->withHeader('Content-Type', 'application/json');
        }

        // Create order
        $orderSpan = $telemetry->getTracer()
            ->spanBuilder('HTTP POST order-service/create')
            ->setSpanKind(SpanKind::KIND_CLIENT)
            ->startSpan();
        $orderScope = $orderSpan->activate();

        try {
            $orderSpan->setAttribute('http.method', 'POST');
            $orderSpan->setAttribute('http.url', $orderApiUrl . '/create');
            $orderSpan->setAttribute('peer.service', 'order-service');

            $headers = [];
            TraceContextPropagator::getInstance()->inject($headers);

            $orderResponse = $httpClient->post($orderApiUrl . '/create', [
                'json' => ['sku' => $sku, 'quantity' => $quantity, 'user_id' => $userId],
                'headers' => $headers,
            ]);
            $orderData = json_decode($orderResponse->getBody()->getContents(), true);

            $orderSpan->setAttribute('http.status_code', $orderResponse->getStatusCode());
            $orderSpan->setStatus(StatusCode::STATUS_OK);
        } catch (GuzzleException $e) {
            $orderSpan->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
            $orderSpan->recordException($e);

            $telemetry->logError('Order service unavailable', [
                'error' => $e->getMessage(),
            ]);

            $response->getBody()->write(json_encode([
                'success' => false,
                'error' => 'order service unavailable',
            ]));
            $span->setStatus(StatusCode::STATUS_ERROR, 'order service unavailable');
            return $response->withHeader('Content-Type', 'application/json');
        } finally {
            $orderScope->detach();
            $orderSpan->end();
        }

        if ($orderData['success'] ?? false) {
            $span->setAttribute('order.parcel_number', $orderData['parcel_number'] ?? '');
            $telemetry->logInfo('Order completed successfully', [
                'parcel_number' => $orderData['parcel_number'] ?? '',
                'sku' => $sku,
                'quantity' => $quantity,
                'user_id' => $userId,
            ]);
        }

        $span->setStatus(StatusCode::STATUS_OK);

        $response->getBody()->write(json_encode($orderData));
        return $response->withHeader('Content-Type', 'application/json');
    } catch (\Throwable $e) {
        $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
        $span->recordException($e);
        $telemetry->logError('Order processing failed', ['error' => $e->getMessage()]);
        throw $e;
    } finally {
        $scope->detach();
        $span->end();
    }
});

register_shutdown_function(function () use ($telemetry) {
    $telemetry->shutdown();
});

$app->run();
EOF

cat > stock/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.1",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "php-http/guzzle7-adapter": "^1.0",
        "guzzlehttp/guzzle": "^7.9"
    },
    "autoload": {
        "psr-4": {
            "Stock\\": "src/"
        }
    }
}
EOF

cat > order/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.1",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "guzzlehttp/guzzle": "^7.9",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "php-http/guzzle7-adapter": "^1.0"
    },
    "autoload": {
        "psr-4": {
            "Order\\": "src/"
        }
    }
}
EOF

cat > gateway/composer.json << 'EOF'
{
    "require": {
        "php": ">=8.1",
        "slim/slim": "^4.14",
        "slim/psr7": "^1.7",
        "php-di/php-di": "^7.0",
        "guzzlehttp/guzzle": "^7.9",
        "monolog/monolog": "^3.5",
        "open-telemetry/sdk": "^1.0",
        "open-telemetry/exporter-otlp": "^1.0",
        "php-http/guzzle7-adapter": "^1.0"
    },
    "autoload": {
        "psr-4": {
            "Gateway\\": "src/"
        }
    }
}
EOF

cd /workdir/stock && composer install --no-interaction 2>&1

cd /workdir/order && composer install --no-interaction 2>&1

cd /workdir/gateway && composer install --no-interaction 2>&1

sleep 2 && make test 2>&1
