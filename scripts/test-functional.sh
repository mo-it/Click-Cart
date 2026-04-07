#!/bin/bash
# ============================================================
# test-functional.sh — Functional tests for the checkout platform
# ============================================================
# Covers:
#   1. Health endpoints for all services (via toolbox in-cluster)
#   2. Gateway public endpoints: /, /api/arch, /api/ping
#   3. Happy path checkout (WM-100, qty 2)
#   4. Out-of-stock checkout (PS-500, stock=0)
#   5. Invalid input (missing item_id)
#   6. Unknown item (price=0, stock=0)
#   7. X-Request-Id propagation + log correlation
# ============================================================

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost}"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

test_case() {
    local name="$1"
    local expected_status="$2"
    shift 2

    echo ""
    echo "─────────────────────────────────────────"
    echo -e "${YELLOW}TEST: $name${NC}"
    echo "─────────────────────────────────────────"

    HTTP_CODE=$(curl -s -o /tmp/test_response.json -w "%{http_code}" "$@")
    BODY=$(cat /tmp/test_response.json)

    echo "HTTP Status: $HTTP_CODE"
    echo "Response:    $(echo "$BODY" | head -c 500)"

    if [ "$HTTP_CODE" == "$expected_status" ]; then
        echo -e "${GREEN}✓ PASS (expected $expected_status, got $HTTP_CODE)${NC}"
        ((PASS++))
    else
        echo -e "${RED}✗ FAIL (expected $expected_status, got $HTTP_CODE)${NC}"
        ((FAIL++))
    fi
}

echo "============================================"
echo "  Functional Tests — Checkout Platform"
echo "============================================"
echo "Base URL: $BASE_URL"
echo "Time:     $(date)"

# ── 1. Gateway public endpoints ─────────────────────────────
test_case "Gateway /health" "200" \
    "$BASE_URL/health"

test_case "Gateway / (UI)" "200" \
    "$BASE_URL/"

test_case "Gateway /api/arch" "200" \
    "$BASE_URL/api/arch"

test_case "Gateway /api/ping" "200" \
    "$BASE_URL/api/ping"

# ── 2. In-cluster health checks (via toolbox) ───────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${YELLOW}In-cluster health checks (toolbox pod)${NC}"
echo "─────────────────────────────────────────"
if kubectl get pod toolbox &>/dev/null 2>&1; then
    echo "gateway-svc /health:"
    kubectl exec toolbox -- curl -s http://gateway-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "checkout-svc /health:"
    kubectl exec toolbox -- curl -s http://checkout-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "pricing-svc /health:"
    kubectl exec toolbox -- curl -s http://pricing-svc/health 2>/dev/null || echo "(may be scaled to zero)"
    echo ""
    echo "inventory-svc /health:"
    kubectl exec toolbox -- curl -s http://inventory-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "postgres-svc connectivity (nc):"
    kubectl exec toolbox -- nc -zv postgres-svc 5432 2>&1 || echo "(failed)"
    echo ""
else
    echo "(toolbox pod not running — skipping)"
fi

# ── 3. Happy path checkout ──────────────────────────────────
test_case "Happy path: WM-100, qty=2" "200" \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: func-test-happy-001" \
    -d '{"item_id":"WM-100","quantity":2}'

# ── 4. Out of stock ─────────────────────────────────────────
test_case "Out of stock: PS-500 (stock=0)" "409" \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: func-test-oos-002" \
    -d '{"item_id":"PS-500","quantity":1}'

# ── 5. Invalid input ────────────────────────────────────────
test_case "Invalid input: missing item_id" "422" \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: func-test-invalid-003" \
    -d '{"quantity":1}'

# ── 6. Unknown item ─────────────────────────────────────────
test_case "Unknown item: NONEXISTENT (stock=0)" "409" \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: func-test-unknown-004" \
    -d '{"item_id":"NONEXISTENT","quantity":1}'

# ── 7. X-Request-Id propagation ─────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${YELLOW}TEST: X-Request-Id propagation${NC}"
echo "─────────────────────────────────────────"
RESP_HEADERS=$(curl -s -D - -o /tmp/test_response.json \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: trace-me-005" \
    -d '{"item_id":"WM-100","quantity":1}')

if echo "$RESP_HEADERS" | grep -qi "x-request-id: trace-me-005"; then
    echo -e "${GREEN}✓ PASS: X-Request-Id echoed in response header${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ FAIL: X-Request-Id not found in response header${NC}"
    ((FAIL++))
fi

BODY_ID=$(cat /tmp/test_response.json | python3 -c "import sys,json; print(json.load(sys.stdin).get('request_id',''))" 2>/dev/null)
if [ "$BODY_ID" == "trace-me-005" ]; then
    echo -e "${GREEN}✓ PASS: request_id in response body matches${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ FAIL: request_id in body='$BODY_ID', expected='trace-me-005'${NC}"
    ((FAIL++))
fi

# ── 8. Log correlation across services ──────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${YELLOW}TEST: Log correlation across services${NC}"
echo "─────────────────────────────────────────"
echo "Searching logs for request ID 'trace-me-005'..."
echo ""
for svc in gateway checkout pricing inventory; do
    echo "--- $svc logs ---"
    kubectl logs -l app=$svc --tail=30 2>/dev/null | grep "trace-me-005" || echo "(not found or scaled to zero)"
    echo ""
done

# ── 9. Fallback price indicator ─────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${YELLOW}TEST: Fallback price field present in response${NC}"
echo "─────────────────────────────────────────"
FALLBACK_FIELD=$(cat /tmp/test_response.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('present' if 'fallback_price_used' in d else 'missing')" 2>/dev/null)
if [ "$FALLBACK_FIELD" == "present" ]; then
    echo -e "${GREEN}✓ PASS: fallback_price_used field present in checkout response${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ FAIL: fallback_price_used field missing${NC}"
    ((FAIL++))
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
