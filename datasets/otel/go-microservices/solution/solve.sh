#!/bin/bash
set -e

GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org go get go.opentelemetry.io/otel@v1.39.0 go.opentelemetry.io/otel/sdk@v1.39.0 go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.39.0 go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.64.0 go.opentelemetry.io/contrib/bridges/otelslog@v0.14.0 go.opentelemetry.io/otel/sdk/log@v0.15.0 go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp@v0.15.0

mkdir -p /workdir/internal/telemetry

cat > /workdir/internal/telemetry/slogmulti.go <<'EOF'
package telemetry

import (
	"context"
	"log/slog"
)

type multiHandler struct {
	handlers []slog.Handler
}

func newMultiHandler(handlers ...slog.Handler) slog.Handler {
	// Drop nil handlers to keep call sites clean.
	filtered := make([]slog.Handler, 0, len(handlers))
	for _, h := range handlers {
		if h != nil {
			filtered = append(filtered, h)
		}
	}
	return &multiHandler{handlers: filtered}
}

func (h *multiHandler) Enabled(ctx context.Context, level slog.Level) bool {
	for _, child := range h.handlers {
		if child.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (h *multiHandler) Handle(ctx context.Context, r slog.Record) error {
	var lastErr error
	for _, child := range h.handlers {
		if err := child.Handle(ctx, r); err != nil {
			lastErr = err
		}
	}
	return lastErr
}

func (h *multiHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	children := make([]slog.Handler, 0, len(h.handlers))
	for _, child := range h.handlers {
		children = append(children, child.WithAttrs(attrs))
	}
	return &multiHandler{handlers: children}
}

func (h *multiHandler) WithGroup(name string) slog.Handler {
	children := make([]slog.Handler, 0, len(h.handlers))
	for _, child := range h.handlers {
		children = append(children, child.WithGroup(name))
	}
	return &multiHandler{handlers: children}
}
EOF

cat > /workdir/internal/telemetry/httplog.go <<'EOF'
package telemetry

import (
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"go.opentelemetry.io/otel/trace"
)

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (w *statusWriter) WriteHeader(statusCode int) {
	w.status = statusCode
	w.ResponseWriter.WriteHeader(statusCode)
}

func (w *statusWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += n
	return n, err
}

// AccessLogMiddleware logs a single line per HTTP request, including trace correlation.
// It is intended to run *inside* an otelhttp handler so r.Context() contains the server span.
func AccessLogMiddleware(logger *slog.Logger, route string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			sw := &statusWriter{ResponseWriter: w}

			next.ServeHTTP(sw, r)

			latency := time.Since(start)
			sc := trace.SpanContextFromContext(r.Context())

			logger.InfoContext(r.Context(), "http.request",
				slog.String("service.route", route),
				slog.String("http.method", r.Method),
				slog.String("http.target", r.URL.RequestURI()),
				slog.String("http.path", r.URL.Path),
				slog.String("http.scheme", scheme(r)),
				slog.String("server.address", r.Host),
				slog.String("client.address", r.RemoteAddr),
				slog.String("user_agent", r.UserAgent()),
				slog.Int("http.status_code", sw.status),
				slog.Int("http.response.body.bytes", sw.bytes),
				slog.Int64("http.server.duration_ms", latency.Milliseconds()),
				slog.String("trace_id", sc.TraceID().String()),
				slog.String("span_id", sc.SpanID().String()),
			)
		})
	}
}

func scheme(r *http.Request) string {
	if r.TLS != nil {
		return "https"
	}
	// If behind a proxy, this is commonly set.
	if v := r.Header.Get("X-Forwarded-Proto"); v != "" {
		return v
	}
	return "http"
}

// StatusTextAttr provides a stable string representation in logs if desired.
func StatusTextAttr(status int) slog.Attr {
	return slog.String("http.status_text", strconv.Quote(http.StatusText(status)))
}
EOF

cat > /workdir/internal/telemetry/telemetry.go <<'EOF'
package telemetry

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	logglobal "go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

type ShutdownFunc func(context.Context) error

type Setup struct {
	Logger   *slog.Logger
	Shutdown ShutdownFunc

	TracesEndpoint string
	LogsEndpoint   string
}

// Init configures OpenTelemetry tracing (v1.39.0) and OpenTelemetry logging (current Go logs SDK).
//
// Export is configured via standard OTEL environment variables:
//   - OTEL_EXPORTER_OTLP_ENDPOINT (e.g. http://localhost:4318)
//   - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT / OTEL_EXPORTER_OTLP_LOGS_ENDPOINT override per signal
//
// Services must continue working if the collector is unavailable; exporters may drop data.
func Init(ctx context.Context, serviceName string) (*Setup, error) {
	tracesEndpoint := resolveOTLPEndpoint("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
	logsEndpoint := resolveOTLPEndpoint("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")

	// Always keep a local stdout logger so we can report OTEL setup problems.
	stdoutHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
	baseLogger := slog.New(stdoutHandler).With(
		slog.String("service.name", serviceName),
		slog.String("otel.traces.endpoint", tracesEndpoint),
		slog.String("otel.logs.endpoint", logsEndpoint),
	)

	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		// Avoid recursion by not using the slog logger here.
		fmt.Fprintln(os.Stderr, "otel error:", err)
	}))

	res, err := resource.New(
		ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithHost(),
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			attribute.String("service.namespace", "shop"),
		),
	)
	if err != nil {
		baseLogger.Warn("failed to build otel resource; continuing with defaults", slog.Any("err", err))
		res = resource.Default()
	}

	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	shutdowns := make([]ShutdownFunc, 0, 2)

	// --- Tracing ---
	traceExp, err := newTraceExporter(ctx)
	if err != nil {
		baseLogger.Warn("otel tracing exporter unavailable; tracing will be disabled", slog.Any("err", err))
		otel.SetTracerProvider(trace.NewNoopTracerProvider())
	} else {
		tp := sdktrace.NewTracerProvider(
			sdktrace.WithResource(res),
			sdktrace.WithBatcher(traceExp),
		)
		otel.SetTracerProvider(tp)
		shutdowns = append(shutdowns, tp.Shutdown)
	}

	// --- Logging (OTEL Logs) ---
	var otelLogHandler slog.Handler
	logExp, err := newLogExporter(ctx)
	if err != nil {
		baseLogger.Warn("otel logs exporter unavailable; exporting logs will be disabled", slog.Any("err", err))
	} else {
		lp := sdklog.NewLoggerProvider(
			sdklog.WithResource(res),
			sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)),
		)
		logglobal.SetLoggerProvider(lp)
		shutdowns = append(shutdowns, lp.Shutdown)

		otelLogHandler = otelslog.NewHandler(serviceName, otelslog.WithLoggerProvider(lp))
	}

	logger := slog.New(newMultiHandler(stdoutHandler, otelLogHandler)).With(
		slog.String("service.name", serviceName),
		slog.String("otel.traces.endpoint", tracesEndpoint),
		slog.String("otel.logs.endpoint", logsEndpoint),
	)

	return &Setup{
		Logger:         logger,
		TracesEndpoint: tracesEndpoint,
		LogsEndpoint:   logsEndpoint,
		Shutdown: func(ctx context.Context) error {
			var joined error
			for i := len(shutdowns) - 1; i >= 0; i-- {
				if err := shutdowns[i](ctx); err != nil {
					joined = errors.Join(joined, err)
				}
			}
			return joined
		},
	}, nil
}

func newTraceExporter(ctx context.Context) (*otlptracehttp.Exporter, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return otlptracehttp.New(ctx)
}

func newLogExporter(ctx context.Context) (*otlploghttp.Exporter, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return otlploghttp.New(ctx)
}

func resolveOTLPEndpoint(signalSpecificEnv string) string {
	// Prefer per-signal env var.
	if v := strings.TrimSpace(os.Getenv(signalSpecificEnv)); v != "" {
		return v
	}
	if v := strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")); v != "" {
		return v
	}
	// OTLP/HTTP default.
	return "http://localhost:4318"
}
EOF

cat > /workdir/gateway/main.go <<'EOF'
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"microservices/internal/telemetry"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

type Gateway struct {
	stockAPIURL string
	orderAPIURL string
	client      *http.Client
}

func NewGateway(stockAPIURL, orderAPIURL string) *Gateway {
	return &Gateway{
		stockAPIURL: stockAPIURL,
		orderAPIURL: orderAPIURL,
		client: &http.Client{
			Transport: otelhttp.NewTransport(http.DefaultTransport),
			Timeout:   5 * time.Second,
		},
	}
}

type OrderRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
	UserID   string `json:"user_id"`
}

type OrderResponse struct {
	Success      bool   `json:"success"`
	ParcelNumber string `json:"parcel_number,omitempty"`
	Error        string `json:"error,omitempty"`
}

type StockCheckRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type StockCheckResponse struct {
	Available bool `json:"available"`
	Current   int  `json:"current"`
}

func (g *Gateway) checkStock(ctx context.Context, sku string, quantity int) (bool, error) {
	reqBody := StockCheckRequest{SKU: sku, Quantity: quantity}
	body, _ := json.Marshal(reqBody)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.stockAPIURL+"/check", bytes.NewBuffer(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := g.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	var stockResp StockCheckResponse
	if err := json.NewDecoder(resp.Body).Decode(&stockResp); err != nil {
		return false, err
	}

	return stockResp.Available, nil
}

func (g *Gateway) createOrder(ctx context.Context, reqBody OrderRequest) (*OrderResponse, error) {
	body, _ := json.Marshal(reqBody)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.orderAPIURL+"/create", bytes.NewBuffer(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := g.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var orderResp OrderResponse
	if err := json.NewDecoder(resp.Body).Decode(&orderResp); err != nil {
		return nil, err
	}

	return &orderResp, nil
}

func (g *Gateway) order(logger *slog.Logger) http.HandlerFunc {
	tr := otel.Tracer("microservices/gateway")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req OrderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		ctx, span := tr.Start(r.Context(), "gateway.place_order")
		span.SetAttributes(
			attribute.String("shop.sku", req.SKU),
			attribute.Int("shop.quantity", req.Quantity),
			attribute.String("enduser.id", req.UserID),
		)
		defer span.End()

		logger.InfoContext(ctx, "order.requested",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.String("enduser.id", req.UserID),
		)

		available, err := g.checkStock(ctx, req.SKU, req.Quantity)
		if err != nil {
			resp := OrderResponse{Success: false, Error: "stock service unavailable"}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			return
		}

		if !available {
			resp := OrderResponse{Success: false, Error: "product not available"}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			return
		}

		orderResp, err := g.createOrder(ctx, req)
		if err != nil {
			resp := OrderResponse{Success: false, Error: "order service unavailable"}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			return
		}

		logger.InfoContext(ctx, "order.created",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.Bool("success", orderResp.Success),
			slog.String("parcel_number", orderResp.ParcelNumber),
			// If orderResp.Success==false, Error will be populated.
			slog.String("error", orderResp.Error),
		)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(orderResp)
	}
}

func main() {
	ctx := context.Background()

	setup, _ := telemetry.Init(ctx, "gateway")
	logger := setup.Logger

	logger.Info("service.starting",
		slog.String("addr", "localhost:8080"),
		slog.String("otel.sdk.version", otel.Version()),
		slog.Bool("otel.instrumented", true),
	)

	gateway := NewGateway("http://localhost:8081", "http://localhost:8082")

	mux := http.NewServeMux()
	orderHandler := http.HandlerFunc(gateway.order(logger))
	orderHandler = telemetry.AccessLogMiddleware(logger, "/order")(orderHandler)
	orderHandler = otelhttp.NewHandler(orderHandler, "POST /order")
	mux.Handle("/order", orderHandler)

	srv := &http.Server{
		Addr:              "localhost:8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		err := srv.ListenAndServe()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	logger.Info("service.started", slog.String("addr", srv.Addr))

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case <-stop:
		logger.Info("service.stopping")
	case err := <-errCh:
		if err != nil {
			logger.Error("server error", slog.Any("err", err))
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown error", slog.Any("err", err))
	}
	if err := setup.Shutdown(shutdownCtx); err != nil {
		logger.Error("otel shutdown error", slog.Any("err", err))
	}

	logger.Info("service.stopped")
}
EOF

cat > /workdir/order/main.go <<'EOF'
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"microservices/internal/telemetry"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

var orderCounter uint64

type OrderRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
	UserID   string `json:"user_id"`
}

type OrderResponse struct {
	Success      bool   `json:"success"`
	ParcelNumber string `json:"parcel_number,omitempty"`
	Error        string `json:"error,omitempty"`
}

type StockUpdateRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type StockUpdateResponse struct {
	Success bool `json:"success"`
	Current int  `json:"current"`
}

type Order struct {
	mu          sync.Mutex
	orders      map[string]OrderRequest
	stockAPIURL string
	client      *http.Client
}

func NewOrder(stockAPIURL string) *Order {
	return &Order{
		orders:      make(map[string]OrderRequest),
		stockAPIURL: stockAPIURL,
		client: &http.Client{
			Transport: otelhttp.NewTransport(http.DefaultTransport),
			Timeout:   5 * time.Second,
		},
	}
}

func (o *Order) decreaseStock(ctx context.Context, sku string, quantity int) (bool, error) {
	reqBody := StockUpdateRequest{SKU: sku, Quantity: quantity}
	body, _ := json.Marshal(reqBody)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.stockAPIURL+"/decrease", bytes.NewBuffer(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := o.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	var stockResp StockUpdateResponse
	if err := json.NewDecoder(resp.Body).Decode(&stockResp); err != nil {
		return false, err
	}

	return stockResp.Success, nil
}

func (o *Order) createOrder(logger *slog.Logger) http.HandlerFunc {
	tr := otel.Tracer("microservices/order")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req OrderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		ctx, span := tr.Start(r.Context(), "order.create")
		span.SetAttributes(
			attribute.String("shop.sku", req.SKU),
			attribute.Int("shop.quantity", req.Quantity),
			attribute.String("enduser.id", req.UserID),
		)
		defer span.End()

		logger.InfoContext(ctx, "order.create.requested",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.String("enduser.id", req.UserID),
		)

		success, err := o.decreaseStock(ctx, req.SKU, req.Quantity)
		if err != nil {
			resp := OrderResponse{Success: false, Error: "stock service unavailable"}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			return
		}

		if !success {
			resp := OrderResponse{Success: false, Error: "insufficient stock"}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			return
		}

		parcelNumber := fmt.Sprintf("PARCEL-%d", atomic.AddUint64(&orderCounter, 1))

		o.mu.Lock()
		o.orders[parcelNumber] = req
		o.mu.Unlock()

		resp := OrderResponse{Success: true, ParcelNumber: parcelNumber}

		logger.InfoContext(ctx, "order.created",
			slog.String("parcel_number", parcelNumber),
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
		)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

func main() {
	ctx := context.Background()

	setup, _ := telemetry.Init(ctx, "order")
	logger := setup.Logger

	logger.Info("service.starting",
		slog.String("addr", "localhost:8082"),
		slog.String("otel.sdk.version", otel.Version()),
		slog.Bool("otel.instrumented", true),
	)

	order := NewOrder("http://localhost:8081")

	mux := http.NewServeMux()
	createHandler := http.HandlerFunc(order.createOrder(logger))
	createHandler = telemetry.AccessLogMiddleware(logger, "/create")(createHandler)
	createHandler = otelhttp.NewHandler(createHandler, "POST /create")
	mux.Handle("/create", createHandler)

	srv := &http.Server{
		Addr:              "localhost:8082",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		err := srv.ListenAndServe()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	logger.Info("service.started", slog.String("addr", srv.Addr))

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case <-stop:
		logger.Info("service.stopping")
	case err := <-errCh:
		if err != nil {
			logger.Error("server error", slog.Any("err", err))
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown error", slog.Any("err", err))
	}
	if err := setup.Shutdown(shutdownCtx); err != nil {
		logger.Error("otel shutdown error", slog.Any("err", err))
	}

	logger.Info("service.stopped")
}
EOF

cat > /workdir/stock/main.go <<'EOF'
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"microservices/internal/telemetry"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

type Stock struct {
	mu       sync.RWMutex
	products map[string]int
}

func NewStock() *Stock {
	return &Stock{
		products: map[string]int{
			"SKU001": 100,
			"SKU002": 50,
			"SKU003": 200,
		},
	}
}

type CheckRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type CheckResponse struct {
	Available bool `json:"available"`
	Current   int  `json:"current"`
}

type UpdateRequest struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type UpdateResponse struct {
	Success bool `json:"success"`
	Current int  `json:"current"`
}

func (s *Stock) checkAvailability(logger *slog.Logger) http.HandlerFunc {
	tr := otel.Tracer("microservices/stock")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req CheckRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		ctx, span := tr.Start(r.Context(), "stock.check")
		span.SetAttributes(
			attribute.String("shop.sku", req.SKU),
			attribute.Int("shop.quantity", req.Quantity),
		)
		defer span.End()

		s.mu.RLock()
		current, exists := s.products[req.SKU]
		s.mu.RUnlock()

		resp := CheckResponse{Available: exists && current >= req.Quantity, Current: current}

		logger.InfoContext(ctx, "stock.checked",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.Bool("available", resp.Available),
			slog.Int("current", resp.Current),
		)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

func (s *Stock) decrease(logger *slog.Logger) http.HandlerFunc {
	tr := otel.Tracer("microservices/stock")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req UpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		ctx, span := tr.Start(r.Context(), "stock.decrease")
		span.SetAttributes(
			attribute.String("shop.sku", req.SKU),
			attribute.Int("shop.quantity", req.Quantity),
		)
		defer span.End()

		s.mu.Lock()
		current, exists := s.products[req.SKU]
		success := exists && current >= req.Quantity
		if success {
			s.products[req.SKU] = current - req.Quantity
			current = s.products[req.SKU]
		}
		s.mu.Unlock()

		resp := UpdateResponse{Success: success, Current: current}

		logger.InfoContext(ctx, "stock.decreased",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.Bool("success", resp.Success),
			slog.Int("current", resp.Current),
		)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

func (s *Stock) increase(logger *slog.Logger) http.HandlerFunc {
	tr := otel.Tracer("microservices/stock")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req UpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		ctx, span := tr.Start(r.Context(), "stock.increase")
		span.SetAttributes(
			attribute.String("shop.sku", req.SKU),
			attribute.Int("shop.quantity", req.Quantity),
		)
		defer span.End()

		s.mu.Lock()
		s.products[req.SKU] += req.Quantity
		current := s.products[req.SKU]
		s.mu.Unlock()

		resp := UpdateResponse{Success: true, Current: current}

		logger.InfoContext(ctx, "stock.increased",
			slog.String("shop.sku", req.SKU),
			slog.Int("shop.quantity", req.Quantity),
			slog.Int("current", resp.Current),
		)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

func main() {
	ctx := context.Background()

	setup, _ := telemetry.Init(ctx, "stock")
	logger := setup.Logger

	logger.Info("service.starting",
		slog.String("addr", "localhost:8081"),
		slog.String("otel.sdk.version", otel.Version()),
		slog.Bool("otel.instrumented", true),
	)

	stock := NewStock()

	mux := http.NewServeMux()

	checkHandler := http.HandlerFunc(stock.checkAvailability(logger))
	checkHandler = telemetry.AccessLogMiddleware(logger, "/check")(checkHandler)
	checkHandler = otelhttp.NewHandler(checkHandler, "POST /check")
	mux.Handle("/check", checkHandler)

	decreaseHandler := http.HandlerFunc(stock.decrease(logger))
	decreaseHandler = telemetry.AccessLogMiddleware(logger, "/decrease")(decreaseHandler)
	decreaseHandler = otelhttp.NewHandler(decreaseHandler, "POST /decrease")
	mux.Handle("/decrease", decreaseHandler)

	increaseHandler := http.HandlerFunc(stock.increase(logger))
	increaseHandler = telemetry.AccessLogMiddleware(logger, "/increase")(increaseHandler)
	increaseHandler = otelhttp.NewHandler(increaseHandler, "POST /increase")
	mux.Handle("/increase", increaseHandler)

	srv := &http.Server{
		Addr:              "localhost:8081",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		err := srv.ListenAndServe()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	logger.Info("service.started", slog.String("addr", srv.Addr))

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case <-stop:
		logger.Info("service.stopping")
	case err := <-errCh:
		if err != nil {
			logger.Error("server error", slog.Any("err", err))
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown error", slog.Any("err", err))
	}
	if err := setup.Shutdown(shutdownCtx); err != nil {
		logger.Error("otel shutdown error", slog.Any("err", err))
	}

	logger.Info("service.stopped")
}
EOF

gofmt -w /workdir/internal/telemetry/*.go /workdir/gateway/main.go /workdir/order/main.go /workdir/stock/main.go

go mod tidy

python3 - <<'PY'
from pathlib import Path
p = Path('/workdir/internal/telemetry/telemetry.go')
s = p.read_text()
old = '''\t// --- Tracing ---
\ttraceExp, err := newTraceExporter(ctx)
\tif err != nil {
\t\tbaseLogger.Warn("otel tracing exporter unavailable; tracing will be disabled", slog.Any("err", err))
\t\totel.SetTracerProvider(trace.NewNoopTracerProvider())
\t} else {
\t\ttp := sdktrace.NewTracerProvider(
\t\t\tsdktrace.WithResource(res),
\t\t\tsdktrace.WithBatcher(traceExp),
\t\t)
\t\totel.SetTracerProvider(tp)
\t\tshutdowns = append(shutdowns, tp.Shutdown)
\t}
'''
new = '''\t// --- Tracing ---
\t// Always install an SDK tracer provider so spans/trace IDs exist for correlation,
\t// even if exporting is not available.
\ttpOpts := []sdktrace.TracerProviderOption{sdktrace.WithResource(res)}
\ttraceExp, err := newTraceExporter(ctx)
\tif err != nil {
\t\tbaseLogger.Warn("otel tracing exporter unavailable; spans will not be exported", slog.Any("err", err))
\t} else {
\t\ttpOpts = append(tpOpts, sdktrace.WithBatcher(traceExp))
\t}
\ttp := sdktrace.NewTracerProvider(tpOpts...)
\totel.SetTracerProvider(tp)
\tshutdowns = append(shutdowns, tp.Shutdown)
'''
if old not in s:
    raise SystemExit('Expected tracing block not found; telemetry.go may have changed')
p.write_text(s.replace(old, new))
PY

gofmt -w /workdir/internal/telemetry/telemetry.go

python3 - <<'PY'
from pathlib import Path
import re
p = Path('/workdir/internal/telemetry/telemetry.go')
s = p.read_text()

# Remove unused trace import line if present.
s = re.sub(r'\n\t"go\.opentelemetry\.io/otel/trace"\n', '\n', s)

# Fix exporter function signatures to use SDK interfaces.
s = re.sub(r'func newTraceExporter\(ctx context\.Context\) \(\*otlptracehttp\.Exporter, error\) {',
           'func newTraceExporter(ctx context.Context) (sdktrace.SpanExporter, error) {', s)

s = re.sub(r'func newLogExporter\(ctx context\.Context\) \(\*otlploghttp\.Exporter, error\) {',
           'func newLogExporter(ctx context.Context) (sdklog.Exporter, error) {', s)

p.write_text(s)
PY

gofmt -w /workdir/internal/telemetry/telemetry.go

python3 - <<'PY'
from pathlib import Path

def patch(path: str, mapping):
    p = Path(path)
    s = p.read_text()
    for old, new in mapping.items():
        if old not in s:
            raise SystemExit(f"Expected block not found in {path}:\n{old}")
        s = s.replace(old, new)
    p.write_text(s)

patch('/workdir/gateway/main.go', {
"\torderHandler := http.HandlerFunc(gateway.order(logger))\n\torderHandler = telemetry.AccessLogMiddleware(logger, \"/order\")(orderHandler)\n\torderHandler = otelhttp.NewHandler(orderHandler, \"POST /order\")\n\tmux.Handle(\"/order\", orderHandler)\n":
"\tvar orderHandler http.Handler = http.HandlerFunc(gateway.order(logger))\n\torderHandler = telemetry.AccessLogMiddleware(logger, \"/order\")(orderHandler)\n\torderHandler = otelhttp.NewHandler(orderHandler, \"POST /order\")\n\tmux.Handle(\"/order\", orderHandler)\n"
})

patch('/workdir/order/main.go', {
"\tcreateHandler := http.HandlerFunc(order.createOrder(logger))\n\tcreateHandler = telemetry.AccessLogMiddleware(logger, \"/create\")(createHandler)\n\tcreateHandler = otelhttp.NewHandler(createHandler, \"POST /create\")\n\tmux.Handle(\"/create\", createHandler)\n":
"\tvar createHandler http.Handler = http.HandlerFunc(order.createOrder(logger))\n\tcreateHandler = telemetry.AccessLogMiddleware(logger, \"/create\")(createHandler)\n\tcreateHandler = otelhttp.NewHandler(createHandler, \"POST /create\")\n\tmux.Handle(\"/create\", createHandler)\n"
})

patch('/workdir/stock/main.go', {
"\tcheckHandler := http.HandlerFunc(stock.checkAvailability(logger))\n\tcheckHandler = telemetry.AccessLogMiddleware(logger, \"/check\")(checkHandler)\n\tcheckHandler = otelhttp.NewHandler(checkHandler, \"POST /check\")\n\tmux.Handle(\"/check\", checkHandler)\n":
"\tvar checkHandler http.Handler = http.HandlerFunc(stock.checkAvailability(logger))\n\tcheckHandler = telemetry.AccessLogMiddleware(logger, \"/check\")(checkHandler)\n\tcheckHandler = otelhttp.NewHandler(checkHandler, \"POST /check\")\n\tmux.Handle(\"/check\", checkHandler)\n",

"\tdecreaseHandler := http.HandlerFunc(stock.decrease(logger))\n\tdecreaseHandler = telemetry.AccessLogMiddleware(logger, \"/decrease\")(decreaseHandler)\n\tdecreaseHandler = otelhttp.NewHandler(decreaseHandler, \"POST /decrease\")\n\tmux.Handle(\"/decrease\", decreaseHandler)\n":
"\tvar decreaseHandler http.Handler = http.HandlerFunc(stock.decrease(logger))\n\tdecreaseHandler = telemetry.AccessLogMiddleware(logger, \"/decrease\")(decreaseHandler)\n\tdecreaseHandler = otelhttp.NewHandler(decreaseHandler, \"POST /decrease\")\n\tmux.Handle(\"/decrease\", decreaseHandler)\n",

"\tincreaseHandler := http.HandlerFunc(stock.increase(logger))\n\tincreaseHandler = telemetry.AccessLogMiddleware(logger, \"/increase\")(increaseHandler)\n\tincreaseHandler = otelhttp.NewHandler(increaseHandler, \"POST /increase\")\n\tmux.Handle(\"/increase\", increaseHandler)\n":
"\tvar increaseHandler http.Handler = http.HandlerFunc(stock.increase(logger))\n\tincreaseHandler = telemetry.AccessLogMiddleware(logger, \"/increase\")(increaseHandler)\n\tincreaseHandler = otelhttp.NewHandler(increaseHandler, \"POST /increase\")\n\tmux.Handle(\"/increase\", increaseHandler)\n"
})
PY

gofmt -w /workdir/gateway/main.go /workdir/order/main.go /workdir/stock/main.go

go build ./...
