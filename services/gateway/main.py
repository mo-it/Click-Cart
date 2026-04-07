"""Gateway Service — routes requests and serves the UI."""

import os, uuid, time, json, logging
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse

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
        m.innerHTML='<b>Order placed</b> (estimated price)<br>'+
          'Total: &euro;'+d.total.toFixed(2)+
          '<br><code>Order ref: '+d.request_id+'</code>';
      }else{
        m.className='msg ok';
        m.innerHTML='<b>Order confirmed</b><br>'+
          'Total: &euro;'+d.total.toFixed(2)+' &middot; '+
          d.stock_remaining+' remaining in stock'+
          '<br><code>Order ref: '+d.request_id+'</code>';
      }
    }else{
      m.className='msg err';
      m.innerHTML='<b>Order could not be placed</b><br>'+(d.error||'Something went wrong')+
        (d.available!==undefined?'<br>Available stock: '+d.available:'')+
        '<br><code>Ref: '+(d.request_id||'')+'</code>';
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
