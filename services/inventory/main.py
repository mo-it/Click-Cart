"""Inventory Service — product stock lookup."""

import json, logging
from fastapi import FastAPI, Request, Query

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
