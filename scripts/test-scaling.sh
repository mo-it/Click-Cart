#!/bin/bash
# ============================================================
# test-scaling.sh — KEDA scaling + latency + persistence tests
# ============================================================
# Covers:
#   1. Warm latency baseline (pricing running)
#   2. Force scale-to-zero → measure cold start
#   3. Post-cold warm comparison
#   4. KEDA ScaledObject status
#   5. Postgres persistence proof (insert → restart → verify)
# ============================================================

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

section() {
    echo ""
    echo "============================================"
    echo -e "${CYAN}$1${NC}"
    echo "============================================"
}

# ════════════════════════════════════════════════════════════
#  1. WARM LATENCY BASELINE
# ════════════════════════════════════════════════════════════
section "1. Warm latency baseline"

echo "Ensuring pricing has at least 1 replica..."
kubectl scale deployment pricing --replicas=1 2>/dev/null
kubectl wait --for=condition=ready pod -l app=pricing --timeout=60s 2>/dev/null || true
echo ""

echo "Running 20 warm requests (curl timing through Ingress)..."
echo "(Matches Lab 3.7 curl timing pattern)"
echo ""

WARM_FILE=$(mktemp)
for i in $(seq 1 20); do
    ELAPSED=$(curl -s -o /dev/null -w "%{time_total}" \
        -X POST "$BASE_URL/api/checkout" \
        -H "Content-Type: application/json" \
        -H "X-Request-Id: warm-$(printf '%03d' $i)" \
        -d '{"item_id":"WM-100","quantity":1}')
    echo "$ELAPSED" >> "$WARM_FILE"
    printf "  Request %2d: %ss\n" "$i" "$ELAPSED"
done

echo ""
echo "Warm latency summary:"
sort -n "$WARM_FILE" | awk '
    { a[NR] = $1; sum += $1 }
    END {
        n = NR
        printf "  Count:  %d\n", n
        printf "  Min:    %.3fs\n", a[1]
        printf "  Max:    %.3fs\n", a[n]
        printf "  Mean:   %.3fs\n", sum/n
        p50 = int(n*0.5)+1; if(p50>n) p50=n
        p95 = int(n*0.95)+1; if(p95>n) p95=n
        p99 = int(n*0.99)+1; if(p99>n) p99=n
        printf "  p50:    %.3fs\n", a[p50]
        printf "  p95:    %.3fs\n", a[p95]
        printf "  p99:    %.3fs\n", a[p99]
    }
'
rm -f "$WARM_FILE"

# ════════════════════════════════════════════════════════════
#  2. COLD START LATENCY
# ════════════════════════════════════════════════════════════
section "2. Cold start latency (pricing scaled to zero)"

echo "Scaling pricing to 0..."
kubectl scale deployment pricing --replicas=0
echo "Waiting 10s for pod termination..."
sleep 10

echo "Pricing pods (should be empty):"
kubectl get pods -l app=pricing
echo ""

echo "Sending requests until checkout succeeds (measuring cold start window)..."
COLD_START=$(date +%s%N)
MAX_RETRIES=30
RETRY_INTERVAL=2
COLD_SUCCESS=false

for i in $(seq 1 $MAX_RETRIES); do
    HTTP_CODE=$(curl -s -o /tmp/cold_test.json -w "%{http_code}" --max-time 10 \
        -X POST "$BASE_URL/api/checkout" \
        -H "Content-Type: application/json" \
        -H "X-Request-Id: cold-$(printf '%03d' $i)" \
        -d '{"item_id":"WM-100","quantity":1}')

    if [ "$HTTP_CODE" == "200" ]; then
        COLD_END=$(date +%s%N)
        COLD_MS=$(( (COLD_END - COLD_START) / 1000000 ))

        # Check if it used fallback or live pricing
        FALLBACK=$(python3 -c "import json; d=json.load(open('/tmp/cold_test.json')); print(d.get('fallback_price_used', False))" 2>/dev/null)

        echo -e "  Attempt $i: ${GREEN}HTTP 200${NC}"
        if [ "$FALLBACK" == "True" ]; then
            echo "  Mode: Fallback pricing (pricing pod still cold-starting)"
        else
            echo "  Mode: Live pricing (pod fully ready)"
        fi
        echo "  Total cold-start window: ${COLD_MS}ms"
        COLD_SUCCESS=true
        break
    else
        echo "  Attempt $i: HTTP $HTTP_CODE (retrying in ${RETRY_INTERVAL}s...)"
        sleep $RETRY_INTERVAL
    fi
done

if [ "$COLD_SUCCESS" == "false" ]; then
    echo -e "${RED}Cold start did not complete within retry window${NC}"
fi

echo ""
echo "Pricing pods after cold start:"
kubectl get pods -l app=pricing -o wide
echo ""

# ════════════════════════════════════════════════════════════
#  3. POST-COLD WARM COMPARISON
# ════════════════════════════════════════════════════════════
section "3. Post-cold warm requests (comparison)"

echo "Waiting for pricing to be fully ready..."
kubectl wait --for=condition=ready pod -l app=pricing --timeout=60s 2>/dev/null || true

echo "Running 5 warm requests after cold start..."
for i in $(seq 1 5); do
    ELAPSED=$(curl -s -o /dev/null -w "%{time_total}" \
        -X POST "$BASE_URL/api/checkout" \
        -H "Content-Type: application/json" \
        -H "X-Request-Id: postcold-$(printf '%03d' $i)" \
        -d '{"item_id":"WM-100","quantity":1}')
    printf "  Request %d: %ss\n" "$i" "$ELAPSED"
done

# ════════════════════════════════════════════════════════════
#  4. KEDA STATUS
# ════════════════════════════════════════════════════════════
section "4. KEDA ScaledObject status"

echo "ScaledObject:"
kubectl get scaledobject pricing-scaledobject -o wide 2>/dev/null || echo "(not found — KEDA may not be installed yet)"
echo ""
echo "HPA managed by KEDA:"
kubectl get hpa 2>/dev/null || echo "(no HPA — expected if KEDA not installed)"
echo ""
echo "To watch scale-to-zero live:"
echo "  kubectl get pods -l app=pricing -w"
echo "  (wait for cooldownPeriod: 300s of idle)"

# ════════════════════════════════════════════════════════════
#  5. POSTGRES PERSISTENCE PROOF
# ════════════════════════════════════════════════════════════
section "5. Postgres persistence proof"

POSTGRES_POD=$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POSTGRES_POD" ]; then
    echo "(Postgres pod not found — skipping)"
else
    echo "Current audit rows (from checkout requests above):"
    kubectl exec "$POSTGRES_POD" -- psql -U checkout -d checkoutdb -c \
        "SELECT id, request_id, item_id, quantity, price, result, fallback_used, created_at FROM checkout_audit ORDER BY id DESC LIMIT 10;" \
        2>/dev/null || echo "(query failed — table may not exist yet)"

    echo ""
    echo "Row count before restart:"
    kubectl exec "$POSTGRES_POD" -- psql -U checkout -d checkoutdb -t -c \
        "SELECT COUNT(*) FROM checkout_audit;" 2>/dev/null || echo "(failed)"

    echo ""
    echo "--- Deleting Postgres pod (PVC keeps data) ---"
    kubectl delete pod "$POSTGRES_POD" --grace-period=5
    echo "Waiting for new Postgres pod..."
    kubectl wait --for=condition=ready pod -l app=postgres --timeout=60s 2>/dev/null || true

    NEW_POD=$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')
    echo "New pod: $NEW_POD"
    echo ""

    echo "Row count after restart (should match):"
    kubectl exec "$NEW_POD" -- psql -U checkout -d checkoutdb -t -c \
        "SELECT COUNT(*) FROM checkout_audit;" 2>/dev/null || echo "(failed)"

    echo ""
    echo "Latest rows after restart:"
    kubectl exec "$NEW_POD" -- psql -U checkout -d checkoutdb -c \
        "SELECT id, request_id, item_id, result, created_at FROM checkout_audit ORDER BY id DESC LIMIT 5;" \
        2>/dev/null || echo "(failed)"
fi

section "Scaling and persistence tests complete"
