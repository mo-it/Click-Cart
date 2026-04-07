#!/bin/bash
# ============================================================
# build.sh — Build all service images and load into K3s
# ============================================================
# K3s uses containerd, not Docker Hub. So we:
#   1. Build images with docker (or nerdctl)
#   2. Save them as .tar files
#   3. Import into K3s with: sudo k3s ctr images import <file>
#
# Run from the project root: ./scripts/build.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVICES_DIR="$PROJECT_DIR/services"

echo "============================================"
echo "  Building checkout-platform images"
echo "============================================"

SERVICES=("gateway" "checkout" "pricing" "inventory")

for svc in "${SERVICES[@]}"; do
    echo ""
    echo "--- Building $svc ---"
    docker build -t "$svc:latest" "$SERVICES_DIR/$svc"
    echo "--- Saving $svc image ---"
    docker save "$svc:latest" -o "/tmp/${svc}.tar"
    echo "--- Importing $svc into K3s ---"
    sudo k3s ctr images import "/tmp/${svc}.tar"
    rm -f "/tmp/${svc}.tar"
    echo "--- $svc done ---"
done

echo ""
echo "============================================"
echo "  All images built and imported into K3s"
echo "============================================"
echo ""
echo "Verify with: sudo k3s crictl images | grep -E 'gateway|checkout|pricing|inventory'"
