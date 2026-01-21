#!/bin/bash
set -e

cat > /workdir/gateway/package.json << 'EOF'
{
  "name": "gateway",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node --import ./instrumentation.js index.js"
  },
  "dependencies": {
    "express": "^4.21.0",
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/sdk-node": "^0.53.0",
    "@opentelemetry/auto-instrumentations-node": "^0.50.0",
    "@opentelemetry/exporter-trace-otlp-http": "^0.53.0",
    "@opentelemetry/exporter-logs-otlp-http": "^0.53.0",
    "@opentelemetry/sdk-logs": "^0.53.0",
    "@opentelemetry/api-logs": "^0.53.0",
    "@opentelemetry/instrumentation": "^0.53.0"
  }
}
EOF

cat > /workdir/gateway/instrumentation.js << 'EOF'
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';
import {
  LoggerProvider,
  BatchLogRecordProcessor,
  ConsoleLogRecordExporter,
} from '@opentelemetry/sdk-logs';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';

// Set diagnostic logging to error level to avoid noise
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

const otlpEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

console.log('='.repeat(60));
console.log('OTEL Instrumentation: ENABLED');
console.log(`Service: gateway`);
console.log(`OTEL Endpoint: ${otlpEndpoint}`);
console.log(`Tracing: ${otlpEndpoint}/v1/traces`);
console.log(`Logging: ${otlpEndpoint}/v1/logs`);
console.log('='.repeat(60));

// Configure resource
const resource = new Resource({
  [ATTR_SERVICE_NAME]: 'gateway',
  [ATTR_SERVICE_VERSION]: '1.0.0',
});

// Configure trace exporter with timeout and error handling
const traceExporter = new OTLPTraceExporter({
  url: `${otlpEndpoint}/v1/traces`,
  timeoutMillis: 5000,
});

// Configure log exporter
const logExporter = new OTLPLogExporter({
  url: `${otlpEndpoint}/v1/logs`,
  timeoutMillis: 5000,
});

// Initialize Logger Provider
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(logExporter));

// Also add console exporter for local debugging if needed
// loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(new ConsoleLogRecordExporter()));

// Initialize SDK
const sdk = new NodeSDK({
  resource,
  traceExporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': {
        enabled: false,
      },
    }),
  ],
});

// Handle SDK startup errors gracefully
try {
  sdk.start();
  console.log('OTEL SDK started successfully');
} catch (error) {
  console.error('Failed to start OTEL SDK:', error.message);
  console.log('Service will continue without OTEL instrumentation');
}

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk
    .shutdown()
    .then(() => {
      console.log('OTEL SDK shut down successfully');
      process.exit(0);
    })
    .catch((error) => {
      console.error('Error shutting down OTEL SDK:', error);
      process.exit(1);
    });
});

export { loggerProvider };
EOF

cat > /workdir/gateway/index.js << 'EOF'
import express from 'express';
import { trace, context } from '@opentelemetry/api';
import { logs } from '@opentelemetry/api-logs';
import { loggerProvider } from './instrumentation.js';

const app = express();
app.use(express.json());

const stockApiUrl = 'http://localhost:8081';
const orderApiUrl = 'http://localhost:8082';

// Get logger for application logs
const logger = loggerProvider.getLogger('gateway', '1.0.0');
const tracer = trace.getTracer('gateway', '1.0.0');

// Helper function to emit logs
function emitLog(level, message, attributes = {}) {
  const logRecord = {
    severityText: level,
    body: message,
    attributes,
  };
  logger.emit(logRecord);
}

// Request logging middleware
app.use((req, res, next) => {
  const startTime = Date.now();
  
  res.on('finish', () => {
    const duration = Date.now() - startTime;
    const logAttributes = {
      'http.method': req.method,
      'http.url': req.url,
      'http.status_code': res.statusCode,
      'http.duration_ms': duration,
      'http.user_agent': req.get('user-agent') || '',
      'http.client_ip': req.ip,
    };
    
    emitLog('INFO', `${req.method} ${req.url} ${res.statusCode} ${duration}ms`, logAttributes);
  });
  
  next();
});

async function checkStock(sku, quantity) {
  const span = tracer.startSpan('check_stock', {
    attributes: {
      'stock.sku': sku,
      'stock.quantity': quantity,
    },
  });
  
  try {
    emitLog('INFO', 'Checking stock availability', {
      'stock.sku': sku,
      'stock.quantity': quantity,
    });
    
    const response = await fetch(`${stockApiUrl}/check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sku, quantity }),
    });
    
    const result = await response.json();
    span.setAttribute('stock.available', result.available);
    span.setAttribute('stock.current', result.current);
    
    emitLog('INFO', 'Stock check completed', {
      'stock.sku': sku,
      'stock.available': result.available,
      'stock.current': result.current,
    });
    
    span.end();
    return result;
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Stock check failed', {
      'stock.sku': sku,
      'error.message': error.message,
    });
    
    throw error;
  }
}

async function createOrder(sku, quantity, userId) {
  const span = tracer.startSpan('create_order', {
    attributes: {
      'order.sku': sku,
      'order.quantity': quantity,
      'order.user_id': userId,
    },
  });
  
  try {
    emitLog('INFO', 'Creating order', {
      'order.sku': sku,
      'order.quantity': quantity,
      'order.user_id': userId,
    });
    
    const response = await fetch(`${orderApiUrl}/create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sku, quantity, user_id: userId }),
    });
    
    const result = await response.json();
    span.setAttribute('order.success', result.success);
    if (result.parcel_number) {
      span.setAttribute('order.parcel_number', result.parcel_number);
    }
    
    emitLog('INFO', 'Order creation completed', {
      'order.sku': sku,
      'order.success': result.success,
      'order.parcel_number': result.parcel_number || '',
    });
    
    span.end();
    return result;
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Order creation failed', {
      'order.sku': sku,
      'error.message': error.message,
    });
    
    throw error;
  }
}

app.post('/order', async (req, res) => {
  const { sku, quantity, user_id } = req.body;
  
  const span = tracer.startSpan('process_order_request', {
    attributes: {
      'request.sku': sku,
      'request.quantity': quantity,
      'request.user_id': user_id,
    },
  });
  
  try {
    emitLog('INFO', 'Processing order request', {
      'request.sku': sku,
      'request.quantity': quantity,
      'request.user_id': user_id,
    });
    
    let stockResp;
    try {
      stockResp = await checkStock(sku, quantity);
    } catch {
      span.setAttribute('error.type', 'stock_service_unavailable');
      span.end();
      return res.json({ success: false, error: 'stock service unavailable' });
    }
    
    if (!stockResp.available) {
      span.setAttribute('error.type', 'product_not_available');
      emitLog('WARN', 'Product not available', {
        'request.sku': sku,
        'request.quantity': quantity,
      });
      span.end();
      return res.json({ success: false, error: 'product not available' });
    }
    
    let orderResp;
    try {
      orderResp = await createOrder(sku, quantity, user_id);
    } catch {
      span.setAttribute('error.type', 'order_service_unavailable');
      span.end();
      return res.json({ success: false, error: 'order service unavailable' });
    }
    
    span.setAttribute('response.success', orderResp.success);
    span.end();
    res.json(orderResp);
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Unexpected error processing order', {
      'error.message': error.message,
    });
    
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

const server = app.listen(8080, '127.0.0.1', () => {
  console.log('Gateway service running on port 8080');
  emitLog('INFO', 'Gateway service started', {
    'service.name': 'gateway',
    'service.port': 8080,
    'service.host': '127.0.0.1',
  });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Received SIGTERM, shutting down gracefully');
  emitLog('INFO', 'Gateway service shutting down', {
    'service.name': 'gateway',
  });
  
  server.close(() => {
    console.log('Gateway service stopped');
    emitLog('INFO', 'Gateway service stopped', {
      'service.name': 'gateway',
    });
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('Received SIGINT, shutting down gracefully');
  emitLog('INFO', 'Gateway service shutting down', {
    'service.name': 'gateway',
  });
  
  server.close(() => {
    console.log('Gateway service stopped');
    emitLog('INFO', 'Gateway service stopped', {
      'service.name': 'gateway',
    });
    process.exit(0);
  });
});
EOF

cat > /workdir/order/package.json << 'EOF'
{
  "name": "order",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node --import ./instrumentation.js index.js"
  },
  "dependencies": {
    "express": "^4.21.0",
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/sdk-node": "^0.53.0",
    "@opentelemetry/auto-instrumentations-node": "^0.50.0",
    "@opentelemetry/exporter-trace-otlp-http": "^0.53.0",
    "@opentelemetry/exporter-logs-otlp-http": "^0.53.0",
    "@opentelemetry/sdk-logs": "^0.53.0",
    "@opentelemetry/api-logs": "^0.53.0",
    "@opentelemetry/instrumentation": "^0.53.0"
  }
}
EOF

cat > /workdir/order/instrumentation.js << 'EOF'
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';
import {
  LoggerProvider,
  BatchLogRecordProcessor,
  ConsoleLogRecordExporter,
} from '@opentelemetry/sdk-logs';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';

// Set diagnostic logging to error level to avoid noise
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

const otlpEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

console.log('='.repeat(60));
console.log('OTEL Instrumentation: ENABLED');
console.log(`Service: order`);
console.log(`OTEL Endpoint: ${otlpEndpoint}`);
console.log(`Tracing: ${otlpEndpoint}/v1/traces`);
console.log(`Logging: ${otlpEndpoint}/v1/logs`);
console.log('='.repeat(60));

// Configure resource
const resource = new Resource({
  [ATTR_SERVICE_NAME]: 'order',
  [ATTR_SERVICE_VERSION]: '1.0.0',
});

// Configure trace exporter with timeout and error handling
const traceExporter = new OTLPTraceExporter({
  url: `${otlpEndpoint}/v1/traces`,
  timeoutMillis: 5000,
});

// Configure log exporter
const logExporter = new OTLPLogExporter({
  url: `${otlpEndpoint}/v1/logs`,
  timeoutMillis: 5000,
});

// Initialize Logger Provider
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(logExporter));

// Initialize SDK
const sdk = new NodeSDK({
  resource,
  traceExporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': {
        enabled: false,
      },
    }),
  ],
});

// Handle SDK startup errors gracefully
try {
  sdk.start();
  console.log('OTEL SDK started successfully');
} catch (error) {
  console.error('Failed to start OTEL SDK:', error.message);
  console.log('Service will continue without OTEL instrumentation');
}

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk
    .shutdown()
    .then(() => {
      console.log('OTEL SDK shut down successfully');
      process.exit(0);
    })
    .catch((error) => {
      console.error('Error shutting down OTEL SDK:', error);
      process.exit(1);
    });
});

export { loggerProvider };
EOF

cat > /workdir/order/index.js << 'EOF'
import express from 'express';
import { trace, context } from '@opentelemetry/api';
import { logs } from '@opentelemetry/api-logs';
import { loggerProvider } from './instrumentation.js';

const app = express();
app.use(express.json());

const orders = new Map();
let orderCounter = 0;
const stockApiUrl = 'http://localhost:8081';

// Get logger for application logs
const logger = loggerProvider.getLogger('order', '1.0.0');
const tracer = trace.getTracer('order', '1.0.0');

// Helper function to emit logs
function emitLog(level, message, attributes = {}) {
  const logRecord = {
    severityText: level,
    body: message,
    attributes,
  };
  logger.emit(logRecord);
}

// Request logging middleware
app.use((req, res, next) => {
  const startTime = Date.now();
  
  res.on('finish', () => {
    const duration = Date.now() - startTime;
    const logAttributes = {
      'http.method': req.method,
      'http.url': req.url,
      'http.status_code': res.statusCode,
      'http.duration_ms': duration,
      'http.user_agent': req.get('user-agent') || '',
      'http.client_ip': req.ip,
    };
    
    emitLog('INFO', `${req.method} ${req.url} ${res.statusCode} ${duration}ms`, logAttributes);
  });
  
  next();
});

async function decreaseStock(sku, quantity) {
  const span = tracer.startSpan('decrease_stock', {
    attributes: {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.operation': 'decrease',
    },
  });
  
  try {
    emitLog('INFO', 'Decreasing stock', {
      'stock.sku': sku,
      'stock.quantity': quantity,
    });
    
    const response = await fetch(`${stockApiUrl}/decrease`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sku, quantity }),
    });
    
    const result = await response.json();
    span.setAttribute('stock.success', result.success);
    span.setAttribute('stock.current', result.current);
    
    emitLog('INFO', 'Stock decrease completed', {
      'stock.sku': sku,
      'stock.success': result.success,
      'stock.current': result.current,
    });
    
    span.end();
    return result;
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Stock decrease failed', {
      'stock.sku': sku,
      'error.message': error.message,
    });
    
    throw error;
  }
}

app.post('/create', async (req, res) => {
  const { sku, quantity, user_id } = req.body;
  
  const span = tracer.startSpan('create_order', {
    attributes: {
      'order.sku': sku,
      'order.quantity': quantity,
      'order.user_id': user_id,
    },
  });
  
  try {
    emitLog('INFO', 'Creating order', {
      'order.sku': sku,
      'order.quantity': quantity,
      'order.user_id': user_id,
    });
    
    let stockResp;
    try {
      stockResp = await decreaseStock(sku, quantity);
    } catch {
      span.setAttribute('error.type', 'stock_service_unavailable');
      span.end();
      return res.json({ success: false, error: 'stock service unavailable' });
    }
    
    if (!stockResp.success) {
      span.setAttribute('error.type', 'insufficient_stock');
      emitLog('WARN', 'Insufficient stock for order', {
        'order.sku': sku,
        'order.quantity': quantity,
      });
      span.end();
      return res.json({ success: false, error: 'insufficient stock' });
    }
    
    orderCounter++;
    const parcelNumber = `PARCEL-${orderCounter}`;
    orders.set(parcelNumber, { sku, quantity, user_id });
    
    span.setAttribute('order.parcel_number', parcelNumber);
    span.setAttribute('order.success', true);
    span.setAttribute('order.id', orderCounter);
    
    emitLog('INFO', 'Order created successfully', {
      'order.parcel_number': parcelNumber,
      'order.sku': sku,
      'order.quantity': quantity,
      'order.user_id': user_id,
      'order.id': orderCounter,
    });
    
    span.end();
    res.json({ success: true, parcel_number: parcelNumber });
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Unexpected error creating order', {
      'error.message': error.message,
    });
    
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

const server = app.listen(8082, '127.0.0.1', () => {
  console.log('Order service running on port 8082');
  emitLog('INFO', 'Order service started', {
    'service.name': 'order',
    'service.port': 8082,
    'service.host': '127.0.0.1',
  });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Received SIGTERM, shutting down gracefully');
  emitLog('INFO', 'Order service shutting down', {
    'service.name': 'order',
    'orders.total': orderCounter,
  });
  
  server.close(() => {
    console.log('Order service stopped');
    emitLog('INFO', 'Order service stopped', {
      'service.name': 'order',
    });
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('Received SIGINT, shutting down gracefully');
  emitLog('INFO', 'Order service shutting down', {
    'service.name': 'order',
    'orders.total': orderCounter,
  });
  
  server.close(() => {
    console.log('Order service stopped');
    emitLog('INFO', 'Order service stopped', {
      'service.name': 'order',
    });
    process.exit(0);
  });
});
EOF

cat > /workdir/stock/package.json << 'EOF'
{
  "name": "stock",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node --import ./instrumentation.js index.js"
  },
  "dependencies": {
    "express": "^4.21.0",
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/sdk-node": "^0.53.0",
    "@opentelemetry/auto-instrumentations-node": "^0.50.0",
    "@opentelemetry/exporter-trace-otlp-http": "^0.53.0",
    "@opentelemetry/exporter-logs-otlp-http": "^0.53.0",
    "@opentelemetry/sdk-logs": "^0.53.0",
    "@opentelemetry/api-logs": "^0.53.0",
    "@opentelemetry/instrumentation": "^0.53.0"
  }
}
EOF

cat > /workdir/stock/instrumentation.js << 'EOF'
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';
import {
  LoggerProvider,
  BatchLogRecordProcessor,
  ConsoleLogRecordExporter,
} from '@opentelemetry/sdk-logs';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';

// Set diagnostic logging to error level to avoid noise
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

const otlpEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

console.log('='.repeat(60));
console.log('OTEL Instrumentation: ENABLED');
console.log(`Service: stock`);
console.log(`OTEL Endpoint: ${otlpEndpoint}`);
console.log(`Tracing: ${otlpEndpoint}/v1/traces`);
console.log(`Logging: ${otlpEndpoint}/v1/logs`);
console.log('='.repeat(60));

// Configure resource
const resource = new Resource({
  [ATTR_SERVICE_NAME]: 'stock',
  [ATTR_SERVICE_VERSION]: '1.0.0',
});

// Configure trace exporter with timeout and error handling
const traceExporter = new OTLPTraceExporter({
  url: `${otlpEndpoint}/v1/traces`,
  timeoutMillis: 5000,
});

// Configure log exporter
const logExporter = new OTLPLogExporter({
  url: `${otlpEndpoint}/v1/logs`,
  timeoutMillis: 5000,
});

// Initialize Logger Provider
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(logExporter));

// Initialize SDK
const sdk = new NodeSDK({
  resource,
  traceExporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': {
        enabled: false,
      },
    }),
  ],
});

// Handle SDK startup errors gracefully
try {
  sdk.start();
  console.log('OTEL SDK started successfully');
} catch (error) {
  console.error('Failed to start OTEL SDK:', error.message);
  console.log('Service will continue without OTEL instrumentation');
}

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk
    .shutdown()
    .then(() => {
      console.log('OTEL SDK shut down successfully');
      process.exit(0);
    })
    .catch((error) => {
      console.error('Error shutting down OTEL SDK:', error);
      process.exit(1);
    });
});

export { loggerProvider };
EOF

cat > /workdir/stock/index.js << 'EOF'
import express from 'express';
import { trace, context } from '@opentelemetry/api';
import { logs } from '@opentelemetry/api-logs';
import { loggerProvider } from './instrumentation.js';

const app = express();
app.use(express.json());

const products = new Map([
  ['SKU001', 100],
  ['SKU002', 50],
  ['SKU003', 200],
]);

// Get logger for application logs
const logger = loggerProvider.getLogger('stock', '1.0.0');
const tracer = trace.getTracer('stock', '1.0.0');

// Helper function to emit logs
function emitLog(level, message, attributes = {}) {
  const logRecord = {
    severityText: level,
    body: message,
    attributes,
  };
  logger.emit(logRecord);
}

// Request logging middleware
app.use((req, res, next) => {
  const startTime = Date.now();
  
  res.on('finish', () => {
    const duration = Date.now() - startTime;
    const logAttributes = {
      'http.method': req.method,
      'http.url': req.url,
      'http.status_code': res.statusCode,
      'http.duration_ms': duration,
      'http.user_agent': req.get('user-agent') || '',
      'http.client_ip': req.ip,
    };
    
    emitLog('INFO', `${req.method} ${req.url} ${res.statusCode} ${duration}ms`, logAttributes);
  });
  
  next();
});

app.post('/check', (req, res) => {
  const { sku, quantity } = req.body;
  
  const span = tracer.startSpan('check_stock', {
    attributes: {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.operation': 'check',
    },
  });
  
  try {
    const current = products.get(sku) ?? 0;
    const available = products.has(sku) && current >= quantity;
    
    span.setAttribute('stock.available', available);
    span.setAttribute('stock.current', current);
    span.setAttribute('stock.exists', products.has(sku));
    
    emitLog('INFO', 'Stock availability checked', {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.available': available,
      'stock.current': current,
    });
    
    span.end();
    res.json({ available, current });
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Error checking stock', {
      'stock.sku': sku,
      'error.message': error.message,
    });
    
    res.status(500).json({ error: 'internal server error' });
  }
});

app.post('/decrease', (req, res) => {
  const { sku, quantity } = req.body;
  
  const span = tracer.startSpan('decrease_stock', {
    attributes: {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.operation': 'decrease',
    },
  });
  
  try {
    const current = products.get(sku) ?? 0;
    
    if (products.has(sku) && current >= quantity) {
      const newValue = current - quantity;
      products.set(sku, newValue);
      
      span.setAttribute('stock.success', true);
      span.setAttribute('stock.previous', current);
      span.setAttribute('stock.current', newValue);
      
      emitLog('INFO', 'Stock decreased successfully', {
        'stock.sku': sku,
        'stock.quantity': quantity,
        'stock.previous': current,
        'stock.current': newValue,
      });
      
      span.end();
      res.json({ success: true, current: newValue });
    } else {
      span.setAttribute('stock.success', false);
      span.setAttribute('stock.current', current);
      span.setAttribute('stock.reason', 'insufficient_stock');
      
      emitLog('WARN', 'Cannot decrease stock - insufficient quantity', {
        'stock.sku': sku,
        'stock.requested': quantity,
        'stock.current': current,
      });
      
      span.end();
      res.json({ success: false, current });
    }
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Error decreasing stock', {
      'stock.sku': sku,
      'error.message': error.message,
    });
    
    res.status(500).json({ error: 'internal server error' });
  }
});

app.post('/increase', (req, res) => {
  const { sku, quantity } = req.body;
  
  const span = tracer.startSpan('increase_stock', {
    attributes: {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.operation': 'increase',
    },
  });
  
  try {
    const current = products.get(sku) ?? 0;
    const newValue = current + quantity;
    products.set(sku, newValue);
    
    span.setAttribute('stock.success', true);
    span.setAttribute('stock.previous', current);
    span.setAttribute('stock.current', newValue);
    
    emitLog('INFO', 'Stock increased successfully', {
      'stock.sku': sku,
      'stock.quantity': quantity,
      'stock.previous': current,
      'stock.current': newValue,
    });
    
    span.end();
    res.json({ success: true, current: newValue });
  } catch (error) {
    span.recordException(error);
    span.setStatus({ code: 2, message: error.message });
    span.end();
    
    emitLog('ERROR', 'Error increasing stock', {
      'stock.sku': sku,
      'error.message': error.message,
    });
    
    res.status(500).json({ error: 'internal server error' });
  }
});

const server = app.listen(8081, '127.0.0.1', () => {
  console.log('Stock service running on port 8081');
  emitLog('INFO', 'Stock service started', {
    'service.name': 'stock',
    'service.port': 8081,
    'service.host': '127.0.0.1',
    'stock.initial_products': products.size,
  });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Received SIGTERM, shutting down gracefully');
  emitLog('INFO', 'Stock service shutting down', {
    'service.name': 'stock',
    'stock.products_count': products.size,
  });
  
  server.close(() => {
    console.log('Stock service stopped');
    emitLog('INFO', 'Stock service stopped', {
      'service.name': 'stock',
    });
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('Received SIGINT, shutting down gracefully');
  emitLog('INFO', 'Stock service shutting down', {
    'service.name': 'stock',
    'stock.products_count': products.size,
  });
  
  server.close(() => {
    console.log('Stock service stopped');
    emitLog('INFO', 'Stock service stopped', {
      'service.name': 'stock',
    });
    process.exit(0);
  });
});
EOF

printf 'NAME=gateway\nPIDFILE=$(NAME).pid\n\n.PHONY: build start stop test\n\nbuild:\n\tnpm install\n\nstart: build\n\tnpm start >app.log 2>&1 & echo $$! > $(PIDFILE)\n\nstop:\n\t@if [ -f $(PIDFILE) ]; then \\\n\t\tkill $$(cat $(PIDFILE)) 2>/dev/null || true; \\\n\t\trm -f $(PIDFILE); \\\n\tfi\n\ntest:\n\t@curl -s -X POST http://localhost:8080/order \\\n\t\t-H "Content-Type: application/json" \\\n\t\t-d '"'"'{"sku":"SKU001","quantity":1,"user_id":"test"}"'"' | grep -q '"'"'"parcel_number""'"' && echo "gateway order: OK" || echo "gateway order: FAILED"\n' > /workdir/gateway/Makefile

printf 'NAME=order\nPIDFILE=$(NAME).pid\n\n.PHONY: build start stop test\n\nbuild:\n\tnpm install\n\nstart: build\n\tnpm start >app.log 2>&1 & echo $$! > $(PIDFILE)\n\nstop:\n\t@if [ -f $(PIDFILE) ]; then \\\n\t\tkill $$(cat $(PIDFILE)) 2>/dev/null || true; \\\n\t\trm -f $(PIDFILE); \\\n\tfi\n\ntest:\n\t@curl -s -X POST http://localhost:8082/create \\\n\t\t-H "Content-Type: application/json" \\\n\t\t-d '"'"'{"sku":"SKU001","quantity":1,"user_id":"test"}"'"' | grep -q '"'"'"success":false"'"' && echo "order create: OK" || echo "order create: FAILED"\n' > /workdir/order/Makefile

printf 'NAME=stock\nPIDFILE=$(NAME).pid\n\n.PHONY: build start stop test\n\nbuild:\n\tnpm install\n\nstart: build\n\tnpm start >app.log 2>&1 & echo $$! > $(PIDFILE)\n\nstop:\n\t@if [ -f $(PIDFILE) ]; then \\\n\t\tkill $$(cat $(PIDFILE)) 2>/dev/null || true; \\\n\t\trm -f $(PIDFILE); \\\n\tfi\n\ntest:\n\t@curl -s -X POST http://localhost:8081/check \\\n\t\t-H "Content-Type: application/json" \\\n\t\t-d '"'"'{"sku":"SKU001","quantity":1}"'"' | grep -q '"'"'"available":true"'"' && echo "stock check: OK" || echo "stock check: FAILED"\n' > /workdir/stock/Makefile

cd /workdir && make build
