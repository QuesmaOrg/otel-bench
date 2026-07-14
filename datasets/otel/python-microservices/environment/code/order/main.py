from fastapi import FastAPI
from pydantic import BaseModel, Field
from threading import Lock
import httpx

app = FastAPI()

orders: dict[str, dict] = {}
order_counter = 0
lock = Lock()
stock_api_url = "http://localhost:8081"


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


class StockUpdateRequest(BaseModel):
    sku: str
    quantity: int


class StockUpdateResponse(BaseModel):
    success: bool
    current: int


@app.post("/create", response_model=OrderResponse)
def create(req: OrderRequest) -> OrderResponse:
    global order_counter

    try:
        with httpx.Client() as client:
            resp = client.post(
                f"{stock_api_url}/decrease",
                json={"sku": req.sku, "quantity": req.quantity},
            )
            stock_resp = StockUpdateResponse(**resp.json())
    except Exception:
        return OrderResponse(success=False, error="stock service unavailable")

    if not stock_resp.success:
        return OrderResponse(success=False, error="insufficient stock")

    with lock:
        order_counter += 1
        parcel_number = f"PARCEL-{order_counter}"
        orders[parcel_number] = {
            "sku": req.sku,
            "quantity": req.quantity,
            "user_id": req.user_id,
        }

    return OrderResponse(success=True, parcel_number=parcel_number)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8082)
