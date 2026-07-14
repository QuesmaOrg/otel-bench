use axum::{extract::State, routing::post, Json, Router};
use serde::{Deserialize, Serialize};

#[derive(Clone)]
struct AppState {
    stock_api_url: String,
    order_api_url: String,
    client: reqwest::Client,
}

#[derive(Deserialize, Serialize)]
struct OrderRequest {
    sku: String,
    quantity: i32,
    user_id: String,
}

#[derive(Deserialize, Serialize)]
struct OrderResponse {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    parcel_number: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
struct StockCheckRequest {
    sku: String,
    quantity: i32,
}

#[derive(Deserialize)]
struct StockCheckResponse {
    available: bool,
    #[allow(dead_code)]
    current: i32,
}

async fn check_stock(state: &AppState, sku: &str, quantity: i32) -> Result<bool, reqwest::Error> {
    let req = StockCheckRequest {
        sku: sku.to_string(),
        quantity,
    };

    let resp: StockCheckResponse = state
        .client
        .post(format!("{}/check", state.stock_api_url))
        .json(&req)
        .send()
        .await?
        .json()
        .await?;

    Ok(resp.available)
}

async fn create_order(state: &AppState, req: &OrderRequest) -> Result<OrderResponse, reqwest::Error> {
    let resp: OrderResponse = state
        .client
        .post(format!("{}/create", state.order_api_url))
        .json(req)
        .send()
        .await?
        .json()
        .await?;

    Ok(resp)
}

async fn order(State(state): State<AppState>, Json(req): Json<OrderRequest>) -> Json<OrderResponse> {
    let available = match check_stock(&state, &req.sku, req.quantity).await {
        Ok(available) => available,
        Err(_) => {
            return Json(OrderResponse {
                success: false,
                parcel_number: None,
                error: Some("stock service unavailable".to_string()),
            });
        }
    };

    if !available {
        return Json(OrderResponse {
            success: false,
            parcel_number: None,
            error: Some("product not available".to_string()),
        });
    }

    match create_order(&state, &req).await {
        Ok(resp) => Json(resp),
        Err(_) => Json(OrderResponse {
            success: false,
            parcel_number: None,
            error: Some("order service unavailable".to_string()),
        }),
    }
}

#[tokio::main]
async fn main() {
    let state = AppState {
        stock_api_url: "http://localhost:8081".to_string(),
        order_api_url: "http://localhost:8082".to_string(),
        client: reqwest::Client::new(),
    };

    let app = Router::new()
        .route("/order", post(order))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:8080")
        .await
        .unwrap();
    axum::serve(listener, app).await.unwrap();
}
