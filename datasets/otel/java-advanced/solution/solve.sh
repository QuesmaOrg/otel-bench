#!/bin/bash
set -e

# Create lib directory and download OpenTelemetry dependencies
mkdir -p lib
cd lib
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-api/1.32.0/opentelemetry-api-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-sdk/1.32.0/opentelemetry-sdk-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-sdk-trace/1.32.0/opentelemetry-sdk-trace-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-sdk-common/1.32.0/opentelemetry-sdk-common-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-context/1.32.0/opentelemetry-context-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-sdk-metrics/1.32.0/opentelemetry-sdk-metrics-1.32.0.jar
wget -q https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-sdk-logs/1.32.0/opentelemetry-sdk-logs-1.32.0.jar
cd ..

# Create instrumented App.java with OpenTelemetry
python3 << 'PYPYTHON'
with open('App.java', 'w') as f:
    f.write('''import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.io.*;
import java.nio.file.*;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.*;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.common.CompletableResultCode;

class JsonSpanExporter implements SpanExporter {
    private final List<SpanData> spans = Collections.synchronizedList(new ArrayList<>());
    private final String outputFile;
    private volatile boolean hasShutdown = false;
    
    public JsonSpanExporter(String outputFile) {
        this.outputFile = outputFile;
    }
    
    @Override
    public CompletableResultCode export(Collection<SpanData> spans) {
        this.spans.addAll(spans);
        return CompletableResultCode.ofSuccess();
    }
    
    @Override
    public CompletableResultCode flush() {
        return CompletableResultCode.ofSuccess();
    }
    
    @Override
    public CompletableResultCode shutdown() {
        if (hasShutdown) {
            return CompletableResultCode.ofSuccess();
        }
        hasShutdown = true;
        try {
            exportToJson();
            return CompletableResultCode.ofSuccess();
        } catch (Exception e) {
            e.printStackTrace();
            return CompletableResultCode.ofFailure();
        }
    }
    
    private void exportToJson() throws IOException {
        StringBuilder json = new StringBuilder();
        json.append("{\\n");
        json.append("  \\"resourceSpans\\": [{\\n");
        json.append("    \\"resource\\": {\\n");
        json.append("      \\"attributes\\": [\\n");
        json.append("        {\\"key\\": \\"service.name\\", \\"value\\": {\\"stringValue\\": \\"web-service\\"}},\\n");
        json.append("        {\\"key\\": \\"service.version\\", \\"value\\": {\\"stringValue\\": \\"1.0.0\\"}}\\n");
        json.append("      ]\\n");
        json.append("    },\\n");
        json.append("    \\"scopeSpans\\": [{\\n");
        json.append("      \\"scope\\": {\\"name\\": \\"advanced-instrumentation\\"},\\n");
        json.append("      \\"spans\\": [\\n");
        
        for (int i = 0; i < spans.size(); i++) {
            SpanData span = spans.get(i);
            json.append("        {\\n");
            json.append("          \\"traceId\\": \\"").append(span.getTraceId()).append("\\",\\n");
            json.append("          \\"spanId\\": \\"").append(span.getSpanId()).append("\\",\\n");
            json.append("          \\"parentSpanId\\": \\"").append(span.getParentSpanId()).append("\\",\\n");
            json.append("          \\"name\\": \\"").append(escapeJson(span.getName())).append("\\",\\n");
            json.append("          \\"kind\\": \\"").append(span.getKind().name()).append("\\",\\n");
            json.append("          \\"startTimeUnixNano\\": \\"").append(span.getStartEpochNanos()).append("\\",\\n");
            json.append("          \\"endTimeUnixNano\\": \\"").append(span.getEndEpochNanos()).append("\\",\\n");
            
            json.append("          \\"attributes\\": [\\n");
            List<String> attrs = new ArrayList<>();
            span.getAttributes().forEach((key, value) -> {
                attrs.add(String.format("            {\\"key\\": \\"%s\\", \\"value\\": {\\"stringValue\\": \\"%s\\"}}",
                    escapeJson(key.getKey()), escapeJson(String.valueOf(value))));
            });
            if (!attrs.isEmpty()) {
                json.append(String.join(",\\n", attrs));
                json.append("\\n");
            }
            json.append("          ],\\n");
            
            json.append("          \\"status\\": {\\n");
            json.append("            \\"code\\": \\"").append(span.getStatus().getStatusCode().name()).append("\\"\\n");
            json.append("          },\\n");
            
            json.append("          \\"events\\": [\\n");
            List<String> events = new ArrayList<>();
            span.getEvents().forEach(event -> {
                StringBuilder eventJson = new StringBuilder();
                eventJson.append("            {\\n");
                eventJson.append("              \\"timeUnixNano\\": \\"").append(event.getEpochNanos()).append("\\",\\n");
                eventJson.append("              \\"name\\": \\"").append(escapeJson(event.getName())).append("\\",\\n");
                eventJson.append("              \\"attributes\\": []\\n");
                eventJson.append("            }");
                events.add(eventJson.toString());
            });
            if (!events.isEmpty()) {
                json.append(String.join(",\\n", events));
                json.append("\\n");
            }
            json.append("          ]\\n");
            
            json.append("        }");
            if (i < spans.size() - 1) {
                json.append(",");
            }
            json.append("\\n");
        }
        
        json.append("      ]\\n");
        json.append("    }]\\n");
        json.append("  }]\\n");
        json.append("}\\n");
        
        Files.write(Paths.get(outputFile), json.toString().getBytes());
    }
    
    private String escapeJson(String str) {
        if (str == null) return "";
        return str.replace("\\\\", "\\\\\\\\")
                  .replace("\\"", "\\\\\\"")
                  .replace("\\n", "\\\\n")
                  .replace("\\r", "\\\\r")
                  .replace("\\t", "\\\\t");
    }
}
''')
print("Part 1 written")
PYPYTHON

# Append TelemetryConfig class
cat >> App.java << 'EOFPART2'

class TelemetryConfig {
    private static OpenTelemetrySdk openTelemetry;
    private static Tracer tracer;
    private static SdkTracerProvider tracerProvider;
    private static volatile boolean initialized = false;
    
    public static synchronized void initialize() {
        if (initialized) return;
        initialized = true;
        
        JsonSpanExporter exporter = new JsonSpanExporter("/workdir/traces.json");
        
        Resource resource = Resource.getDefault()
            .merge(Resource.create(Attributes.of(
                AttributeKey.stringKey("service.name"), "web-service",
                AttributeKey.stringKey("service.version"), "1.0.0"
            )));
        
        tracerProvider = SdkTracerProvider.builder()
            .addSpanProcessor(SimpleSpanProcessor.create(exporter))
            .setResource(resource)
            .build();
        
        openTelemetry = OpenTelemetrySdk.builder()
            .setTracerProvider(tracerProvider)
            .build();
        
        tracer = openTelemetry.getTracer("advanced-instrumentation", "1.0.0");
    }
    
    public static Tracer getTracer() {
        if (!initialized) {
            initialize();
        }
        return tracer;
    }
    
    public static void shutdown() {
        try {
            if (tracerProvider != null) {
                tracerProvider.forceFlush().join(10, TimeUnit.SECONDS);
                tracerProvider.shutdown().join(10, TimeUnit.SECONDS);
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
EOFPART2

# Append DatabaseService and MessageQueue classes
cat >> App.java << 'EOFPART3'

class DatabaseService {
    private final Random random = new Random();
    
    public static class QueryResult {
        public final String data;
        public final int rowsAffected;
        public final boolean success;
        public final String errorMessage;
        
        public QueryResult(String data, int rowsAffected, boolean success, String errorMessage) {
            this.data = data;
            this.rowsAffected = rowsAffected;
            this.success = success;
            this.errorMessage = errorMessage;
        }
    }
    
    public QueryResult executeQuery(String query, String requestId) throws Exception {
        Tracer tracer = TelemetryConfig.getTracer();
        Span span = tracer.spanBuilder("DatabaseService.executeQuery")
            .setSpanKind(SpanKind.CLIENT)
            .setAttribute("db.operation", "SELECT")
            .setAttribute("db.statement", query)
            .setAttribute("request.id", requestId)
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            Thread.sleep(50 + random.nextInt(150));
            
            if (random.nextDouble() < 0.2) {
                throw new RuntimeException("Database connection timeout");
            }
            
            QueryResult result = new QueryResult(
                "user_data_" + requestId,
                42,
                true,
                ""
            );
            
            span.setAttribute("db.rows_affected", result.rowsAffected);
            span.setStatus(StatusCode.OK);
            return result;
            
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            span.addEvent("exception", Attributes.of(
                AttributeKey.stringKey("exception.type"), e.getClass().getName(),
                AttributeKey.stringKey("exception.message"), e.getMessage()
            ));
            throw e;
        } finally {
            span.end();
        }
    }
    
    public void updateCache(String key, String value) throws InterruptedException {
        Tracer tracer = TelemetryConfig.getTracer();
        Span span = tracer.spanBuilder("DatabaseService.updateCache")
            .setSpanKind(SpanKind.INTERNAL)
            .setAttribute("cache.key", key)
            .setAttribute("cache.operation", "UPDATE")
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            Thread.sleep(30);
            System.out.println("Cache updated: " + key);
            span.setStatus(StatusCode.OK);
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
}

class MessageQueue {
    private final BlockingQueue<String> messages = new LinkedBlockingQueue<>();
    private final AtomicBoolean shutdown = new AtomicBoolean(false);
    
    public void publish(String message, String topic) {
        Tracer tracer = TelemetryConfig.getTracer();
        Span span = tracer.spanBuilder("MessageQueue.publish")
            .setSpanKind(SpanKind.PRODUCER)
            .setAttribute("messaging.operation", "publish")
            .setAttribute("messaging.destination", topic)
            .setAttribute("messaging.message_id", UUID.randomUUID().toString())
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            messages.offer(topic + ":" + message);
            System.out.println("Published to " + topic + ": " + message);
            span.setStatus(StatusCode.OK);
        } finally {
            span.end();
        }
    }
    
    public String consume(int timeoutMs) throws InterruptedException {
        Tracer tracer = TelemetryConfig.getTracer();
        Span span = tracer.spanBuilder("MessageQueue.consume")
            .setSpanKind(SpanKind.CONSUMER)
            .setAttribute("messaging.operation", "consume")
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            String msg = messages.poll(timeoutMs, TimeUnit.MILLISECONDS);
            String result = msg != null ? msg : "";
            if (!result.isEmpty()) {
                span.setAttribute("messaging.message", result);
            }
            span.setStatus(StatusCode.OK);
            return result;
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
    
    public void stop() {
        shutdown.set(true);
    }
    
    public boolean isShutdown() {
        return shutdown.get();
    }
}
EOFPART3

# Append WebService and App classes
cat >> App.java << 'EOFPART4'

class WebService {
    private final DatabaseService db = new DatabaseService();
    private final MessageQueue mq = new MessageQueue();
    private final ExecutorService executor = Executors.newFixedThreadPool(10);
    private final List<Future<?>> workers = new ArrayList<>();
    
    public static class RequestResult {
        public final String response;
        public final int statusCode;
        public final long durationMs;
        
        public RequestResult(String response, int statusCode, long durationMs) {
            this.response = response;
            this.statusCode = statusCode;
            this.durationMs = durationMs;
        }
    }
    
    private CompletableFuture<String> processAsync(String requestId, Context parentContext) {
        return CompletableFuture.supplyAsync(() -> {
            Tracer tracer = TelemetryConfig.getTracer();
            Span span = tracer.spanBuilder("WebService.processAsync")
                .setParent(parentContext)
                .setSpanKind(SpanKind.INTERNAL)
                .setAttribute("request.id", requestId)
                .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
                .startSpan();
            
            try (Scope scope = span.makeCurrent()) {
                Thread.sleep(100);
                
                DatabaseService.QueryResult dbResult = db.executeQuery("SELECT * FROM users", requestId);
                
                Context currentContext = Context.current();
                executor.submit(() -> {
                    try (Scope cacheScope = currentContext.makeCurrent()) {
                        db.updateCache("user:" + requestId, dbResult.data);
                    } catch (Exception e) {
                        System.err.println("Cache update failed: " + e.getMessage());
                    }
                });
                
                mq.publish("request_processed:" + requestId, "events");
                
                span.setStatus(StatusCode.OK);
                return "Success: " + dbResult.data;
            } catch (Exception e) {
                span.recordException(e);
                span.setStatus(StatusCode.ERROR, e.getMessage());
                throw new CompletionException(e);
            } finally {
                span.end();
            }
        }, executor);
    }
    
    public RequestResult handleRequest(String requestId, String endpoint) {
        long startTime = System.currentTimeMillis();
        
        Tracer tracer = TelemetryConfig.getTracer();
        Span span = tracer.spanBuilder("WebService.handleRequest")
            .setSpanKind(SpanKind.SERVER)
            .setAttribute("http.method", "GET")
            .setAttribute("http.target", endpoint)
            .setAttribute("request.id", requestId)
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            System.out.println("Handling request " + requestId + " for endpoint: " + endpoint);
            
            if (endpoint.equals("/health")) {
                span.setAttribute("http.status_code", 200);
                span.setStatus(StatusCode.OK);
                return new RequestResult("OK", 200, 1);
            }
            
            Context currentContext = Context.current();
            String result = processAsync(requestId, currentContext).get();
            
            long duration = System.currentTimeMillis() - startTime;
            span.setAttribute("http.status_code", 200);
            span.setAttribute("duration.ms", duration);
            span.setStatus(StatusCode.OK);
            return new RequestResult(result, 200, duration);
            
        } catch (Exception e) {
            long duration = System.currentTimeMillis() - startTime;
            System.err.println("Error processing request: " + e.getMessage());
            span.recordException(e);
            span.setAttribute("http.status_code", 500);
            span.setAttribute("duration.ms", duration);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            span.addEvent("error", Attributes.of(
                AttributeKey.stringKey("error.message"), e.getMessage()
            ));
            return new RequestResult(e.getMessage(), 500, duration);
        } finally {
            span.end();
        }
    }
    
    public void startBackgroundWorker() {
        Tracer tracer = TelemetryConfig.getTracer();
        Span workerSpan = tracer.spanBuilder("BackgroundWorker")
            .setSpanKind(SpanKind.INTERNAL)
            .setAttribute("worker.type", "message-consumer")
            .setAttribute("thread.id", String.valueOf(Thread.currentThread().getId()))
            .startSpan();
        
        Context workerContext = Context.current().with(workerSpan);
        
        workers.add(executor.submit(() -> {
            try (Scope scope = workerContext.makeCurrent()) {
                while (!mq.isShutdown()) {
                    try {
                        String message = mq.consume(1000);
                        if (!message.isEmpty()) {
                            System.out.println("Worker processed: " + message);
                            Thread.sleep(50);
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            } finally {
                workerSpan.end();
            }
        }));
    }
    
    public void shutdown() {
        mq.stop();
        executor.shutdown();
        try {
            executor.awaitTermination(5, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            executor.shutdownNow();
        }
    }
}

public class App {
    public static void main(String[] args) {
        try {
            TelemetryConfig.initialize();
            
            WebService service = new WebService();
            service.startBackgroundWorker();
            
            List<CompletableFuture<WebService.RequestResult>> futures = new ArrayList<>();
            ExecutorService requestExecutor = Executors.newFixedThreadPool(5);
            
            for (int i = 0; i < 5; i++) {
                final int requestNum = i;
                futures.add(CompletableFuture.supplyAsync(() -> {
                    String requestId = "req_" + requestNum;
                    return service.handleRequest(requestId, "/api/users");
                }, requestExecutor));
            }
            
            WebService.RequestResult healthResult = service.handleRequest("health_check", "/health");
            System.out.println("Health check: " + healthResult.response);
            
            for (CompletableFuture<WebService.RequestResult> future : futures) {
                WebService.RequestResult result = future.get();
                System.out.println("Request completed with status: " + result.statusCode + 
                                 ", duration: " + result.durationMs + "ms");
            }
            
            requestExecutor.shutdown();
            service.shutdown();
            
            Thread.sleep(500);
            
            System.out.println("Service shutdown complete");
            
            TelemetryConfig.shutdown();
            System.out.println("Traces exported to /workdir/traces.json");
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
EOFPART4

# Compile and run the application
javac -cp "lib/*" App.java
java -cp ".:lib/*" App