#!/bin/bash
set -e

# Update gateway service with OTEL instrumentation
cat > /workdir/gateway/Cargo.toml << 'EOF'
[package]
name = "gateway"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["json"] }

# OpenTelemetry
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["http-proto", "reqwest-client", "logs"] }
opentelemetry-semantic-conventions = "0.27"
opentelemetry-appender-tracing = "0.27"

# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-opentelemetry = "0.28"
EOF

cat > /workdir/gateway/src/main.rs << 'EOF'
use axum::{extract::State, routing::post, Json, Router};
use opentelemetry::{
    global,
    propagation::Injector,
    trace::TracerProvider as _,
    KeyValue,
};
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_otlp::{LogExporter, SpanExporter, Protocol, WithExportConfig};
use opentelemetry_sdk::{
    logs::LoggerProvider,
    propagation::TraceContextPropagator,
    runtime,
    trace::TracerProvider,
    Resource,
};
use serde::{Deserialize, Serialize};
use tracing::{info, error, instrument, Span};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const SERVICE_NAME: &str = "gateway";

#[derive(Clone)]
struct AppState {
    stock_api_url: String,
    order_api_url: String,
    client: reqwest::Client,
}

#[derive(Deserialize, Serialize, Debug)]
struct OrderRequest {
    sku: String,
    quantity: i32,
    user_id: String,
}

#[derive(Deserialize, Serialize, Debug)]
struct OrderResponse {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    parcel_number: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize, Debug)]
struct StockCheckRequest {
    sku: String,
    quantity: i32,
}

#[derive(Deserialize, Debug)]
struct StockCheckResponse {
    available: bool,
    #[allow(dead_code)]
    current: i32,
}

struct HeaderInjector<'a>(&'a mut reqwest::header::HeaderMap);

impl<'a> Injector for HeaderInjector<'a> {
    fn set(&mut self, key: &str, value: String) {
        if let Ok(name) = reqwest::header::HeaderName::from_bytes(key.as_bytes()) {
            if let Ok(val) = reqwest::header::HeaderValue::from_str(&value) {
                self.0.insert(name, val);
            }
        }
    }
}

fn inject_context(headers: &mut reqwest::header::HeaderMap) {
    let cx = Span::current().context();
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(&cx, &mut HeaderInjector(headers));
    });
}

#[instrument(skip(state), fields(sku = %sku, quantity = %quantity))]
async fn check_stock(state: &AppState, sku: &str, quantity: i32) -> Result<bool, reqwest::Error> {
    let req = StockCheckRequest {
        sku: sku.to_string(),
        quantity,
    };

    let mut headers = reqwest::header::HeaderMap::new();
    inject_context(&mut headers);

    let url = format!("{}/check", state.stock_api_url);
    info!(http.method = "POST", http.url = %url, "Calling stock service to check availability");

    let resp: StockCheckResponse = state
        .client
        .post(&url)
        .headers(headers)
        .json(&req)
        .send()
        .await?
        .json()
        .await?;

    info!(stock.available = %resp.available, stock.current = %resp.current, "Stock check completed");
    Ok(resp.available)
}

#[instrument(skip(state, req), fields(sku = %req.sku, quantity = %req.quantity, user_id = %req.user_id))]
async fn create_order(state: &AppState, req: &OrderRequest) -> Result<OrderResponse, reqwest::Error> {
    let mut headers = reqwest::header::HeaderMap::new();
    inject_context(&mut headers);

    let url = format!("{}/create", state.order_api_url);
    info!(http.method = "POST", http.url = %url, "Calling order service to create order");

    let resp: OrderResponse = state
        .client
        .post(&url)
        .headers(headers)
        .json(req)
        .send()
        .await?
        .json()
        .await?;

    if resp.success {
        info!(order.parcel_number = ?resp.parcel_number, "Order created successfully");
    } else {
        info!(order.error = ?resp.error, "Order creation failed");
    }
    Ok(resp)
}

#[instrument(skip(state), fields(
    http.method = "POST",
    http.route = "/order",
    order.sku = %req.sku,
    order.quantity = %req.quantity,
    order.user_id = %req.user_id
))]
async fn order(State(state): State<AppState>, Json(req): Json<OrderRequest>) -> Json<OrderResponse> {
    info!("Received order request");

    let available = match check_stock(&state, &req.sku, req.quantity).await {
        Ok(available) => available,
        Err(e) => {
            error!(error = %e, "Stock service unavailable");
            return Json(OrderResponse {
                success: false,
                parcel_number: None,
                error: Some("stock service unavailable".to_string()),
            });
        }
    };

    if !available {
        info!("Product not available in requested quantity");
        return Json(OrderResponse {
            success: false,
            parcel_number: None,
            error: Some("product not available".to_string()),
        });
    }

    match create_order(&state, &req).await {
        Ok(resp) => {
            info!(success = %resp.success, "Order request completed");
            Json(resp)
        }
        Err(e) => {
            error!(error = %e, "Order service unavailable");
            Json(OrderResponse {
                success: false,
                parcel_number: None,
                error: Some("order service unavailable".to_string()),
            })
        }
    }
}

fn init_telemetry() -> Option<(TracerProvider, LoggerProvider)> {
    let endpoint = match std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(ep) => ep,
        Err(_) => {
            eprintln!("[{}] OTEL_EXPORTER_OTLP_ENDPOINT not set, OTEL instrumentation disabled", SERVICE_NAME);
            return None;
        }
    };

    println!("[{}] OTEL instrumentation enabled, sending data to {}", SERVICE_NAME, endpoint);

    let resource = Resource::new(vec![
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_NAME,
            SERVICE_NAME,
        ),
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_VERSION,
            env!("CARGO_PKG_VERSION"),
        ),
    ]);

    global::set_text_map_propagator(TraceContextPropagator::new());

    let span_exporter = match SpanExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create span exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let tracer_provider = TracerProvider::builder()
        .with_batch_exporter(span_exporter, runtime::Tokio)
        .with_resource(resource.clone())
        .build();

    global::set_tracer_provider(tracer_provider.clone());

    let log_exporter = match LogExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create log exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let logger_provider = LoggerProvider::builder()
        .with_batch_exporter(log_exporter, runtime::Tokio)
        .with_resource(resource)
        .build();

    Some((tracer_provider, logger_provider))
}

#[tokio::main]
async fn main() {
    let telemetry = init_telemetry();

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    let registry = tracing_subscriber::registry().with(env_filter);

    if let Some((ref tracer_provider, ref logger_provider)) = telemetry {
        let tracer = tracer_provider.tracer(SERVICE_NAME);
        let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);
        let log_layer = OpenTelemetryTracingBridge::new(logger_provider);

        registry
            .with(telemetry_layer)
            .with(log_layer)
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    } else {
        registry
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    }

    info!("Starting {} service", SERVICE_NAME);

    let state = AppState {
        stock_api_url: std::env::var("STOCK_API_URL")
            .unwrap_or_else(|_| "http://localhost:8081".to_string()),
        order_api_url: std::env::var("ORDER_API_URL")
            .unwrap_or_else(|_| "http://localhost:8082".to_string()),
        client: reqwest::Client::new(),
    };

    let app = Router::new()
        .route("/order", post(order))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:8080")
        .await
        .unwrap();

    info!(http.host = "127.0.0.1", http.port = 8080, "Listening for requests");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();

    info!("Shutting down {} service", SERVICE_NAME);

    if let Some((tracer_provider, logger_provider)) = telemetry {
        let _ = tracer_provider.shutdown();
        let _ = logger_provider.shutdown();
    }
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to install CTRL+C signal handler");
}
EOF

# Update order service with OTEL instrumentation
cat > /workdir/order/Cargo.toml << 'EOF'
[package]
name = "order"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
axum-extra = { version = "0.9", features = ["typed-header"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["json"] }

# OpenTelemetry
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["http-proto", "reqwest-client", "logs"] }
opentelemetry-semantic-conventions = "0.27"
opentelemetry-appender-tracing = "0.27"

# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-opentelemetry = "0.28"
EOF

cat > /workdir/order/src/main.rs << 'EOF'
use axum::{
    extract::State,
    http::HeaderMap,
    routing::post,
    Json, Router,
};
use opentelemetry::{
    global,
    propagation::{Extractor, Injector},
    trace::TracerProvider as _,
    KeyValue,
};
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_otlp::{LogExporter, SpanExporter, Protocol, WithExportConfig};
use opentelemetry_sdk::{
    logs::LoggerProvider,
    propagation::TraceContextPropagator,
    runtime,
    trace::TracerProvider,
    Resource,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::{Mutex, RwLock};
use tracing::{info, error, instrument, Span};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const SERVICE_NAME: &str = "order";

#[derive(Clone)]
struct AppState {
    orders: Arc<RwLock<HashMap<String, OrderRequest>>>,
    order_counter: Arc<Mutex<u64>>,
    stock_api_url: String,
    client: reqwest::Client,
}

#[derive(Clone, Deserialize, Serialize, Debug)]
struct OrderRequest {
    sku: String,
    quantity: i32,
    user_id: String,
}

#[derive(Serialize, Debug)]
struct OrderResponse {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    parcel_number: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize, Debug)]
struct StockUpdateRequest {
    sku: String,
    quantity: i32,
}

#[derive(Deserialize, Debug)]
struct StockUpdateResponse {
    success: bool,
    #[allow(dead_code)]
    current: i32,
}

struct HeaderExtractor<'a>(&'a HeaderMap);

impl<'a> Extractor for HeaderExtractor<'a> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|v| v.to_str().ok())
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(|k| k.as_str()).collect()
    }
}

struct HeaderInjector<'a>(&'a mut reqwest::header::HeaderMap);

impl<'a> Injector for HeaderInjector<'a> {
    fn set(&mut self, key: &str, value: String) {
        if let Ok(name) = reqwest::header::HeaderName::from_bytes(key.as_bytes()) {
            if let Ok(val) = reqwest::header::HeaderValue::from_str(&value) {
                self.0.insert(name, val);
            }
        }
    }
}

fn extract_context(headers: &HeaderMap) {
    let parent_cx = global::get_text_map_propagator(|propagator| {
        propagator.extract(&HeaderExtractor(headers))
    });
    Span::current().set_parent(parent_cx);
}

fn inject_context(headers: &mut reqwest::header::HeaderMap) {
    let cx = Span::current().context();
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(&cx, &mut HeaderInjector(headers));
    });
}

#[instrument(skip(state), fields(sku = %sku, quantity = %quantity))]
async fn decrease_stock(state: &AppState, sku: &str, quantity: i32) -> Result<bool, reqwest::Error> {
    let req = StockUpdateRequest {
        sku: sku.to_string(),
        quantity,
    };

    let mut headers = reqwest::header::HeaderMap::new();
    inject_context(&mut headers);

    let url = format!("{}/decrease", state.stock_api_url);
    info!(http.method = "POST", http.url = %url, "Calling stock service to decrease inventory");

    let resp: StockUpdateResponse = state
        .client
        .post(&url)
        .headers(headers)
        .json(&req)
        .send()
        .await?
        .json()
        .await?;

    info!(stock.success = %resp.success, stock.current = %resp.current, "Stock decrease completed");
    Ok(resp.success)
}

#[instrument(skip(state, headers), fields(
    http.method = "POST",
    http.route = "/create",
    order.sku = %req.sku,
    order.quantity = %req.quantity,
    order.user_id = %req.user_id
))]
async fn create_order(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<OrderRequest>,
) -> Json<OrderResponse> {
    extract_context(&headers);

    info!("Received order creation request");

    let success = match decrease_stock(&state, &req.sku, req.quantity).await {
        Ok(success) => success,
        Err(e) => {
            error!(error = %e, "Stock service unavailable");
            return Json(OrderResponse {
                success: false,
                parcel_number: None,
                error: Some("stock service unavailable".to_string()),
            });
        }
    };

    if !success {
        info!("Insufficient stock for order");
        return Json(OrderResponse {
            success: false,
            parcel_number: None,
            error: Some("insufficient stock".to_string()),
        });
    }

    let parcel_number = {
        let mut counter = state.order_counter.lock().await;
        *counter += 1;
        format!("PARCEL-{}", *counter)
    };

    {
        let mut orders = state.orders.write().await;
        orders.insert(parcel_number.clone(), req);
    }

    info!(order.parcel_number = %parcel_number, "Order created successfully");

    Json(OrderResponse {
        success: true,
        parcel_number: Some(parcel_number),
        error: None,
    })
}

fn init_telemetry() -> Option<(TracerProvider, LoggerProvider)> {
    let endpoint = match std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(ep) => ep,
        Err(_) => {
            eprintln!("[{}] OTEL_EXPORTER_OTLP_ENDPOINT not set, OTEL instrumentation disabled", SERVICE_NAME);
            return None;
        }
    };

    println!("[{}] OTEL instrumentation enabled, sending data to {}", SERVICE_NAME, endpoint);

    let resource = Resource::new(vec![
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_NAME,
            SERVICE_NAME,
        ),
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_VERSION,
            env!("CARGO_PKG_VERSION"),
        ),
    ]);

    global::set_text_map_propagator(TraceContextPropagator::new());

    let span_exporter = match SpanExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create span exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let tracer_provider = TracerProvider::builder()
        .with_batch_exporter(span_exporter, runtime::Tokio)
        .with_resource(resource.clone())
        .build();

    global::set_tracer_provider(tracer_provider.clone());

    let log_exporter = match LogExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create log exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let logger_provider = LoggerProvider::builder()
        .with_batch_exporter(log_exporter, runtime::Tokio)
        .with_resource(resource)
        .build();

    Some((tracer_provider, logger_provider))
}

#[tokio::main]
async fn main() {
    let telemetry = init_telemetry();

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    let registry = tracing_subscriber::registry().with(env_filter);

    if let Some((ref tracer_provider, ref logger_provider)) = telemetry {
        let tracer = tracer_provider.tracer(SERVICE_NAME);
        let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);
        let log_layer = OpenTelemetryTracingBridge::new(logger_provider);

        registry
            .with(telemetry_layer)
            .with(log_layer)
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    } else {
        registry
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    }

    info!("Starting {} service", SERVICE_NAME);

    let state = AppState {
        orders: Arc::new(RwLock::new(HashMap::new())),
        order_counter: Arc::new(Mutex::new(0)),
        stock_api_url: std::env::var("STOCK_API_URL")
            .unwrap_or_else(|_| "http://localhost:8081".to_string()),
        client: reqwest::Client::new(),
    };

    let app = Router::new()
        .route("/create", post(create_order))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:8082")
        .await
        .unwrap();

    info!(http.host = "127.0.0.1", http.port = 8082, "Listening for requests");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();

    info!("Shutting down {} service", SERVICE_NAME);

    if let Some((tracer_provider, logger_provider)) = telemetry {
        let _ = tracer_provider.shutdown();
        let _ = logger_provider.shutdown();
    }
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to install CTRL+C signal handler");
}
EOF

# Update stock service with OTEL instrumentation
cat > /workdir/stock/Cargo.toml << 'EOF'
[package]
name = "stock"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# OpenTelemetry
opentelemetry = "0.27"
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["http-proto", "reqwest-client", "logs"] }
opentelemetry-semantic-conventions = "0.27"
opentelemetry-appender-tracing = "0.27"

# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-opentelemetry = "0.28"
EOF

cat > /workdir/stock/src/main.rs << 'EOF'
use axum::{
    extract::State,
    http::HeaderMap,
    routing::post,
    Json, Router,
};
use opentelemetry::{
    global,
    propagation::Extractor,
    trace::TracerProvider as _,
    KeyValue,
};
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_otlp::{LogExporter, SpanExporter, Protocol, WithExportConfig};
use opentelemetry_sdk::{
    logs::LoggerProvider,
    propagation::TraceContextPropagator,
    runtime,
    trace::TracerProvider,
    Resource,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tracing::{info, instrument, Span};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const SERVICE_NAME: &str = "stock";

#[derive(Clone)]
struct AppState {
    products: Arc<RwLock<HashMap<String, i32>>>,
}

#[derive(Deserialize, Debug)]
struct CheckRequest {
    sku: String,
    quantity: i32,
}

#[derive(Serialize, Debug)]
struct CheckResponse {
    available: bool,
    current: i32,
}

#[derive(Deserialize, Debug)]
struct UpdateRequest {
    sku: String,
    quantity: i32,
}

#[derive(Serialize, Debug)]
struct UpdateResponse {
    success: bool,
    current: i32,
}

struct HeaderExtractor<'a>(&'a HeaderMap);

impl<'a> Extractor for HeaderExtractor<'a> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|v| v.to_str().ok())
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(|k| k.as_str()).collect()
    }
}

fn extract_context(headers: &HeaderMap) {
    let parent_cx = global::get_text_map_propagator(|propagator| {
        propagator.extract(&HeaderExtractor(headers))
    });
    Span::current().set_parent(parent_cx);
}

#[instrument(skip(state, headers), fields(
    http.method = "POST",
    http.route = "/check",
    stock.sku = %req.sku,
    stock.quantity_requested = %req.quantity
))]
async fn check_availability(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CheckRequest>,
) -> Json<CheckResponse> {
    extract_context(&headers);

    info!("Checking stock availability");

    let products = state.products.read().await;
    let current = products.get(&req.sku).copied().unwrap_or(0);
    let available = current >= req.quantity;

    info!(
        stock.current = %current,
        stock.available = %available,
        "Stock check completed"
    );

    Json(CheckResponse { available, current })
}

#[instrument(skip(state, headers), fields(
    http.method = "POST",
    http.route = "/decrease",
    stock.sku = %req.sku,
    stock.quantity = %req.quantity
))]
async fn decrease(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<UpdateRequest>,
) -> Json<UpdateResponse> {
    extract_context(&headers);

    info!("Decreasing stock");

    let mut products = state.products.write().await;
    let current = products.get(&req.sku).copied().unwrap_or(0);

    if current >= req.quantity {
        let new_value = current - req.quantity;
        products.insert(req.sku.clone(), new_value);
        info!(
            stock.previous = %current,
            stock.new = %new_value,
            "Stock decreased successfully"
        );
        Json(UpdateResponse {
            success: true,
            current: new_value,
        })
    } else {
        info!(
            stock.current = %current,
            stock.requested = %req.quantity,
            "Insufficient stock for decrease"
        );
        Json(UpdateResponse {
            success: false,
            current,
        })
    }
}

#[instrument(skip(state, headers), fields(
    http.method = "POST",
    http.route = "/increase",
    stock.sku = %req.sku,
    stock.quantity = %req.quantity
))]
async fn increase(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<UpdateRequest>,
) -> Json<UpdateResponse> {
    extract_context(&headers);

    info!("Increasing stock");

    let mut products = state.products.write().await;
    let current = products.get(&req.sku).copied().unwrap_or(0);
    let new_value = current + req.quantity;
    products.insert(req.sku.clone(), new_value);

    info!(
        stock.previous = %current,
        stock.new = %new_value,
        "Stock increased successfully"
    );

    Json(UpdateResponse {
        success: true,
        current: new_value,
    })
}

fn init_telemetry() -> Option<(TracerProvider, LoggerProvider)> {
    let endpoint = match std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(ep) => ep,
        Err(_) => {
            eprintln!("[{}] OTEL_EXPORTER_OTLP_ENDPOINT not set, OTEL instrumentation disabled", SERVICE_NAME);
            return None;
        }
    };

    println!("[{}] OTEL instrumentation enabled, sending data to {}", SERVICE_NAME, endpoint);

    let resource = Resource::new(vec![
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_NAME,
            SERVICE_NAME,
        ),
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_VERSION,
            env!("CARGO_PKG_VERSION"),
        ),
    ]);

    global::set_text_map_propagator(TraceContextPropagator::new());

    let span_exporter = match SpanExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create span exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let tracer_provider = TracerProvider::builder()
        .with_batch_exporter(span_exporter, runtime::Tokio)
        .with_resource(resource.clone())
        .build();

    global::set_tracer_provider(tracer_provider.clone());

    let log_exporter = match LogExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(&endpoint)
        .build()
    {
        Ok(exp) => exp,
        Err(e) => {
            eprintln!("[{}] Failed to create log exporter: {}", SERVICE_NAME, e);
            return None;
        }
    };

    let logger_provider = LoggerProvider::builder()
        .with_batch_exporter(log_exporter, runtime::Tokio)
        .with_resource(resource)
        .build();

    Some((tracer_provider, logger_provider))
}

#[tokio::main]
async fn main() {
    let telemetry = init_telemetry();

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    let registry = tracing_subscriber::registry().with(env_filter);

    if let Some((ref tracer_provider, ref logger_provider)) = telemetry {
        let tracer = tracer_provider.tracer(SERVICE_NAME);
        let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);
        let log_layer = OpenTelemetryTracingBridge::new(logger_provider);

        registry
            .with(telemetry_layer)
            .with(log_layer)
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    } else {
        registry
            .with(tracing_subscriber::fmt::layer().with_target(true))
            .init();
    }

    info!("Starting {} service", SERVICE_NAME);

    let mut initial_stock = HashMap::new();
    initial_stock.insert("SKU001".to_string(), 100);
    initial_stock.insert("SKU002".to_string(), 50);
    initial_stock.insert("SKU003".to_string(), 200);

    info!(
        stock.sku001 = 100,
        stock.sku002 = 50,
        stock.sku003 = 200,
        "Initialized stock inventory"
    );

    let state = AppState {
        products: Arc::new(RwLock::new(initial_stock)),
    };

    let app = Router::new()
        .route("/check", post(check_availability))
        .route("/decrease", post(decrease))
        .route("/increase", post(increase))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:8081")
        .await
        .unwrap();

    info!(http.host = "127.0.0.1", http.port = 8081, "Listening for requests");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();

    info!("Shutting down {} service", SERVICE_NAME);

    if let Some((tracer_provider, logger_provider)) = telemetry {
        let _ = tracer_provider.shutdown();
        let _ = logger_provider.shutdown();
    }
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to install CTRL+C signal handler");
}
EOF

# Format all services
cd /workdir/gateway && cargo fmt
cd /workdir/order && cargo fmt
cd /workdir/stock && cargo fmt

# Build all services
cd /workdir
cargo build --manifest-path gateway/Cargo.toml
cargo build --manifest-path order/Cargo.toml
cargo build --manifest-path stock/Cargo.toml