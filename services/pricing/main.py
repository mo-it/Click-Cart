"""Pricing Service — product price lookup."""

import json, logging
from fastapi import FastAPI, Request, Query

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
