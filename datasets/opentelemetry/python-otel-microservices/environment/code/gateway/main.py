from fastapi import FastAPI
from pydantic import BaseModel, Field
import httpx

app = FastAPI()

stock_api_url = "http://localhost:8081"
order_api_url = "http://localhost:8082"


class OrderRequest(BaseModel):
    sku: str
    quantity: int
    user_id: str = Field(alias="user_id")

    model_config = {"populate_by_name": True}


class OrderResponse(BaseModel):
    success: bool
    parcel_number: str | None = Field(default=None, serialization_alias="parcel_number")
    error: str | None = None

    model_config = {"populate_by_name": True, "by_alias": True}


class StockCheckRequest(BaseModel):
    sku: str
    quantity: int


class StockCheckResponse(BaseModel):
    available: bool
    current: int


@app.post("/order", response_model=OrderResponse)
def order(req: OrderRequest) -> OrderResponse:
    try:
        with httpx.Client() as client:
            resp = client.post(
                f"{stock_api_url}/check",
                json={"sku": req.sku, "quantity": req.quantity},
            )
            stock_resp = StockCheckResponse(**resp.json())
    except Exception:
        return OrderResponse(success=False, error="stock service unavailable")

    if not stock_resp.available:
        return OrderResponse(success=False, error="product not available")

    try:
        with httpx.Client() as client:
            resp = client.post(
                f"{order_api_url}/create",
                json={"sku": req.sku, "quantity": req.quantity, "user_id": req.user_id},
            )
            order_resp = OrderResponse(**resp.json())
    except Exception:
        return OrderResponse(success=False, error="order service unavailable")

    return order_resp


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8080)
