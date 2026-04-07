"""
Checkout Service — the kitchen orchestrator (UPGRADED).

Production-grade enhancements:
  - Structured JSON logging (machine-readable, grep-friendly)
  - Circuit breaker pattern (pybreaker) on dependency calls
  - Retry with exponential backoff for transient failures
  - Graceful fallback when pricing is unavailable (cached/default prices)
  - Startup probe compatibility (separate from readiness)
"""

import os
import asyncio
import time
import json
import logging

import httpx
import pybreaker
import psycopg2
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# ── Config ──────────────────────────────────────────────────────
PRICING_URL = os.getenv("PRICING_URL", "http://pricing-svc")
INVENTORY_URL = os.getenv("INVENTORY_URL", "http://inventory-svc")
DB_HOST = os.getenv("DB_HOST", "postgres-svc")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("POSTGRES_DB", "checkoutdb")
DB_USER = os.getenv("POSTGRES_USER", "checkout")
DB_PASS = os.getenv("POSTGRES_PASSWORD", "changeme")
TIMEOUT_SECONDS = float(os.getenv("DEPENDENCY_TIMEOUT", "3.0"))
RETRY_MAX = int(os.getenv("RETRY_MAX", "2"))
RETRY_BACKOFF = float(os.getenv("RETRY_BACKOFF", "0.5"))
SERVICE_NAME = "checkout"

# ── Structured JSON Logging ─────────────────────────────────────
# Every log line is a JSON object with consistent fields.
# This makes logs parseable by Loki, ELK, CloudWatch, etc.
# Think of it like every receipt in the café having the same format:
# date, counter, staff member, action, details.
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_entry = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
        }
        if hasattr(record, "request_id"):
            log_entry["request_id"] = record.request_id
        if hasattr(record, "extra_data"):
            log_entry.update(record.extra_data)
        return json.dumps(log_entry)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger(SERVICE_NAME)
logger.handlers = [handler]
logger.setLevel(logging.INFO)

# ── Circuit Breaker ─────────────────────────────────────────────
# Tracks recent failures per dependency. Opens after 3 consecutive
# failures, rejects calls for 30s, then half-opens to test recovery.
class CircuitBreakerLogger(pybreaker.CircuitBreakerListener):
    def state_change(self, cb, old_state, new_state):
        logger.warning(
            "Circuit breaker '%s' state: %s -> %s",
            cb.name, old_state.name, new_state.name,
            extra={"extra_data": {
                "event": "circuit_breaker_state_change",
                "breaker": cb.name,
                "old_state": old_state.name,
                "new_state": new_state.name,
            }}
        )

pricing_breaker = pybreaker.CircuitBreaker(
    fail_max=3, reset_timeout=30, name="pricing",
    listeners=[CircuitBreakerLogger()],
)

inventory_breaker = pybreaker.CircuitBreaker(
    fail_max=3, reset_timeout=30, name="inventory",
    listeners=[CircuitBreakerLogger()],
)

# ── Fallback Prices ─────────────────────────────────────────────
# When pricing is unavailable (cold start, circuit open), return
# cached defaults instead of a hard failure. Graceful degradation.
FALLBACK_PRICES = {
    "WM-100": 29.99, "BH-200": 49.99, "UC-300": 9.99,
    "MK-400": 199.99, "PS-500": 14.50,
}

# ── App ─────────────────────────────────────────────────────────
app = FastAPI(title="Checkout Service")
http_client = httpx.AsyncClient(timeout=TIMEOUT_SECONDS)


class CheckoutRequest(BaseModel):
    item_id: str
    quantity: int = 1


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT,
        dbname=DB_NAME, user=DB_USER, password=DB_PASS,
    )


def init_db():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS checkout_audit (
                id SERIAL PRIMARY KEY,
                request_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                quantity INTEGER NOT NULL,
                price NUMERIC,
                stock_available INTEGER,
                result TEXT NOT NULL,
                fallback_used BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT NOW()
            )
        """)
        conn.commit()
        cur.close()
        conn.close()
        logger.info("Database initialized")
    except Exception as e:
        logger.warning("DB init deferred: %s", e)


@app.on_event("startup")
async def startup():
    init_db()


def write_audit(request_id, item_id, quantity, price, stock, result, fallback_used=False):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO checkout_audit
               (request_id, item_id, quantity, price, stock_available, result, fallback_used)
               VALUES (%s, %s, %s, %s, %s, %s, %s)""",
            (request_id, item_id, quantity, price, stock, result, fallback_used),
        )
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        logger.error("Audit write failed: %s", e, extra={"request_id": request_id})


async def call_with_retry(func, retries=RETRY_MAX, backoff=RETRY_BACKOFF):
    """Retry with exponential backoff. Handles KEDA cold-start race."""
    last_exc = None
    for attempt in range(retries + 1):
        try:
            return await func()
        except (httpx.ConnectError, httpx.ReadTimeout, pybreaker.CircuitBreakerError) as e:
            last_exc = e
            if attempt < retries:
                wait = backoff * (2 ** attempt)
                logger.info("Retry %d/%d in %.1fs: %s", attempt + 1, retries, wait, type(e).__name__)
                await asyncio.sleep(wait)
    raise last_exc


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/ready")
async def readiness():
    """Readiness probe — verifies Postgres connectivity."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return {"status": "ready", "service": SERVICE_NAME}
    except Exception:
        return JSONResponse(
            content={"status": "not_ready", "service": SERVICE_NAME},
            status_code=503,
        )


@app.post("/checkout")
async def checkout(payload: CheckoutRequest, request: Request):
    request_id = request.headers.get("x-request-id", "unknown")
    item_id = payload.item_id
    quantity = payload.quantity

    logger.info(
        "Checkout start: item=%s qty=%d", item_id, quantity,
        extra={"request_id": request_id, "extra_data": {
            "event": "checkout_start", "item_id": item_id, "quantity": quantity,
        }}
    )

    if not item_id:
        return JSONResponse(content={"error": "item_id is required", "request_id": request_id}, status_code=400)
    if quantity < 1:
        return JSONResponse(content={"error": "quantity must be >= 1", "request_id": request_id}, status_code=400)

    headers = {"X-Request-Id": request_id}
    start_time = time.time()
    fallback_used = False

    # ── Dependency calls with circuit breaker ────────────────
    async def call_pricing():
        @pricing_breaker
        async def _call():
            resp = await http_client.get(
                f"{PRICING_URL}/price", params={"item_id": item_id}, headers=headers,
            )
            return resp.json()
        return await _call()

    async def call_inventory():
        @inventory_breaker
        async def _call():
            resp = await http_client.get(
                f"{INVENTORY_URL}/stock", params={"item_id": item_id}, headers=headers,
            )
            return resp.json()
        return await _call()

    pricing_result = None
    inventory_result = None
    errors = []

    results = await asyncio.gather(
        call_with_retry(call_pricing),
        call_with_retry(call_inventory),
        return_exceptions=True,
    )

    # ── Pricing: fallback if unavailable ─────────────────────
    if isinstance(results[0], Exception):
        err_type = type(results[0]).__name__
        if item_id in FALLBACK_PRICES:
            pricing_result = {"item_id": item_id, "price": FALLBACK_PRICES[item_id]}
            fallback_used = True
            logger.info(
                "Fallback price: %.2f for %s", FALLBACK_PRICES[item_id], item_id,
                extra={"request_id": request_id, "extra_data": {
                    "event": "fallback_price", "item_id": item_id,
                }}
            )
        else:
            errors.append(f"pricing: {err_type}")
    else:
        pricing_result = results[0]

    # ── Inventory: no fallback (stock must be live) ──────────
    if isinstance(results[1], Exception):
        errors.append(f"inventory: {type(results[1]).__name__}")
    else:
        inventory_result = results[1]

    elapsed = time.time() - start_time

    if errors:
        write_audit(request_id, item_id, quantity, None, None,
                     f"error: {', '.join(errors)}", fallback_used)
        status = 504 if "Timeout" in str(errors) else 503
        return JSONResponse(
            content={"error": "dependency failure", "details": errors,
                     "request_id": request_id, "elapsed_ms": round(elapsed * 1000)},
            status_code=status,
        )

    price = pricing_result.get("price", 0)
    stock = inventory_result.get("stock", 0)

    if stock < quantity:
        write_audit(request_id, item_id, quantity, price, stock, "out_of_stock", fallback_used)
        return JSONResponse(
            content={"error": "insufficient stock", "item_id": item_id,
                     "requested": quantity, "available": stock, "request_id": request_id},
            status_code=409,
        )

    total = round(price * quantity, 2)
    logger.info(
        "Checkout success: total=%.2f", total,
        extra={"request_id": request_id, "extra_data": {
            "event": "checkout_success", "item_id": item_id,
            "total": total, "elapsed_ms": round(elapsed * 1000),
            "fallback_used": fallback_used,
        }}
    )
    write_audit(request_id, item_id, quantity, price, stock, "success", fallback_used)

    return {
        "status": "success", "item_id": item_id, "quantity": quantity,
        "unit_price": price, "total": total,
        "stock_remaining": stock - quantity, "request_id": request_id,
        "elapsed_ms": round(elapsed * 1000), "fallback_price_used": fallback_used,
    }
