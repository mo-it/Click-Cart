#!/bin/bash
# =============================================================================
# Click-Cart Assignment 2 — Day 2: Observability
# =============================================================================
# Run from ~/Click-Cart on your VM:
#   chmod +x add-observability.sh
#   ./add-observability.sh
#
# WHAT THIS DOES:
# 1. Updates requirements.txt for all 4 services (adds prometheus libraries)
# 2. Updates main.py for all 4 services (adds /metrics endpoint + custom metrics)
# 3. Rebuilds Docker images
# 4. Redeploys to K3s
# 5. Installs Prometheus + Loki + Grafana monitoring stack
# =============================================================================

set -e
cd ~/Click-Cart

echo "================================================"
echo "PHASE 1: Update service code with Prometheus metrics"
echo "================================================"

# =============================================================================
# UPDATE REQUIREMENTS.TXT FILES
# =============================================================================

echo "[1/4] Updating requirements.txt files..."

# Checkout — add prometheus libraries
cat > services/checkout/requirements.txt << 'REQ'
fastapi==0.115.6
uvicorn==0.34.0
httpx==0.28.1
psycopg2-binary==2.9.10
pybreaker==1.2.0
prometheus-fastapi-instrumentator==7.0.2
prometheus-client==0.21.1
REQ

# Gateway — add prometheus libraries
cat > services/gateway/requirements.txt << 'REQ'
fastapi==0.115.6
uvicorn==0.34.0
httpx==0.28.1
prometheus-fastapi-instrumentator==7.0.2
REQ

# Pricing — add prometheus libraries
cat > services/pricing/requirements.txt << 'REQ'
fastapi==0.115.6
uvicorn==0.34.0
prometheus-fastapi-instrumentator==7.0.2
REQ

# Inventory — add prometheus libraries
cat > services/inventory/requirements.txt << 'REQ'
fastapi==0.115.6
uvicorn==0.34.0
prometheus-fastapi-instrumentator==7.0.2
REQ

echo "   ✓ All requirements.txt updated"

# =============================================================================
# UPDATE CHECKOUT main.py — Add Prometheus metrics + circuit breaker gauge
# =============================================================================
# WHAT WE'RE ADDING:
#   1. Instrumentator() — automatically tracks request count, duration, size
#      for every endpoint. Think of it as an automatic customer counter at
#      every service's door.
#   2. circuit_breaker_state Gauge — a custom metric that reports whether the
#      circuit breaker is closed (0), open (1), or half-open (2).
#      Think of it as a traffic light: green/red/yellow.
#   3. checkout_outcomes Counter — tracks how each checkout ends:
#      success, out_of_stock, error, or fallback.
# =============================================================================

echo "[2/4] Updating main.py files with Prometheus metrics..."

cat > services/checkout/main.py << 'PYTHON'
"""
Checkout Service — the kitchen orchestrator (UPGRADED + OBSERVABILITY).

Assignment 2 additions:
  - Prometheus metrics via prometheus-fastapi-instrumentator
  - Custom circuit breaker state gauge (for Grafana dashboard)
  - Custom checkout outcome counter (success/error/fallback tracking)
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

# ── Prometheus Metrics ──────────────────────────────────────────
# Think of this like installing automatic counters at every door in the café:
# - How many customers entered? (request count)
# - How long did they wait? (request duration)
# - How big was their order? (response size)
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Counter, Gauge

# Custom metrics that tell the STORY of our system
# These are what make the Grafana dashboard interesting
circuit_breaker_state = Gauge(
    "circuit_breaker_state",
    "Circuit breaker: 0=closed(healthy), 1=open(failing), 2=half-open(testing)",
    ["dependency"]
)
checkout_outcomes = Counter(
    "checkout_outcomes_total",
    "How each checkout request ended",
    ["result"]  # success, out_of_stock, error, fallback
)

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
class CircuitBreakerLogger(pybreaker.CircuitBreakerListener):
    def state_change(self, cb, old_state, new_state):
        # Push state to Prometheus so Grafana can visualise it
        state_map = {"closed": 0, "open": 1, "half-open": 2}
        circuit_breaker_state.labels(dependency=cb.name).set(
            state_map.get(new_state.name, -1)
        )
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
FALLBACK_PRICES = {
    "WM-100": 29.99, "BH-200": 49.99, "UC-300": 9.99,
    "MK-400": 199.99, "PS-500": 14.50,
}

# ── App ─────────────────────────────────────────────────────────
app = FastAPI(title="Checkout Service")
http_client = httpx.AsyncClient(timeout=TIMEOUT_SECONDS)

# Wire up Prometheus automatic instrumentation
# This creates /metrics endpoint and tracks all HTTP requests automatically
Instrumentator().instrument(app).expose(app)

# Initialise circuit breaker gauges to 0 (closed = healthy)
circuit_breaker_state.labels(dependency="pricing").set(0)
circuit_breaker_state.labels(dependency="inventory").set(0)


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

    if isinstance(results[0], Exception):
        err_type = type(results[0]).__name__
        if item_id in FALLBACK_PRICES:
            pricing_result = {"item_id": item_id, "price": FALLBACK_PRICES[item_id]}
            fallback_used = True
            checkout_outcomes.labels(result="fallback").inc()  # METRIC
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

    if isinstance(results[1], Exception):
        errors.append(f"inventory: {type(results[1]).__name__}")
    else:
        inventory_result = results[1]

    elapsed = time.time() - start_time

    if errors:
        checkout_outcomes.labels(result="error").inc()  # METRIC
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
        checkout_outcomes.labels(result="out_of_stock").inc()  # METRIC
        write_audit(request_id, item_id, quantity, price, stock, "out_of_stock", fallback_used)
        return JSONResponse(
            content={"error": "insufficient stock", "item_id": item_id,
                     "requested": quantity, "available": stock, "request_id": request_id},
            status_code=409,
        )

    total = round(price * quantity, 2)
    checkout_outcomes.labels(result="success").inc()  # METRIC
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
PYTHON

# =============================================================================
# UPDATE GATEWAY main.py — Add Instrumentator
# =============================================================================

cat > services/gateway/main.py << 'PYTHON'
"""Gateway Service — routes requests and serves the UI (+ Prometheus metrics)."""

import os, uuid, time, json, logging
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse

# ── Prometheus ──────────────────────────────────────────────────
from prometheus_fastapi_instrumentator import Instrumentator

CHECKOUT_URL = os.getenv("CHECKOUT_URL", "http://checkout-svc")
SERVICE_NAME = "gateway"

class JSONFmt(logging.Formatter):
    def format(self, r):
        d = {"timestamp": self.formatTime(r), "level": r.levelname,
             "service": SERVICE_NAME, "message": r.getMessage()}
        if hasattr(r, "request_id"): d["request_id"] = r.request_id
        if hasattr(r, "extra_data"): d.update(r.extra_data)
        return json.dumps(d)

h = logging.StreamHandler()
h.setFormatter(JSONFmt())
log = logging.getLogger(SERVICE_NAME)
log.handlers = [h]
log.setLevel(logging.INFO)

app = FastAPI()
client = httpx.AsyncClient(timeout=5.0)

# Wire up Prometheus — creates /metrics endpoint automatically
Instrumentator().instrument(app).expose(app)

@app.middleware("http")
async def mid(req: Request, call_next):
    rid = req.headers.get("x-request-id", str(uuid.uuid4()))
    req.state.request_id = rid
    t = time.time()
    res = await call_next(req)
    ms = round((time.time() - t) * 1000)
    res.headers["X-Request-Id"] = rid
    log.info("%s %s %d %dms", req.method, req.url.path, res.status_code, ms,
             extra={"request_id": rid, "extra_data": {"event": "http_request",
             "method": req.method, "path": req.url.path,
             "status": res.status_code, "elapsed_ms": ms}})
    return res

@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE_NAME}

@app.get("/api/arch")
async def arch():
    return {"arch": "gateway -> checkout -> [pricing, inventory] + postgres"}

@app.get("/api/ping")
async def ping(req: Request):
    return {"pong": True, "service": SERVICE_NAME,
            "timestamp": time.time(), "request_id": req.state.request_id}

@app.post("/api/checkout")
async def checkout_proxy(req: Request):
    rid = req.state.request_id
    body = await req.json()
    log.info("Proxying to checkout-svc", extra={"request_id": rid,
             "extra_data": {"event": "proxy_start", "target": CHECKOUT_URL}})
    try:
        r = await client.post(f"{CHECKOUT_URL}/checkout", json=body,
                              headers={"X-Request-Id": rid})
        return JSONResponse(content=r.json(), status_code=r.status_code,
                            headers={"X-Request-Id": rid})
    except httpx.ConnectError:
        log.error("checkout-svc unreachable", extra={"request_id": rid})
        return JSONResponse(content={"error": "checkout service unavailable",
                            "request_id": rid}, status_code=503)
    except httpx.ReadTimeout:
        log.error("checkout-svc timed out", extra={"request_id": rid})
        return JSONResponse(content={"error": "checkout service timed out",
                            "request_id": rid}, status_code=504)

@app.get("/", response_class=HTMLResponse)
async def ui():
    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Click Cart</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#f5f5f5;color:#111}
    nav{background:#111;padding:18px 24px;text-align:center}
    nav span{color:#fff;font-size:20px;font-weight:700;letter-spacing:1px}
    .page{max-width:600px;margin:28px auto;padding:0 16px}
    h2{font-size:15px;font-weight:600;color:#444;margin-bottom:14px}
    .item{display:flex;align-items:center;gap:12px;padding:14px 16px;
          border:1px solid #e5e5e5;border-radius:8px;margin-bottom:8px;
          cursor:pointer;background:#fff;transition:border-color 0.15s}
    .item:hover{border-color:#999}
    .item.sel{border-color:#111}
    .item input{accent-color:#111}
    .info{flex:1}
    .name{font-weight:500;font-size:14px}
    .right{text-align:right}
    .price{font-weight:600;font-size:15px}
    .stock{font-size:11px;color:#888;margin-top:2px}
    .out{color:#dc2626;font-weight:500}
    .low{color:#d97706}
    .bar{display:flex;align-items:center;gap:12px;margin:22px 0}
    .bar label{font-size:13px;color:#666}
    .bar input{width:56px;padding:8px;border:1px solid #e5e5e5;border-radius:6px;
               font-size:14px;text-align:center;font-family:inherit}
    .bar input:focus{outline:none;border-color:#111}
    .btn{flex:1;padding:12px;background:#111;color:#fff;border:none;border-radius:6px;
         font-size:14px;font-weight:500;cursor:pointer;font-family:inherit}
    .btn:hover{background:#333}
    .btn:disabled{background:#ccc;cursor:not-allowed}
    .msg{margin-top:16px;padding:14px 16px;border-radius:8px;font-size:13px;
         line-height:1.7;display:none}
    .msg.ok{background:#f0fdf4;border:1px solid #bbf7d0;color:#166534}
    .msg.err{background:#fef2f2;border:1px solid #fecaca;color:#991b1b}
    .msg.warn{background:#fffbeb;border:1px solid #fde68a;color:#92400e}
    .msg b{font-weight:600}
    .msg code{font-size:11px;color:#999;font-family:monospace}
    .foot{text-align:center;margin-top:40px;font-size:11px;color:#ccc}
  </style>
</head>
<body>
  <nav><span>CLICK CART</span></nav>
  <div class="page">
    <h2>Choose a product</h2>
    <div class="item sel" data-id="WM-100" onclick="pick(this)">
      <input type="radio" name="i" checked>
      <div class="info"><div class="name">Wireless Mouse</div></div>
      <div class="right"><div class="price">&euro;29.99</div><div class="stock">42 in stock</div></div>
    </div>
    <div class="item" data-id="BH-200" onclick="pick(this)">
      <input type="radio" name="i">
      <div class="info"><div class="name">Bluetooth Headphones</div></div>
      <div class="right"><div class="price">&euro;49.99</div><div class="stock">15 in stock</div></div>
    </div>
    <div class="item" data-id="UC-300" onclick="pick(this)">
      <input type="radio" name="i">
      <div class="info"><div class="name">USB-C Cable</div></div>
      <div class="right"><div class="price">&euro;9.99</div><div class="stock">100 in stock</div></div>
    </div>
    <div class="item" data-id="MK-400" onclick="pick(this)">
      <input type="radio" name="i">
      <div class="info"><div class="name">Mechanical Keyboard</div></div>
      <div class="right"><div class="price">&euro;199.99</div><div class="stock low">Only 3 left</div></div>
    </div>
    <div class="item" data-id="PS-500" onclick="pick(this)">
      <input type="radio" name="i">
      <div class="info"><div class="name">Phone Stand</div></div>
      <div class="right"><div class="price">&euro;14.50</div><div class="stock out">Out of stock</div></div>
    </div>
    <div class="bar">
      <label>Qty</label>
      <input type="number" id="qty" value="1" min="1">
      <button class="btn" id="btn" onclick="order()">Place order</button>
    </div>
    <div class="msg" id="msg"></div>
    <div class="foot">&copy; 2026 Click Cart</div>
  </div>
<script>
var sel={id:'WM-100'};
function pick(el){
  document.querySelectorAll('.item').forEach(function(i){i.classList.remove('sel')});
  el.classList.add('sel');
  el.querySelector('input').checked=true;
  sel={id:el.dataset.id};
}
async function order(){
  var qty=parseInt(document.getElementById('qty').value)||1;
  var b=document.getElementById('btn');
  var m=document.getElementById('msg');
  b.disabled=true; b.textContent='Processing...'; m.style.display='none';
  try{
    var r=await fetch('/api/checkout',{method:'POST',
      headers:{'Content-Type':'application/json','X-Request-Id':'order-'+Date.now()},
      body:JSON.stringify({item_id:sel.id,quantity:qty})});
    var d=await r.json();
    m.style.display='block';
    if(r.ok&&d.status==='success'){
      if(d.fallback_price_used){
        m.className='msg warn';
        m.innerHTML='<b>Order placed</b> (estimated price)<br>Total: &euro;'+d.total.toFixed(2)+'<br><code>Order ref: '+d.request_id+'</code>';
      }else{
        m.className='msg ok';
        m.innerHTML='<b>Order confirmed</b><br>Total: &euro;'+d.total.toFixed(2)+' &middot; '+d.stock_remaining+' remaining in stock<br><code>Order ref: '+d.request_id+'</code>';
      }
    }else{
      m.className='msg err';
      m.innerHTML='<b>Order could not be placed</b><br>'+(d.error||'Something went wrong')+(d.available!==undefined?'<br>Available stock: '+d.available:'')+'<br><code>Ref: '+(d.request_id||'')+'</code>';
    }
  }catch(e){
    m.style.display='block'; m.className='msg err';
    m.innerHTML='<b>Unable to connect</b><br>Please try again later.';
  }
  b.disabled=false; b.textContent='Place order';
}
</script>
</body>
</html>"""
PYTHON

# =============================================================================
# UPDATE PRICING main.py — Add Instrumentator
# =============================================================================

cat > services/pricing/main.py << 'PYTHON'
"""Pricing Service — product price lookup (+ Prometheus metrics)."""

import json, logging
from fastapi import FastAPI, Request, Query
from prometheus_fastapi_instrumentator import Instrumentator

SERVICE_NAME = "pricing"

class JSONFmt(logging.Formatter):
    def format(self, r):
        d = {"timestamp": self.formatTime(r), "level": r.levelname,
             "service": SERVICE_NAME, "message": r.getMessage()}
        if hasattr(r, "request_id"): d["request_id"] = r.request_id
        if hasattr(r, "extra_data"): d.update(r.extra_data)
        return json.dumps(d)

h = logging.StreamHandler()
h.setFormatter(JSONFmt())
logger = logging.getLogger(SERVICE_NAME)
logger.handlers = [h]
logger.setLevel(logging.INFO)

app = FastAPI(title="Pricing Service")

# Prometheus auto-instrumentation — creates /metrics endpoint
Instrumentator().instrument(app).expose(app)

PRICES = {
    "WM-100": 29.99,
    "BH-200": 49.99,
    "UC-300": 9.99,
    "MK-400": 199.99,
    "PS-500": 14.50,
}

@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE_NAME}

@app.get("/price")
async def get_price(request: Request, item_id: str = Query(...)):
    request_id = request.headers.get("x-request-id", "unknown")
    price = PRICES.get(item_id, 0.00)
    logger.info("Price lookup: item=%s price=%.2f", item_id, price,
        extra={"request_id": request_id, "extra_data": {
            "event": "price_lookup", "item_id": item_id, "price": price}})
    return {"item_id": item_id, "price": price, "request_id": request_id}
PYTHON

# =============================================================================
# UPDATE INVENTORY main.py — Add Instrumentator
# =============================================================================

cat > services/inventory/main.py << 'PYTHON'
"""Inventory Service — product stock lookup (+ Prometheus metrics)."""

import json, logging
from fastapi import FastAPI, Request, Query
from prometheus_fastapi_instrumentator import Instrumentator

SERVICE_NAME = "inventory"

class JSONFmt(logging.Formatter):
    def format(self, r):
        d = {"timestamp": self.formatTime(r), "level": r.levelname,
             "service": SERVICE_NAME, "message": r.getMessage()}
        if hasattr(r, "request_id"): d["request_id"] = r.request_id
        if hasattr(r, "extra_data"): d.update(r.extra_data)
        return json.dumps(d)

h = logging.StreamHandler()
h.setFormatter(JSONFmt())
logger = logging.getLogger(SERVICE_NAME)
logger.handlers = [h]
logger.setLevel(logging.INFO)

app = FastAPI(title="Inventory Service")

# Prometheus auto-instrumentation — creates /metrics endpoint
Instrumentator().instrument(app).expose(app)

STOCK = {
    "WM-100": 42,
    "BH-200": 15,
    "UC-300": 100,
    "MK-400": 3,
    "PS-500": 0,
}

@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE_NAME}

@app.get("/stock")
async def get_stock(request: Request, item_id: str = Query(...)):
    request_id = request.headers.get("x-request-id", "unknown")
    stock = STOCK.get(item_id, 0)
    logger.info("Stock lookup: item=%s stock=%d", item_id, stock,
        extra={"request_id": request_id, "extra_data": {
            "event": "stock_lookup", "item_id": item_id, "stock": stock}})
    return {"item_id": item_id, "stock": stock, "request_id": request_id}
PYTHON

echo "   ✓ All main.py files updated with Prometheus metrics"

# =============================================================================
# PHASE 2: Rebuild Docker images
# =============================================================================

echo ""
echo "================================================"
echo "PHASE 2: Rebuild Docker images"
echo "================================================"

echo "[3/4] Building Docker images (this may take 2-3 minutes)..."

cd ~/Click-Cart

docker build -t checkout:latest services/checkout/
echo "   ✓ checkout:latest built"

docker build -t gateway:latest services/gateway/
echo "   ✓ gateway:latest built"

docker build -t pricing:latest services/pricing/
echo "   ✓ pricing:latest built"

docker build -t inventory:latest services/inventory/
echo "   ✓ inventory:latest built"

# =============================================================================
# PHASE 3: Redeploy to K3s
# =============================================================================

echo ""
echo "================================================"
echo "PHASE 3: Redeploy services to K3s"
echo "================================================"

echo "[4/4] Rolling out updated deployments..."

# Force K3s to pick up the new images by restarting deployments
sudo k3s kubectl rollout restart deployment/checkout
sudo k3s kubectl rollout restart deployment/gateway
sudo k3s kubectl rollout restart deployment/pricing
sudo k3s kubectl rollout restart deployment/inventory

echo "   Waiting for rollout to complete..."
sleep 10

sudo k3s kubectl get pods

echo ""
echo "================================================"
echo "✅ PHASE 1-3 COMPLETE — Services updated with metrics"
echo "================================================"
echo ""
echo "VERIFY: Test that /metrics endpoints work:"
echo "  kubectl exec deploy/checkout -- curl -s http://localhost:8001/metrics | head -5"
echo ""
echo "NEXT: Run the monitoring stack install commands shown below."
echo ""
echo "================================================"
echo "PHASE 4: Install monitoring stack (run manually)"
echo "================================================"
echo ""
echo "# Step 1: Install Helm (if not already installed)"
echo "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
echo ""
echo "# Step 2: Add Grafana repo and install loki-stack"
echo "helm repo add grafana https://grafana.github.io/helm-charts"
echo "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
echo "helm repo update"
echo ""
echo "# Step 3: Install Prometheus + Grafana"
echo "helm install prometheus prometheus-community/kube-prometheus-stack \\"
echo "  --namespace monitoring --create-namespace \\"
echo "  --set prometheus.prometheusSpec.scrapeInterval=30s \\"
echo "  --set prometheus.prometheusSpec.retention=7d \\"
echo "  --set alertmanager.enabled=false \\"
echo "  --set grafana.adminPassword=admin123"
echo ""
echo "# Step 4: Install Loki + Promtail for log aggregation"
echo "helm install loki grafana/loki-stack \\"
echo "  --namespace monitoring \\"
echo "  --set grafana.enabled=false \\"
echo "  --set loki.resources.requests.memory=128Mi \\"
echo "  --set loki.resources.limits.memory=256Mi"
echo ""
