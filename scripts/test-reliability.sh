#!/bin/bash
# ============================================================
# test-reliability.sh — Reliability and failure mode tests
# ============================================================
# Follows the troubleshooting workflow from Lab 3.7:
#   Step 1: What exists? (get deploy,pods,svc,ingress)
#   Step 2: What does K8s say is wrong? (describe, Events)
#   Step 3: Container logs
#   Step 4: Service routing (endpoints)
#   Step 5: Ingress routing
#   Step 6: Inside-cluster test (toolbox)
#
# Tests:
#   A. Dependency down: scale pricing to 0, verify 503/fallback
#   B. Bad rollout: deploy bad image tag, capture ImagePullBackOff
#   C. Full diagnosis workflow (R5 evidence)
#   D. Recovery verification
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
#  TEST A: Dependency down — pricing scaled to 0
# ════════════════════════════════════════════════════════════
section "TEST A: Dependency down — scale pricing to 0"

echo "Current pricing state:"
kubectl get pods -l app=pricing -o wide
echo ""

echo "Scaling pricing to 0 replicas..."
kubectl scale deployment pricing --replicas=0
sleep 5

echo "Pricing pods after scale-down (expect none):"
kubectl get pods -l app=pricing
echo ""

echo "Sending checkout request (pricing down → expect fallback or 503)..."
HTTP_CODE=$(curl -s -o /tmp/rel_test.json -w "%{http_code}" \
    -X POST "$BASE_URL/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: rel-dep-down-001" \
    -d '{"item_id":"WM-100","quantity":1}')

echo "HTTP Status: $HTTP_CODE"
echo "Response:"
python3 -m json.tool /tmp/rel_test.json 2>/dev/null || cat /tmp/rel_test.json
echo ""

# Check if fallback was used (200 with fallback_price_used=true) or hard fail (503)
FALLBACK=$(python3 -c "import json; d=json.load(open('/tmp/rel_test.json')); print(d.get('fallback_price_used','N/A'))" 2>/dev/null)
if [ "$HTTP_CODE" == "200" ] && [ "$FALLBACK" == "True" ]; then
    echo -e "${GREEN}✓ PASS: Graceful degradation — fallback price used${NC}"
elif [ "$HTTP_CODE" == "503" ] || [ "$HTTP_CODE" == "504" ]; then
    echo -e "${GREEN}✓ PASS: Gateway returned $HTTP_CODE (dependency unavailable)${NC}"
else
    echo -e "${RED}✗ UNEXPECTED: HTTP $HTTP_CODE${NC}"
fi

echo ""
echo "Gateway still healthy (partial failure — gateway stays up):"
curl -s "$BASE_URL/health" | python3 -m json.tool 2>/dev/null
echo ""

echo "Restoring pricing to 1 replica..."
kubectl scale deployment pricing --replicas=1
kubectl wait --for=condition=ready pod -l app=pricing --timeout=60s 2>/dev/null || true

# ════════════════════════════════════════════════════════════
#  TEST B: Bad rollout — invalid image tag
# ════════════════════════════════════════════════════════════
section "TEST B: Bad rollout — pricing with bad image tag"

echo "Setting pricing image to 'pricing:DOESNOTEXIST'..."
kubectl set image deployment/pricing pricing=pricing:DOESNOTEXIST
sleep 15

echo ""
echo "--- Pod status (expect ImagePullBackOff or ErrImagePull) ---"
kubectl get pods -l app=pricing -o wide
echo ""

echo "--- Describe pricing deployment (Events at bottom) ---"
kubectl describe deployment pricing | tail -20
echo ""

echo "--- Failing pod events ---"
PRICING_POD=$(kubectl get pods -l app=pricing --field-selector=status.phase!=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$PRICING_POD" ]; then
    kubectl describe pod "$PRICING_POD" | grep -A 8 "Events:"
fi
echo ""

echo "Rolling back to correct image..."
kubectl set image deployment/pricing pricing=pricing:latest
kubectl rollout status deployment/pricing --timeout=60s 2>/dev/null || true

echo "Pricing pods after rollback:"
kubectl get pods -l app=pricing
echo ""

# ════════════════════════════════════════════════════════════
#  TEST C: Full troubleshooting workflow (Lab 3.7 pattern)
# ════════════════════════════════════════════════════════════
section "TEST C: Troubleshooting workflow — R5 evidence"
echo "(Following the repeatable workflow from Lab 3.7)"

echo ""
echo -e "${YELLOW}Step 1: What exists and what is failing?${NC}"
echo "─────────────────────────────────────────"
kubectl get deploy,pods,svc,ingress
echo ""

echo -e "${YELLOW}Step 2: Describe a key deployment (Events section)${NC}"
echo "─────────────────────────────────────────"
kubectl describe deployment checkout | tail -20
echo ""

echo -e "${YELLOW}Step 3: Container logs${NC}"
echo "─────────────────────────────────────────"
for svc in gateway checkout pricing inventory; do
    echo "--- $svc (last 8 lines) ---"
    kubectl logs -l app=$svc --tail=8 2>/dev/null || echo "(no logs or scaled to zero)"
    echo ""
done

echo -e "${YELLOW}Step 4: Service routing — endpoints${NC}"
echo "─────────────────────────────────────────"
echo "Endpoints:"
kubectl get endpoints gateway-svc checkout-svc pricing-svc inventory-svc postgres-svc -o wide 2>/dev/null
echo ""
echo "EndpointSlices:"
kubectl get endpointslices 2>/dev/null
echo ""

echo -e "${YELLOW}Step 5: Ingress routing${NC}"
echo "─────────────────────────────────────────"
kubectl get ingress -o wide
echo ""
kubectl describe ingress checkout-ingress 2>/dev/null
echo ""

echo "Traefik controller running?"
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null
echo ""

echo -e "${YELLOW}Step 6: Inside-cluster connectivity (toolbox)${NC}"
echo "─────────────────────────────────────────"
if kubectl get pod toolbox &>/dev/null 2>&1; then
    echo "DNS: nslookup gateway-svc"
    kubectl exec toolbox -- nslookup gateway-svc 2>/dev/null || echo "(DNS failed)"
    echo ""
    echo "HTTP: curl gateway-svc/health"
    kubectl exec toolbox -- curl -s http://gateway-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "HTTP: curl checkout-svc/health"
    kubectl exec toolbox -- curl -s http://checkout-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "HTTP: curl pricing-svc/health"
    kubectl exec toolbox -- curl -s http://pricing-svc/health 2>/dev/null || echo "(may be scaled to zero)"
    echo ""
    echo "HTTP: curl inventory-svc/health"
    kubectl exec toolbox -- curl -s http://inventory-svc/health 2>/dev/null || echo "(failed)"
    echo ""
    echo "TCP: nc -zv postgres-svc 5432"
    kubectl exec toolbox -- nc -zv postgres-svc 5432 2>&1 || echo "(failed)"
    echo ""
else
    echo "(toolbox pod not running — deploy with: kubectl apply -f k8s/10-toolbox.yaml)"
fi

echo ""
echo -e "${YELLOW}Bonus: Recent cluster events (sorted by time)${NC}"
echo "─────────────────────────────────────────"
kubectl get events --sort-by='.lastTimestamp' 2>/dev/null | tail -20
echo ""

section "Reliability tests complete"
