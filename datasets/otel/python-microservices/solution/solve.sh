#!/bin/bash
set -e

cat <<EOF >> stock/requirements.txt
opentelemetry-api
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-http
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-logging
EOF

cat <<EOF >> order/requirements.txt
opentelemetry-api
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-http
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-logging
opentelemetry-instrumentation-httpx
EOF

cat <<EOF >> gateway/requirements.txt
opentelemetry-api
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-http
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-logging
opentelemetry-instrumentation-httpx
EOF

cat <<EOF > stock/main.py
import os
import logging
from fastapi import FastAPI
from pydantic import BaseModel
from threading import Lock
import uvicorn

from opentelemetry import trace
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor

# Configuration
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
SERVICE_NAME_VAL = "stock-service"

print(f"OTEL Instrumentation enabled for {SERVICE_NAME_VAL}. Sending to {OTEL_ENDPOINT}")

resource = Resource(attributes={
    SERVICE_NAME: SERVICE_NAME_VAL
})

# Tracing Provider
trace_provider = TracerProvider(resource=resource)
trace_exporter = OTLPSpanExporter(endpoint=f"{OTEL_ENDPOINT}/v1/traces")
trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(trace_provider)

# Logging Provider
logger_provider = LoggerProvider(resource=resource)
log_exporter = OTLPLogExporter(endpoint=f"{OTEL_ENDPOINT}/v1/logs")
logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
set_logger_provider(logger_provider)

# Logging Handler
handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.INFO)

# Instrument standard logging
LoggingInstrumentor().instrument(set_logging_packages=True)

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)

logger = logging.getLogger(__name__)

products: dict[str, int] = {
    "SKU001": 100,
    "SKU002": 50,
    "SKU003": 200,
}
lock = Lock()


class CheckRequest(BaseModel):
    sku: str
    quantity: int


class CheckResponse(BaseModel):
    available: bool
    current: int


class UpdateRequest(BaseModel):
    sku: str
    quantity: int


class UpdateResponse(BaseModel):
    success: bool
    current: int

@app.on_event("startup")
async def startup():
    logger.info("Stock service started")

@app.on_event("shutdown")
async def shutdown():
    logger.info("Stock service stopped")

@app.post("/check", response_model=CheckResponse)
def check(req: CheckRequest) -> CheckResponse:
    with lock:
        current = products.get(req.sku, 0)
        available = req.sku in products and current >= req.quantity
    return CheckResponse(available=available, current=current)


@app.post("/decrease", response_model=UpdateResponse)
def decrease(req: UpdateRequest) -> UpdateResponse:
    with lock:
        current = products.get(req.sku, 0)
        if req.sku in products and current >= req.quantity:
            products[req.sku] = current - req.quantity
            return UpdateResponse(success=True, current=products[req.sku])
        return UpdateResponse(success=False, current=current)


@app.post("/increase", response_model=UpdateResponse)
def increase(req: UpdateRequest) -> UpdateResponse:
    with lock:
        current = products.get(req.sku, 0)
        products[req.sku] = current + req.quantity
        return UpdateResponse(success=True, current=products[req.sku])


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8081)
EOF

cat <<EOF > order/main.py
import os
import logging
from fastapi import FastAPI
from pydantic import BaseModel, Field
from threading import Lock
import httpx
import uvicorn

from opentelemetry import trace
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

# Configuration
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
SERVICE_NAME_VAL = "order-service"

print(f"OTEL Instrumentation enabled for {SERVICE_NAME_VAL}. Sending to {OTEL_ENDPOINT}")

resource = Resource(attributes={
    SERVICE_NAME: SERVICE_NAME_VAL
})

# Tracing Provider
trace_provider = TracerProvider(resource=resource)
trace_exporter = OTLPSpanExporter(endpoint=f"{OTEL_ENDPOINT}/v1/traces")
trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(trace_provider)

# Logging Provider
logger_provider = LoggerProvider(resource=resource)
log_exporter = OTLPLogExporter(endpoint=f"{OTEL_ENDPOINT}/v1/logs")
logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
set_logger_provider(logger_provider)

# Logging Handler
handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.INFO)

# Instrumentations
LoggingInstrumentor().instrument(set_logging_packages=True)
HTTPXClientInstrumentor().instrument()

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)

logger = logging.getLogger(__name__)

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

@app.on_event("startup")
async def startup():
    logger.info("Order service started")

@app.on_event("shutdown")
async def shutdown():
    logger.info("Order service stopped")

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
    uvicorn.run(app, host="127.0.0.1", port=8082)
EOF

cat <<EOF > gateway/main.py
import os
import logging
from fastapi import FastAPI
from pydantic import BaseModel, Field
import httpx
import uvicorn
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from opentelemetry import trace
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

# Configuration
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
SERVICE_NAME_VAL = "gateway-service"

print(f"OTEL Instrumentation enabled for {SERVICE_NAME_VAL}. Sending to {OTEL_ENDPOINT}")

resource = Resource(attributes={
    SERVICE_NAME: SERVICE_NAME_VAL
})

# Tracing Provider
trace_provider = TracerProvider(resource=resource)
trace_exporter = OTLPSpanExporter(endpoint=f"{OTEL_ENDPOINT}/v1/traces")
trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(trace_provider)

# Logging Provider
logger_provider = LoggerProvider(resource=resource)
log_exporter = OTLPLogExporter(endpoint=f"{OTEL_ENDPOINT}/v1/logs")
logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
set_logger_provider(logger_provider)

# Logging Handler
handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.INFO)

# Instrumentations
LoggingInstrumentor().instrument(set_logging_packages=True)
HTTPXClientInstrumentor().instrument()

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)

logger = logging.getLogger(__name__)

class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        logger.info(f"Request: {request.method} {request.url}")
        response = await call_next(request)
        logger.info(f"Response: {response.status_code}")
        return response

app.add_middleware(LoggingMiddleware)

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

@app.on_event("startup")
async def startup():
    logger.info("Gateway service started")

@app.on_event("shutdown")
async def shutdown():
    logger.info("Gateway service stopped")

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
    uvicorn.run(app, host="127.0.0.1", port=8080)
EOF

sed -i 's/python main.py/python3 main.py/g' stock/Makefile order/Makefile gateway/Makefile

make test
