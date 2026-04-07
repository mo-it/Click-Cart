#!/bin/bash
# ============================================================
# teardown.sh — Remove all checkout-platform resources from K3s
# ============================================================

set -uo pipefail

echo "============================================"
echo "  Tearing down checkout-platform"
echo "============================================"

echo "Deleting KEDA ScaledObject..."
kubectl delete scaledobject pricing-scaledobject 2>/dev/null || true

echo "Deleting Ingress..."
kubectl delete ingress checkout-ingress 2>/dev/null || true

echo "Deleting toolbox..."
kubectl delete pod toolbox 2>/dev/null || true

echo "Deleting Deployments..."
kubectl delete deployment gateway checkout pricing inventory postgres 2>/dev/null || true

echo "Deleting Services..."
kubectl delete svc gateway-svc checkout-svc pricing-svc inventory-svc postgres-svc 2>/dev/null || true

echo "Deleting Secret..."
kubectl delete secret postgres-secret 2>/dev/null || true

echo "Deleting PVC (this removes stored data)..."
kubectl delete pvc postgres-pvc 2>/dev/null || true

echo ""
echo "Done. Verify with: kubectl get all"
kubectl get all 2>/dev/null
