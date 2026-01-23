#!/bin/bash
set -e

# Create go.mod with OpenTelemetry dependencies
cat > /workdir/go.mod << 'EOF'
module workdir

go 1.21

require (
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.49.0
	go.opentelemetry.io/otel v1.24.0
	go.opentelemetry.io/otel/exporters/stdout/stdouttrace v1.24.0
	go.opentelemetry.io/otel/sdk v1.24.0
	go.opentelemetry.io/otel/trace v1.24.0
)
EOF

# Create instrumented server.go with OpenTelemetry tracing
cat > /workdir/server.go << 'ENDOFSERVER'
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type SearchResponse struct {
	Token     string    `json:"token"`
	Timestamp time.Time `json:"timestamp"`
}

type ResultResponse struct {
	Data      string    `json:"data"`
	Token     string    `json:"token"`
	Timestamp time.Time `json:"timestamp"`
}

var (
	tokenStore = make(map[string]string)
	mu         sync.RWMutex
	tracer     trace.Tracer
)

type SpanData struct {
	Name         string                 `json:"name"`
	TraceID      string                 `json:"traceId"`
	SpanID       string                 `json:"spanId"`
	ParentSpanID string                 `json:"parentSpanId"`
	StartTime    time.Time              `json:"startTime"`
	EndTime      time.Time              `json:"endTime"`
	Attributes   map[string]interface{} `json:"attributes"`
	Status       string                 `json:"status"`
}

type MemoryExporter struct {
	spans []sdktrace.ReadOnlySpan
	mu    sync.Mutex
}

func NewMemoryExporter() *MemoryExporter {
	return &MemoryExporter{
		spans: make([]sdktrace.ReadOnlySpan, 0),
	}
}

func (e *MemoryExporter) ExportSpans(ctx context.Context, spans []sdktrace.ReadOnlySpan) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.spans = append(e.spans, spans...)
	return nil
}

func (e *MemoryExporter) Shutdown(ctx context.Context) error {
	return nil
}

func (e *MemoryExporter) GetSpans() []SpanData {
	e.mu.Lock()
	defer e.mu.Unlock()

	result := make([]SpanData, 0, len(e.spans))
	for _, s := range e.spans {
		attrs := make(map[string]interface{})
		for _, attr := range s.Attributes() {
			attrs[string(attr.Key)] = attr.Value.AsInterface()
		}

		parentSpanID := ""
		if s.Parent().SpanID().IsValid() {
			parentSpanID = s.Parent().SpanID().String()
		}

		sd := SpanData{
			Name:         s.Name(),
			TraceID:      s.SpanContext().TraceID().String(),
			SpanID:       s.SpanContext().SpanID().String(),
			ParentSpanID: parentSpanID,
			StartTime:    s.StartTime(),
			EndTime:      s.EndTime(),
			Attributes:   attrs,
			Status:       s.Status().Code.String(),
		}
		result = append(result, sd)
	}
	return result
}

var (
	memExporter  *MemoryExporter
	tp           *sdktrace.TracerProvider
	shutdownChan chan struct{}
)

func initTracer() error {
	memExporter = NewMemoryExporter()

	tp = sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(memExporter),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	tracer = tp.Tracer("server")
	return nil
}

func searchHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	ctx, span := tracer.Start(ctx, "Server /search")
	defer span.End()

	query := r.URL.Query().Get("q")
	if query == "" {
		query = "default"
	}

	span.SetAttributes(
		attribute.String("http.method", r.Method),
		attribute.String("http.target", r.URL.Path),
		attribute.String("search.query", query),
	)

	log.Printf("Search request received for query: %s", query)
	time.Sleep(50 * time.Millisecond)

	hash := sha256.Sum256([]byte(query + time.Now().String()))
	token := hex.EncodeToString(hash[:])[:16]

	mu.Lock()
	tokenStore[token] = fmt.Sprintf("Results for query: %s", query)
	mu.Unlock()

	response := SearchResponse{
		Token:     token,
		Timestamp: time.Now(),
	}

	span.SetAttributes(attribute.Int("http.status_code", http.StatusOK))
	span.SetStatus(codes.Ok, "")

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func resultHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	ctx, span := tracer.Start(ctx, "Server /result")
	defer span.End()

	token := r.URL.Query().Get("token")

	span.SetAttributes(
		attribute.String("http.method", r.Method),
		attribute.String("http.target", r.URL.Path),
		attribute.String("result.token", token),
	)

	if token == "" {
		span.SetAttributes(attribute.Int("http.status_code", http.StatusBadRequest))
		span.SetStatus(codes.Error, "Token required")
		http.Error(w, "Token required", http.StatusBadRequest)
		return
	}

	log.Printf("Result request received for token: %s", token)
	time.Sleep(30 * time.Millisecond)

	mu.RLock()
	data, exists := tokenStore[token]
	mu.RUnlock()

	if !exists {
		span.SetAttributes(attribute.Int("http.status_code", http.StatusNotFound))
		span.SetStatus(codes.Error, "Token not found")
		http.Error(w, "Token not found", http.StatusNotFound)
		return
	}

	response := ResultResponse{
		Data:      data,
		Token:     token,
		Timestamp: time.Now(),
	}

	span.SetAttributes(attribute.Int("http.status_code", http.StatusOK))
	span.SetStatus(codes.Ok, "")

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func shutdownHandler(w http.ResponseWriter, r *http.Request) {
	log.Println("Shutdown request received")
	w.Write([]byte("Shutting down..."))
	go func() {
		time.Sleep(100 * time.Millisecond)
		close(shutdownChan)
	}()
}

func writeSpansToFile() {
	spans := memExporter.GetSpans()
	data, err := json.MarshalIndent(spans, "", "  ")
	if err != nil {
		log.Printf("Failed to marshal spans: %v", err)
		return
	}
	err = os.WriteFile("/workdir/server_traces.json", data, 0644)
	if err != nil {
		log.Printf("Failed to write spans: %v", err)
		return
	}
	log.Printf("Wrote %d spans to server_traces.json", len(spans))
}

func main() {
	if err := initTracer(); err != nil {
		log.Fatal(err)
	}

	shutdownChan = make(chan struct{})

	http.HandleFunc("/search", searchHandler)
	http.HandleFunc("/result", resultHandler)
	http.HandleFunc("/shutdown", shutdownHandler)

	server := &http.Server{Addr: ":8080"}

	go func() {
		<-shutdownChan
		log.Println("Shutting down server...")

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		tp.ForceFlush(ctx)
		tp.Shutdown(ctx)
		writeSpansToFile()

		server.Shutdown(ctx)
	}()

	log.Println("Server starting on :8080")
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
	log.Println("Server stopped")
}
ENDOFSERVER

# Create instrumented client.go with OpenTelemetry tracing
cat > /workdir/client.go << 'ENDOFCLIENT'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type SearchResponse struct {
	Token     string    `json:"token"`
	Timestamp time.Time `json:"timestamp"`
}

type ResultResponse struct {
	Data      string    `json:"data"`
	Token     string    `json:"token"`
	Timestamp time.Time `json:"timestamp"`
}

type SpanData struct {
	Name         string                 `json:"name"`
	TraceID      string                 `json:"traceId"`
	SpanID       string                 `json:"spanId"`
	ParentSpanID string                 `json:"parentSpanId"`
	StartTime    time.Time              `json:"startTime"`
	EndTime      time.Time              `json:"endTime"`
	Attributes   map[string]interface{} `json:"attributes"`
	Status       string                 `json:"status"`
}

type MemoryExporter struct {
	spans []sdktrace.ReadOnlySpan
	mu    sync.Mutex
}

func NewMemoryExporter() *MemoryExporter {
	return &MemoryExporter{
		spans: make([]sdktrace.ReadOnlySpan, 0),
	}
}

func (e *MemoryExporter) ExportSpans(ctx context.Context, spans []sdktrace.ReadOnlySpan) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.spans = append(e.spans, spans...)
	return nil
}

func (e *MemoryExporter) Shutdown(ctx context.Context) error {
	return nil
}

func (e *MemoryExporter) GetSpans() []SpanData {
	e.mu.Lock()
	defer e.mu.Unlock()

	result := make([]SpanData, 0, len(e.spans))
	for _, s := range e.spans {
		attrs := make(map[string]interface{})
		for _, attr := range s.Attributes() {
			attrs[string(attr.Key)] = attr.Value.AsInterface()
		}

		parentSpanID := ""
		if s.Parent().SpanID().IsValid() {
			parentSpanID = s.Parent().SpanID().String()
		}

		sd := SpanData{
			Name:         s.Name(),
			TraceID:      s.SpanContext().TraceID().String(),
			SpanID:       s.SpanContext().SpanID().String(),
			ParentSpanID: parentSpanID,
			StartTime:    s.StartTime(),
			EndTime:      s.EndTime(),
			Attributes:   attrs,
			Status:       s.Status().Code.String(),
		}
		result = append(result, sd)
	}
	return result
}

var (
	tracer      trace.Tracer
	memExporter *MemoryExporter
)

func initTracer() (*sdktrace.TracerProvider, error) {
	memExporter = NewMemoryExporter()

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(memExporter),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	tracer = tp.Tracer("client")
	return tp, nil
}

func doSearchRequest(ctx context.Context, client *http.Client) (*SearchResponse, error) {
	ctx, span := tracer.Start(ctx, "Client Search Request")
	defer span.End()

	url := "http://localhost:8080/search?q=opentelemetry"

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	span.SetAttributes(
		attribute.String("http.method", "GET"),
		attribute.String("http.url", url),
	)

	resp, err := client.Do(req)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	defer resp.Body.Close()

	span.SetAttributes(attribute.Int("http.status_code", resp.StatusCode))

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	var result SearchResponse
	if err := json.Unmarshal(body, &result); err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	span.SetStatus(codes.Ok, "")
	return &result, nil
}

func doResultRequest(ctx context.Context, client *http.Client, token string) (*ResultResponse, error) {
	ctx, span := tracer.Start(ctx, "Client Result Request")
	defer span.End()

	url := fmt.Sprintf("http://localhost:8080/result?token=%s", token)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	span.SetAttributes(
		attribute.String("http.method", "GET"),
		attribute.String("http.url", url),
	)

	resp, err := client.Do(req)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	defer resp.Body.Close()

	span.SetAttributes(attribute.Int("http.status_code", resp.StatusCode))

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	var result ResultResponse
	if err := json.Unmarshal(body, &result); err != nil {
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	span.SetStatus(codes.Ok, "")
	return &result, nil
}

func combineAndWriteTraces() error {
	clientSpans := memExporter.GetSpans()

	time.Sleep(500 * time.Millisecond)

	var serverSpans []SpanData
	serverData, err := os.ReadFile("/workdir/server_traces.json")
	if err == nil {
		json.Unmarshal(serverData, &serverSpans)
	} else {
		log.Printf("Warning: could not read server traces: %v", err)
	}

	allSpans := append(clientSpans, serverSpans...)

	data, err := json.MarshalIndent(allSpans, "", "  ")
	if err != nil {
		return err
	}

	err = os.WriteFile("/workdir/traces.json", data, 0644)
	if err != nil {
		return err
	}

	log.Printf("Wrote %d total spans to traces.json", len(allSpans))
	return nil
}

func main() {
	time.Sleep(2 * time.Second)

	tp, err := initTracer()
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		ctx := context.Background()
		tp.ForceFlush(ctx)
		tp.Shutdown(ctx)
	}()

	client := &http.Client{}

	ctx, mainSpan := tracer.Start(context.Background(), "Client Main")

	log.Println("Making search request...")
	searchResult, err := doSearchRequest(ctx, client)
	if err != nil {
		log.Fatal("Search request failed:", err)
	}
	log.Printf("Received token: %s", searchResult.Token)

	log.Println("Making result request...")
	resultData, err := doResultRequest(ctx, client, searchResult.Token)
	if err != nil {
		log.Fatal("Result request failed:", err)
	}
	log.Printf("Received data: %s", resultData.Data)

	mainSpan.SetStatus(codes.Ok, "")
	mainSpan.End()

	fmt.Println("Client completed successfully")

	tp.ForceFlush(context.Background())

	time.Sleep(100 * time.Millisecond)

	req, _ := http.NewRequest("GET", "http://localhost:8080/shutdown", nil)
	http.DefaultClient.Do(req)

	if err := combineAndWriteTraces(); err != nil {
		log.Fatal("Failed to write traces:", err)
	}
}
ENDOFCLIENT

# Download Go dependencies
cd /workdir
export PATH=$PATH:/usr/local/go/bin
go mod tidy