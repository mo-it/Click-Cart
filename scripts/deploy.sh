#!/bin/bash
# ============================================================
# deploy.sh — Deploy the entire checkout platform to K3s
# ============================================================
# Applies manifests in numbered order:
#   01 - Postgres Secret
#   02 - Postgres PVC
#   03 - Postgres Deployment + Service
#   04 - Pricing Deployment + Service
#   05 - Inventory Deployment + Service
#   06 - Checkout Deployment + Service
#   07 - Gateway Deployment + Service
#   08 - Ingress
#   09 - KEDA ScaledObject (requires KEDA to be installed)
#   10 - Toolbox pod
#
# Run from the project root: ./scripts/deploy.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
K8S_DIR="$PROJECT_DIR/k8s"

echo "============================================"
echo "  Deploying checkout-platform to K3s"
echo "============================================"

# ── Step 1: Check KEDA is installed ─────────────────────────
echo ""
echo "--- Checking KEDA installation ---"
if kubectl get crd scaledobjects.keda.sh &>/dev/null; then
    echo "KEDA is already installed."
else
    echo "KEDA not found. Installing via Helm..."
    echo ""
    # Install Helm if not present
    if ! command -v helm &>/dev/null; then
        echo "Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    # Add KEDA Helm repo and install
    helm repo add kedacore https://kedacore.github.io/charts
    helm repo update
    helm install keda kedacore/keda --namespace keda --create-namespace
    echo ""
    echo "Waiting for KEDA to be ready (60s)..."
    kubectl wait --for=condition=available deployment/keda-operator \
        --namespace keda --timeout=60s || true
    echo "KEDA installed."
fi

# ── Step 2: Apply manifests in order ────────────────────────
echo ""
echo "--- Applying Kubernetes manifests ---"
for manifest in "$K8S_DIR"/[0-9]*.yaml; do
    echo "Applying: $(basename "$manifest")"
    kubectl apply -f "$manifest"
done

# ── Step 3: Wait for core pods ──────────────────────────────
echo ""
echo "--- Waiting for pods to be ready ---"
echo "Waiting for Postgres..."
kubectl wait --for=condition=ready pod -l app=postgres --timeout=90s || true

echo "Waiting for Gateway..."
kubectl wait --for=condition=ready pod -l app=gateway --timeout=60s || true

echo "Waiting for Checkout..."
kubectl wait --for=condition=ready pod -l app=checkout --timeout=60s || true

echo "Waiting for Inventory..."
kubectl wait --for=condition=ready pod -l app=inventory --timeout=60s || true

# Pricing may be at 0 replicas if KEDA already took over — that's fine
echo "Checking Pricing (may be scaled to zero)..."
kubectl get pods -l app=pricing 2>/dev/null || true

# ── Step 4: Show final state ────────────────────────────────
echo ""
echo "============================================"
echo "  Deployment complete! Current state:"
echo "============================================"
echo ""
kubectl get pods -o wide
echo ""
kubectl get svc
echo ""
kubectl get ingress
echo ""
echo "============================================"
echo "  Access the platform:"
echo "    UI:       http://localhost/"
echo "    Health:   http://localhost/health"
echo "    Arch:     http://localhost/api/arch"
echo "    Checkout: curl -X POST http://localhost/api/checkout \\"
echo "              -H 'Content-Type: application/json' \\"
echo "              -H 'X-Request-Id: test-123' \\"
echo "              -d '{\"item_id\":\"WIDGET-1\",\"quantity\":2}'"
echo "============================================"
