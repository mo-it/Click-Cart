#!/bin/bash
# ╔════════════════════════════════════════════════════════════════╗
# ║  CHECKOUT PLATFORM — COMPLETE SETUP GUIDE                     ║
# ║  From fresh Ubuntu VM to running checkout platform             ║
# ║                                                                ║
# ║  Run each section one at a time. Don't paste the whole file.   ║
# ║  Read the comments — they explain what's happening.            ║
# ╚════════════════════════════════════════════════════════════════╝

# ─────────────────────────────────────────────────────────────────
# PHASE 0: CREATE THE VM (do this in VirtualBox GUI, not here)
# ─────────────────────────────────────────────────────────────────
#
# 1. Download Ubuntu 22.04 Server ISO:
#    https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso
#
# 2. Open VirtualBox → New:
#    - Name: checkout-lab
#    - Type: Linux / Ubuntu (64-bit)
#    - RAM: 4096 MB  (half your 8GB — K3s needs ~512MB, rest for services)
#    - CPU: 2 cores
#    - Disk: 25 GB (dynamic)
#    - Network: Bridged Adapter (so you can access from your laptop browser)
#      OR: NAT + Port Forwarding (simpler but need to forward port 80)
#
# 3. Install Ubuntu Server (defaults are fine):
#    - Pick a username/password you'll remember
#    - Enable OpenSSH during install (so you can SSH from your laptop)
#    - Don't install Docker during Ubuntu install (we'll do it properly below)
#
# 4. After install, reboot, login, and note your IP:
#    ip addr show | grep "inet " | grep -v 127.0.0.1
#
# 5. From your laptop, SSH in (easier than typing in the VM console):
#    ssh youruser@<vm-ip>
#
# Now you're ready. Run the sections below one at a time.
# ─────────────────────────────────────────────────────────────────


# ═══════════════════════════════════════════════════════════════
# SECTION 1: System updates and essentials
# ═══════════════════════════════════════════════════════════════
echo "=== Section 1: System updates ==="

sudo apt update && sudo apt upgrade -y

# Install tools we'll need
sudo apt install -y \
    curl \
    wget \
    git \
    jq \
    bc \
    unzip \
    python3 \
    python3-pip

echo "=== Section 1 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 2: Install Docker
# ═══════════════════════════════════════════════════════════════
# Docker is needed to BUILD our container images.
# K3s uses containerd (not Docker) to RUN them,
# but we need Docker as a build tool.
echo "=== Section 2: Install Docker ==="

# Remove any old Docker packages
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's official GPG key and repo
sudo apt install -y ca-certificates gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# Let your user run docker without sudo
sudo usermod -aG docker $USER

echo ""
echo "=== Docker installed. LOG OUT AND BACK IN for group change ==="
echo "=== Run: exit, then SSH back in, then continue Section 3 ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 3: Verify Docker (run AFTER re-login)
# ═══════════════════════════════════════════════════════════════
echo "=== Section 3: Verify Docker ==="

docker --version
docker run --rm hello-world

# If you see "Hello from Docker!" it works.
echo "=== Section 3 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 4: Install K3s
# ═══════════════════════════════════════════════════════════════
# K3s is a lightweight Kubernetes distribution.
# Think of it as Kubernetes with the bloat stripped out.
# One command installs the full control plane + worker.
echo "=== Section 4: Install K3s ==="

curl -sfL https://get.k3s.io | sh -

# Wait for K3s to start
echo "Waiting for K3s to be ready..."
sudo k3s kubectl wait --for=condition=ready node --all --timeout=60s

# Make kubectl work without sudo
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
export KUBECONFIG=~/.kube/config

# Add to your shell profile so it persists
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

# Verify
kubectl get nodes
kubectl get pods -A

echo ""
echo "=== K3s installed. You should see one node in 'Ready' state ==="
echo "=== Section 4 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 5: Install Helm (needed for KEDA)
# ═══════════════════════════════════════════════════════════════
echo "=== Section 5: Install Helm ==="

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version

echo "=== Section 5 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 6: Install KEDA
# ═══════════════════════════════════════════════════════════════
# KEDA lets us scale the pricing service to zero replicas.
echo "=== Section 6: Install KEDA ==="

helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

echo "Waiting for KEDA operator to be ready..."
kubectl wait --for=condition=available deployment/keda-operator \
    --namespace keda --timeout=120s || echo "(still starting — give it a minute)"

kubectl get pods -n keda

echo "=== Section 6 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 7: Upload and extract the project
# ═══════════════════════════════════════════════════════════════
# Transfer checkout-platform.tar.gz from your laptop to the VM.
# Option A (from your laptop terminal):
#   scp checkout-platform.tar.gz youruser@<vm-ip>:~/
#
# Option B (if you have the file on a USB/shared folder):
#   cp /media/shared/checkout-platform.tar.gz ~/
echo "=== Section 7: Extract project ==="

cd ~
tar -xzf checkout-platform.tar.gz
cd checkout-platform
ls -la

echo "=== Section 7 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 8: Build container images
# ═══════════════════════════════════════════════════════════════
# This builds all 4 service images and imports them into K3s.
# K3s uses containerd (not Docker), so we:
#   1. Build with docker
#   2. Save as .tar
#   3. Import into K3s containerd
echo "=== Section 8: Build images ==="

cd ~/checkout-platform
chmod +x scripts/*.sh
./scripts/build.sh

# Verify images are in K3s
sudo k3s crictl images | grep -E "gateway|checkout|pricing|inventory"

echo "=== Section 8 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 9: Deploy everything
# ═══════════════════════════════════════════════════════════════
echo "=== Section 9: Deploy ==="

cd ~/checkout-platform

# Apply all manifests in order
for manifest in k8s/[0-9]*.yaml; do
    echo "Applying: $manifest"
    kubectl apply -f "$manifest"
done

# Wait for pods
echo ""
echo "Waiting for pods to start..."
kubectl wait --for=condition=ready pod -l app=postgres --timeout=90s || true
kubectl wait --for=condition=ready pod -l app=pricing --timeout=60s || true
kubectl wait --for=condition=ready pod -l app=inventory --timeout=60s || true
kubectl wait --for=condition=ready pod -l app=checkout --timeout=60s || true
kubectl wait --for=condition=ready pod -l app=gateway --timeout=60s || true

echo ""
echo "=== Current state ==="
kubectl get deploy,pods,svc,ingress

echo "=== Section 9 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 10: Smoke test
# ═══════════════════════════════════════════════════════════════
echo "=== Section 10: Smoke test ==="

echo ""
echo "--- Health check ---"
curl -s http://localhost/health | jq .

echo ""
echo "--- Architecture ---"
curl -s http://localhost/api/arch | jq .

echo ""
echo "--- Ping ---"
curl -s http://localhost/api/ping | jq .

echo ""
echo "--- Checkout (happy path) ---"
curl -s -X POST http://localhost/api/checkout \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: smoke-test-001" \
    -d '{"item_id":"WIDGET-1","quantity":2}' | jq .

echo ""
echo "=== If you see JSON responses above, your platform is running! ==="
echo ""
echo "Access the UI from your laptop browser:"
echo "  http://<vm-ip>/"
echo ""
echo "=== Section 10 done ==="


# ═══════════════════════════════════════════════════════════════
# SECTION 11: Run the test suites (Phase 3)
# ═══════════════════════════════════════════════════════════════
echo "=== Section 11: Run tests ==="

cd ~/checkout-platform

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Running functional tests            ║"
echo "╚══════════════════════════════════════╝"
./scripts/test-functional.sh 2>&1 | tee ~/test-functional-output.txt

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Running reliability tests           ║"
echo "╚══════════════════════════════════════╝"
./scripts/test-reliability.sh 2>&1 | tee ~/test-reliability-output.txt

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Running scaling tests               ║"
echo "╚══════════════════════════════════════╝"
./scripts/test-scaling.sh 2>&1 | tee ~/test-scaling-output.txt

echo ""
echo "=== All test output saved to ~/test-*-output.txt ==="
echo "=== Copy these files for your report ==="
echo "=== Section 11 done ==="


# ═══════════════════════════════════════════════════════════════
# PORT FORWARDING NOTE (if using NAT instead of Bridged)
# ═══════════════════════════════════════════════════════════════
# If your VM uses NAT networking, add port forwarding in VirtualBox:
#   Settings → Network → Advanced → Port Forwarding:
#   - Name: HTTP,  Host Port: 8080, Guest Port: 80
#   - Name: SSH,   Host Port: 2222, Guest Port: 22
#
# Then access from your laptop:
#   Browser:  http://localhost:8080/
#   SSH:      ssh -p 2222 youruser@localhost


# ═══════════════════════════════════════════════════════════════
# TROUBLESHOOTING
# ═══════════════════════════════════════════════════════════════
# If pods are stuck in "Pending":
#   kubectl describe pod <name>   # Check Events section
#
# If pods are in "ImagePullBackOff":
#   sudo k3s crictl images | grep pricing   # Is the image imported?
#   # If not, re-run: ./scripts/build.sh
#
# If checkout can't reach postgres:
#   kubectl logs -l app=checkout   # Check for connection errors
#   kubectl get endpoints postgres-svc   # Should show an IP
#
# If you see "CrashLoopBackOff":
#   kubectl logs <pod-name> --previous   # Logs from the crashed container
#
# Nuclear option (start fresh):
#   ./scripts/teardown.sh
#   ./scripts/deploy.sh
