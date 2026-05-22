#!/bin/bash
# =============================================================================
# Click-Cart Assignment 2 — Security Fixes
# =============================================================================
# Run this script from ~/Click-Cart on your VM:
#   chmod +x create-security-fixes.sh
#   ./create-security-fixes.sh
#
# WHAT THIS DOES:
# Creates hardened versions of your Kubernetes manifests in security/fixes/
# You'll apply them AFTER reviewing what changed.
# =============================================================================

set -e
cd ~/Click-Cart
mkdir -p security/fixes

echo "================================================"
echo "Creating hardened Kubernetes manifests..."
echo "================================================"

# =============================================================================
# FIX 1: SECRETS — Remove plaintext password from Git
# =============================================================================
# WHAT'S WRONG:
#   Your 01-postgres-secret.yaml has the actual password "sup3rS3cret!"
#   written in plain text. Anyone who can read your Git repo can see it.
#   base64 encoding (which Kubernetes does automatically) is NOT encryption —
#   it's like writing the password backwards and calling it "secure".
#
# WHAT WE'RE DOING:
#   1. Creating a .env file with the credentials (excluded from Git)
#   2. Creating a placeholder YAML that documents the new workflow
#   3. Adding .env files to .gitignore
#
# HOW TO USE:
#   Instead of: kubectl apply -f k8s/01-postgres-secret.yaml
#   You'll run:  kubectl create secret generic postgres-secret --from-env-file=k8s/.env.postgres
# =============================================================================

echo "[1/8] Creating secrets fix..."

cat > k8s/.env.postgres << 'ENV'
POSTGRES_USER=checkout
POSTGRES_PASSWORD=N3wR0tated$ecret2026!
POSTGRES_DB=checkoutdb
ENV

cat > security/fixes/01-postgres-secret-placeholder.yaml << 'YAML'
# ============================================================
# PLACEHOLDER — Do NOT apply this file directly
# ============================================================
# The actual secret is created at deploy time using:
#
#   kubectl create secret generic postgres-secret \
#     --from-env-file=k8s/.env.postgres
#
# The .env.postgres file is excluded from Git via .gitignore
# This prevents credentials from ever entering version control
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  labels:
    app: postgres
type: Opaque
# No stringData here — credentials loaded from .env at deploy time
YAML

# Add .env files to .gitignore (only if not already there)
grep -q "k8s/.env.*" .gitignore 2>/dev/null || echo "k8s/.env.*" >> .gitignore

echo "   ✓ Secrets placeholder created"
echo "   ✓ .env.postgres created (excluded from Git)"
echo "   ✓ .gitignore updated"

# =============================================================================
# FIX 2: POSTGRES DEPLOYMENT — Add securityContext
# =============================================================================
# WHAT'S WRONG:
#   Postgres pod has NO securityContext at all. It runs as root, can escalate
#   privileges, has all Linux capabilities, and can write anywhere on disk.
#
# WHAT WE'RE ADDING:
#   - allowPrivilegeEscalation: false → container can't gain more privileges
#   - capabilities.drop: [ALL] → removes all Linux capabilities (like NET_RAW,
#     SYS_ADMIN etc.) that could be used for attacks
#   - automountServiceAccountToken: false → prevents the pod from talking to
#     the Kubernetes API (Postgres has no reason to call kubectl)
#
# WHY NOT runAsNonRoot?
#   The official postgres:16-alpine image NEEDS to start as root to initialize
#   the database, then drops to the 'postgres' user internally. So we can't
#   set runAsNonRoot here — but we CAN restrict everything else.
# =============================================================================

echo "[2/8] Creating hardened postgres deployment..."

cat > security/fixes/03-postgres.yaml << 'YAML'
# PostgreSQL Deployment — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false (no K8s API access)
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access needed
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-secret
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "checkout"]
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "checkout"]
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:                    # NEW: Hardened security
            allowPrivilegeEscalation: false   # Can't gain more privileges
            capabilities:
              drop:
                - ALL                         # Remove all Linux capabilities
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  labels:
    app: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
YAML

echo "   ✓ Postgres hardened (capabilities dropped, no API token)"

# =============================================================================
# FIX 3: CHECKOUT DEPLOYMENT — Add missing security settings
# =============================================================================
# WHAT'S WRONG:
#   Checkout has runAsNonRoot and runAsUser but is MISSING:
#   - readOnlyRootFilesystem (attacker could write malware to /app)
#   - allowPrivilegeEscalation (could gain root)
#   - capabilities.drop (has full Linux capabilities)
#   - automountServiceAccountToken (can call Kubernetes API)
#
# WHAT WE'RE ADDING:
#   All four missing settings, plus a /tmp volume mount because Python
#   needs a writable temp directory and readOnlyRootFilesystem blocks /tmp
# =============================================================================

echo "[3/8] Creating hardened checkout deployment..."

cat > security/fixes/06-checkout.yaml << 'YAML'
# Checkout Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + readOnlyRootFilesystem: true (was missing!)
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume (Python needs writable temp dir)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  labels:
    app: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access
      containers:
        - name: checkout
          image: checkout:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8001
          envFrom:
            - secretRef:
                name: postgres-secret
          env:
            - name: PRICING_URL
              value: "http://pricing-svc"
            - name: INVENTORY_URL
              value: "http://inventory-svc"
            - name: DB_HOST
              value: "postgres-svc"
            - name: DB_PORT
              value: "5432"
            - name: DEPENDENCY_TIMEOUT
              value: "3.0"
          startupProbe:
            httpGet:
              path: /health
              port: 8001
            failureThreshold: 10
            periodSeconds: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8001
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8001
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:
            runAsNonRoot: true               # KEPT from original
            runAsUser: 1000                  # KEPT from original
            readOnlyRootFilesystem: true      # NEW: Can't write to container
            allowPrivilegeEscalation: false   # NEW: Can't gain privileges
            capabilities:
              drop:
                - ALL                         # NEW: Drop all capabilities
          volumeMounts:                       # NEW: Python needs writable /tmp
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}                       # Writable temp dir backed by RAM
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-svc
  labels:
    app: checkout
spec:
  selector:
    app: checkout
  ports:
    - port: 80
      targetPort: 8001
  type: ClusterIP
YAML

echo "   ✓ Checkout hardened (readOnly, drop ALL, no API token)"

# =============================================================================
# FIX 4: PRICING DEPLOYMENT — Add missing security settings
# =============================================================================
# WHAT'S WRONG:
#   Pricing already has runAsNonRoot, runAsUser, readOnlyRootFilesystem (good!)
#   but is MISSING:
#   - allowPrivilegeEscalation: false
#   - capabilities.drop: [ALL]
#   - automountServiceAccountToken: false
# =============================================================================

echo "[4/8] Creating hardened pricing deployment..."

cat > security/fixes/04-pricing.yaml << 'YAML'
# Pricing Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume (needed for readOnlyRootFilesystem)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  labels:
    app: pricing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pricing
  template:
    metadata:
      labels:
        app: pricing
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access
      containers:
        - name: pricing
          image: pricing:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8002
          readinessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT from original
            runAsUser: 1000                  # KEPT from original
            readOnlyRootFilesystem: true      # KEPT from original
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW: Python needs writable /tmp
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: pricing-svc
  labels:
    app: pricing
spec:
  selector:
    app: pricing
  ports:
    - port: 80
      targetPort: 8002
  type: ClusterIP
YAML

echo "   ✓ Pricing hardened (drop ALL, no API token)"

# =============================================================================
# FIX 5: INVENTORY DEPLOYMENT — Same pattern as pricing
# =============================================================================

echo "[5/8] Creating hardened inventory deployment..."

cat > security/fixes/05-inventory.yaml << 'YAML'
# Inventory Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
  labels:
    app: inventory
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inventory
  template:
    metadata:
      labels:
        app: inventory
    spec:
      automountServiceAccountToken: false    # NEW
      containers:
        - name: inventory
          image: inventory:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8003
          readinessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT
            runAsUser: 1000                  # KEPT
            readOnlyRootFilesystem: true      # KEPT
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: inventory-svc
  labels:
    app: inventory
spec:
  selector:
    app: inventory
  ports:
    - port: 80
      targetPort: 8003
  type: ClusterIP
YAML

echo "   ✓ Inventory hardened (drop ALL, no API token)"

# =============================================================================
# FIX 6: GATEWAY DEPLOYMENT — Add missing security settings
# =============================================================================

echo "[6/8] Creating hardened gateway deployment..."

cat > security/fixes/07-gateway.yaml << 'YAML'
# Gateway Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  labels:
    app: gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gateway
  template:
    metadata:
      labels:
        app: gateway
    spec:
      automountServiceAccountToken: false    # NEW
      containers:
        - name: gateway
          image: gateway:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8000
          env:
            - name: CHECKOUT_URL
              value: "http://checkout-svc"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT
            runAsUser: 1000                  # KEPT
            readOnlyRootFilesystem: true      # KEPT
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: gateway-svc
  labels:
    app: gateway
spec:
  selector:
    app: gateway
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
YAML

echo "   ✓ Gateway hardened (drop ALL, no API token)"

# =============================================================================
# FIX 7: TOOLBOX POD — Harden or document for removal
# =============================================================================
# WHAT'S WRONG:
#   The toolbox pod is a troubleshooting tool with ZERO security restrictions.
#   It runs as root, has all capabilities, can access the Kubernetes API via
#   the default ServiceAccount, and sleeps for 10 hours (36000 seconds).
#   If an attacker gets shell access to ANY pod, they could use the toolbox
#   as a lateral-movement beachhead.
#
# WHAT WE'RE DOING:
#   Hardening it for dev use + documenting that it should be DELETED in production.
# =============================================================================

echo "[7/8] Creating hardened toolbox pod..."

cat > security/fixes/10-toolbox.yaml << 'YAML'
# Toolbox Pod — HARDENED for Assignment 2
# ⚠️  In PRODUCTION: DELETE this pod entirely. It exists only for dev debugging.
#
# Changes from original:
#   + automountServiceAccountToken: false (no K8s API access)
#   + runAsNonRoot: true + runAsUser: 1000
#   + readOnlyRootFilesystem: true
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + Sleep reduced from 36000s (10hrs) to 3600s (1hr)
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  labels:
    app: toolbox
spec:
  automountServiceAccountToken: false        # NEW: No K8s API access
  containers:
    - name: toolbox
      image: nicolaka/netshoot:latest
      command: ["sleep", "3600"]             # CHANGED: 1hr instead of 10hrs
      resources:
        requests:
          memory: "32Mi"
          cpu: "10m"
        limits:
          memory: "64Mi"
          cpu: "100m"
      securityContext:                        # NEW: Full hardening
        runAsNonRoot: true
        runAsUser: 1000
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
  restartPolicy: Never
YAML

echo "   ✓ Toolbox hardened (non-root, drop ALL, 1hr sleep)"

# =============================================================================
# FIX 8: NETWORK POLICIES — Build walls between services
# =============================================================================
# WHAT'S WRONG:
#   Right now ANY pod can talk to ANY other pod. That means if an attacker
#   compromises the Gateway, they can directly access PostgreSQL, read the
#   database, and steal all data. There are no walls.
#
# WHAT WE'RE DOING:
#   1. Default-deny: block ALL traffic first (lock every door)
#   2. Then open ONLY the specific doors each service needs:
#      - Gateway can ONLY talk to Checkout
#      - Checkout can talk to Pricing, Inventory, and Postgres
#      - Pricing and Inventory can ONLY receive from Checkout
#      - Postgres can ONLY receive from Checkout
# =============================================================================

echo "[8/8] Creating NetworkPolicy manifests..."

cat > security/fixes/11-default-deny.yaml << 'YAML'
# Default Deny — Block ALL traffic first, then allow specific paths
# Think of it like: "The café is closed. Now let's decide who gets keys."
#
# Without this policy, Kubernetes allows ALL pod-to-pod communication.
# This is the #1 recommendation in the NSA/CISA Kubernetes Hardening Guide.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}           # Applies to ALL pods in the namespace
  policyTypes:
    - Ingress               # Block all incoming traffic
    - Egress                # Block all outgoing traffic
YAML

cat > security/fixes/12-allow-gateway.yaml << 'YAML'
# Gateway NetworkPolicy
# The front door of the café — customers can enter, waiter can go to kitchen
#
# ALLOWS:
#   IN:  Traffic from anywhere (Traefik Ingress sends customer requests here)
#   OUT: Only to checkout-svc (the kitchen) + DNS (so it can resolve service names)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway
spec:
  podSelector:
    matchLabels:
      app: gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from: []                            # Allow from anywhere (Traefik)
      ports:
        - port: 8000
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: checkout               # Can ONLY reach checkout
      ports:
        - port: 8001
    - to:                                 # DNS resolution (required!)
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/13-allow-checkout.yaml << 'YAML'
# Checkout NetworkPolicy
# The kitchen — receives orders from waiter, talks to menu board,
# stockroom, and record book
#
# ALLOWS:
#   IN:  Only from gateway (the waiter brings orders)
#   OUT: To pricing, inventory, postgres, and DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-checkout
spec:
  podSelector:
    matchLabels:
      app: checkout
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - port: 8001
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: pricing
      ports:
        - port: 8002
    - to:
        - podSelector:
            matchLabels:
              app: inventory
      ports:
        - port: 8003
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
    - to:                                 # DNS
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/14-allow-pricing-inventory.yaml << 'YAML'
# Pricing & Inventory NetworkPolicies
# The menu board and stockroom — only the kitchen staff (checkout) can enter
#
# ALLOWS:
#   IN:  Only from checkout
#   OUT: DNS only (these services don't call anything else)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-pricing
spec:
  podSelector:
    matchLabels:
      app: pricing
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 8002
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-inventory
spec:
  podSelector:
    matchLabels:
      app: inventory
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 8003
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/15-allow-postgres.yaml << 'YAML'
# PostgreSQL NetworkPolicy
# The record book — locked in a cage, only the head chef (checkout) has the key
#
# ALLOWS:
#   IN:  Only from checkout on port 5432
#   OUT: Nothing (Postgres doesn't need to call any other service)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 5432
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

echo "   ✓ NetworkPolicies created (default-deny + 5 allow rules)"

echo ""
echo "================================================"
echo "✅ ALL FILES CREATED SUCCESSFULLY"
echo "================================================"
echo ""
echo "Files created in security/fixes/:"
ls -1 security/fixes/
echo ""
echo "================================================"
echo "NEXT STEPS — Apply the fixes to your cluster:"
echo "================================================"
echo ""
echo "Step 1: Apply the hardened deployments (one at a time):"
echo "  kubectl apply -f security/fixes/03-postgres.yaml"
echo "  kubectl apply -f security/fixes/04-pricing.yaml"
echo "  kubectl apply -f security/fixes/05-inventory.yaml"
echo "  kubectl apply -f security/fixes/06-checkout.yaml"
echo "  kubectl apply -f security/fixes/07-gateway.yaml"
echo ""
echo "Step 2: Delete old toolbox and apply hardened version:"
echo "  kubectl delete pod toolbox --ignore-not-found"
echo "  kubectl apply -f security/fixes/10-toolbox.yaml"
echo ""
echo "Step 3: Apply NetworkPolicies:"
echo "  kubectl apply -f security/fixes/11-default-deny.yaml"
echo "  kubectl apply -f security/fixes/12-allow-gateway.yaml"
echo "  kubectl apply -f security/fixes/13-allow-checkout.yaml"
echo "  kubectl apply -f security/fixes/14-allow-pricing-inventory.yaml"
echo "  kubectl apply -f security/fixes/15-allow-postgres.yaml"
echo ""
echo "Step 4: Verify everything still works:"
echo "  kubectl get pods     # All should be Running"
echo "  # Test from your Windows browser: http://localhost:8080/health"
echo ""
#!/bin/bash
# =============================================================================
# Click-Cart Assignment 2 — Security Fixes
# =============================================================================
# Run this script from ~/Click-Cart on your VM:
#   chmod +x create-security-fixes.sh
#   ./create-security-fixes.sh
#
# WHAT THIS DOES:
# Creates hardened versions of your Kubernetes manifests in security/fixes/
# You'll apply them AFTER reviewing what changed.
# =============================================================================

set -e
cd ~/Click-Cart
mkdir -p security/fixes

echo "================================================"
echo "Creating hardened Kubernetes manifests..."
echo "================================================"

# =============================================================================
# FIX 1: SECRETS — Remove plaintext password from Git
# =============================================================================
# WHAT'S WRONG:
#   Your 01-postgres-secret.yaml has the actual password "sup3rS3cret!"
#   written in plain text. Anyone who can read your Git repo can see it.
#   base64 encoding (which Kubernetes does automatically) is NOT encryption —
#   it's like writing the password backwards and calling it "secure".
#
# WHAT WE'RE DOING:
#   1. Creating a .env file with the credentials (excluded from Git)
#   2. Creating a placeholder YAML that documents the new workflow
#   3. Adding .env files to .gitignore
#
# HOW TO USE:
#   Instead of: kubectl apply -f k8s/01-postgres-secret.yaml
#   You'll run:  kubectl create secret generic postgres-secret --from-env-file=k8s/.env.postgres
# =============================================================================

echo "[1/8] Creating secrets fix..."

cat > k8s/.env.postgres << 'ENV'
POSTGRES_USER=checkout
POSTGRES_PASSWORD=N3wR0tated$ecret2026!
POSTGRES_DB=checkoutdb
ENV

cat > security/fixes/01-postgres-secret-placeholder.yaml << 'YAML'
# ============================================================
# PLACEHOLDER — Do NOT apply this file directly
# ============================================================
# The actual secret is created at deploy time using:
#
#   kubectl create secret generic postgres-secret \
#     --from-env-file=k8s/.env.postgres
#
# The .env.postgres file is excluded from Git via .gitignore
# This prevents credentials from ever entering version control
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  labels:
    app: postgres
type: Opaque
# No stringData here — credentials loaded from .env at deploy time
YAML

# Add .env files to .gitignore (only if not already there)
grep -q "k8s/.env.*" .gitignore 2>/dev/null || echo "k8s/.env.*" >> .gitignore

echo "   ✓ Secrets placeholder created"
echo "   ✓ .env.postgres created (excluded from Git)"
echo "   ✓ .gitignore updated"

# =============================================================================
# FIX 2: POSTGRES DEPLOYMENT — Add securityContext
# =============================================================================
# WHAT'S WRONG:
#   Postgres pod has NO securityContext at all. It runs as root, can escalate
#   privileges, has all Linux capabilities, and can write anywhere on disk.
#
# WHAT WE'RE ADDING:
#   - allowPrivilegeEscalation: false → container can't gain more privileges
#   - capabilities.drop: [ALL] → removes all Linux capabilities (like NET_RAW,
#     SYS_ADMIN etc.) that could be used for attacks
#   - automountServiceAccountToken: false → prevents the pod from talking to
#     the Kubernetes API (Postgres has no reason to call kubectl)
#
# WHY NOT runAsNonRoot?
#   The official postgres:16-alpine image NEEDS to start as root to initialize
#   the database, then drops to the 'postgres' user internally. So we can't
#   set runAsNonRoot here — but we CAN restrict everything else.
# =============================================================================

echo "[2/8] Creating hardened postgres deployment..."

cat > security/fixes/03-postgres.yaml << 'YAML'
# PostgreSQL Deployment — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false (no K8s API access)
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access needed
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-secret
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "checkout"]
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "checkout"]
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:                    # NEW: Hardened security
            allowPrivilegeEscalation: false   # Can't gain more privileges
            capabilities:
              drop:
                - ALL                         # Remove all Linux capabilities
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  labels:
    app: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
YAML

echo "   ✓ Postgres hardened (capabilities dropped, no API token)"

# =============================================================================
# FIX 3: CHECKOUT DEPLOYMENT — Add missing security settings
# =============================================================================
# WHAT'S WRONG:
#   Checkout has runAsNonRoot and runAsUser but is MISSING:
#   - readOnlyRootFilesystem (attacker could write malware to /app)
#   - allowPrivilegeEscalation (could gain root)
#   - capabilities.drop (has full Linux capabilities)
#   - automountServiceAccountToken (can call Kubernetes API)
#
# WHAT WE'RE ADDING:
#   All four missing settings, plus a /tmp volume mount because Python
#   needs a writable temp directory and readOnlyRootFilesystem blocks /tmp
# =============================================================================

echo "[3/8] Creating hardened checkout deployment..."

cat > security/fixes/06-checkout.yaml << 'YAML'
# Checkout Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + readOnlyRootFilesystem: true (was missing!)
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume (Python needs writable temp dir)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  labels:
    app: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access
      containers:
        - name: checkout
          image: checkout:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8001
          envFrom:
            - secretRef:
                name: postgres-secret
          env:
            - name: PRICING_URL
              value: "http://pricing-svc"
            - name: INVENTORY_URL
              value: "http://inventory-svc"
            - name: DB_HOST
              value: "postgres-svc"
            - name: DB_PORT
              value: "5432"
            - name: DEPENDENCY_TIMEOUT
              value: "3.0"
          startupProbe:
            httpGet:
              path: /health
              port: 8001
            failureThreshold: 10
            periodSeconds: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8001
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8001
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:
            runAsNonRoot: true               # KEPT from original
            runAsUser: 1000                  # KEPT from original
            readOnlyRootFilesystem: true      # NEW: Can't write to container
            allowPrivilegeEscalation: false   # NEW: Can't gain privileges
            capabilities:
              drop:
                - ALL                         # NEW: Drop all capabilities
          volumeMounts:                       # NEW: Python needs writable /tmp
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}                       # Writable temp dir backed by RAM
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-svc
  labels:
    app: checkout
spec:
  selector:
    app: checkout
  ports:
    - port: 80
      targetPort: 8001
  type: ClusterIP
YAML

echo "   ✓ Checkout hardened (readOnly, drop ALL, no API token)"

# =============================================================================
# FIX 4: PRICING DEPLOYMENT — Add missing security settings
# =============================================================================
# WHAT'S WRONG:
#   Pricing already has runAsNonRoot, runAsUser, readOnlyRootFilesystem (good!)
#   but is MISSING:
#   - allowPrivilegeEscalation: false
#   - capabilities.drop: [ALL]
#   - automountServiceAccountToken: false
# =============================================================================

echo "[4/8] Creating hardened pricing deployment..."

cat > security/fixes/04-pricing.yaml << 'YAML'
# Pricing Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume (needed for readOnlyRootFilesystem)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  labels:
    app: pricing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pricing
  template:
    metadata:
      labels:
        app: pricing
    spec:
      automountServiceAccountToken: false    # NEW: No K8s API access
      containers:
        - name: pricing
          image: pricing:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8002
          readinessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT from original
            runAsUser: 1000                  # KEPT from original
            readOnlyRootFilesystem: true      # KEPT from original
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW: Python needs writable /tmp
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: pricing-svc
  labels:
    app: pricing
spec:
  selector:
    app: pricing
  ports:
    - port: 80
      targetPort: 8002
  type: ClusterIP
YAML

echo "   ✓ Pricing hardened (drop ALL, no API token)"

# =============================================================================
# FIX 5: INVENTORY DEPLOYMENT — Same pattern as pricing
# =============================================================================

echo "[5/8] Creating hardened inventory deployment..."

cat > security/fixes/05-inventory.yaml << 'YAML'
# Inventory Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
  labels:
    app: inventory
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inventory
  template:
    metadata:
      labels:
        app: inventory
    spec:
      automountServiceAccountToken: false    # NEW
      containers:
        - name: inventory
          image: inventory:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8003
          readinessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8003
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT
            runAsUser: 1000                  # KEPT
            readOnlyRootFilesystem: true      # KEPT
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: inventory-svc
  labels:
    app: inventory
spec:
  selector:
    app: inventory
  ports:
    - port: 80
      targetPort: 8003
  type: ClusterIP
YAML

echo "   ✓ Inventory hardened (drop ALL, no API token)"

# =============================================================================
# FIX 6: GATEWAY DEPLOYMENT — Add missing security settings
# =============================================================================

echo "[6/8] Creating hardened gateway deployment..."

cat > security/fixes/07-gateway.yaml << 'YAML'
# Gateway Service — HARDENED for Assignment 2
# Changes from original:
#   + automountServiceAccountToken: false
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + /tmp emptyDir volume
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  labels:
    app: gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gateway
  template:
    metadata:
      labels:
        app: gateway
    spec:
      automountServiceAccountToken: false    # NEW
      containers:
        - name: gateway
          image: gateway:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 8000
          env:
            - name: CHECKOUT_URL
              value: "http://checkout-svc"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "250m"
          securityContext:
            runAsNonRoot: true               # KEPT
            runAsUser: 1000                  # KEPT
            readOnlyRootFilesystem: true      # KEPT
            allowPrivilegeEscalation: false   # NEW
            capabilities:
              drop:
                - ALL                         # NEW
          volumeMounts:                       # NEW
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: gateway-svc
  labels:
    app: gateway
spec:
  selector:
    app: gateway
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
YAML

echo "   ✓ Gateway hardened (drop ALL, no API token)"

# =============================================================================
# FIX 7: TOOLBOX POD — Harden or document for removal
# =============================================================================
# WHAT'S WRONG:
#   The toolbox pod is a troubleshooting tool with ZERO security restrictions.
#   It runs as root, has all capabilities, can access the Kubernetes API via
#   the default ServiceAccount, and sleeps for 10 hours (36000 seconds).
#   If an attacker gets shell access to ANY pod, they could use the toolbox
#   as a lateral-movement beachhead.
#
# WHAT WE'RE DOING:
#   Hardening it for dev use + documenting that it should be DELETED in production.
# =============================================================================

echo "[7/8] Creating hardened toolbox pod..."

cat > security/fixes/10-toolbox.yaml << 'YAML'
# Toolbox Pod — HARDENED for Assignment 2
# ⚠️  In PRODUCTION: DELETE this pod entirely. It exists only for dev debugging.
#
# Changes from original:
#   + automountServiceAccountToken: false (no K8s API access)
#   + runAsNonRoot: true + runAsUser: 1000
#   + readOnlyRootFilesystem: true
#   + allowPrivilegeEscalation: false
#   + capabilities.drop: [ALL]
#   + Sleep reduced from 36000s (10hrs) to 3600s (1hr)
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  labels:
    app: toolbox
spec:
  automountServiceAccountToken: false        # NEW: No K8s API access
  containers:
    - name: toolbox
      image: nicolaka/netshoot:latest
      command: ["sleep", "3600"]             # CHANGED: 1hr instead of 10hrs
      resources:
        requests:
          memory: "32Mi"
          cpu: "10m"
        limits:
          memory: "64Mi"
          cpu: "100m"
      securityContext:                        # NEW: Full hardening
        runAsNonRoot: true
        runAsUser: 1000
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
  restartPolicy: Never
YAML

echo "   ✓ Toolbox hardened (non-root, drop ALL, 1hr sleep)"

# =============================================================================
# FIX 8: NETWORK POLICIES — Build walls between services
# =============================================================================
# WHAT'S WRONG:
#   Right now ANY pod can talk to ANY other pod. That means if an attacker
#   compromises the Gateway, they can directly access PostgreSQL, read the
#   database, and steal all data. There are no walls.
#
# WHAT WE'RE DOING:
#   1. Default-deny: block ALL traffic first (lock every door)
#   2. Then open ONLY the specific doors each service needs:
#      - Gateway can ONLY talk to Checkout
#      - Checkout can talk to Pricing, Inventory, and Postgres
#      - Pricing and Inventory can ONLY receive from Checkout
#      - Postgres can ONLY receive from Checkout
# =============================================================================

echo "[8/8] Creating NetworkPolicy manifests..."

cat > security/fixes/11-default-deny.yaml << 'YAML'
# Default Deny — Block ALL traffic first, then allow specific paths
# Think of it like: "The café is closed. Now let's decide who gets keys."
#
# Without this policy, Kubernetes allows ALL pod-to-pod communication.
# This is the #1 recommendation in the NSA/CISA Kubernetes Hardening Guide.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}           # Applies to ALL pods in the namespace
  policyTypes:
    - Ingress               # Block all incoming traffic
    - Egress                # Block all outgoing traffic
YAML

cat > security/fixes/12-allow-gateway.yaml << 'YAML'
# Gateway NetworkPolicy
# The front door of the café — customers can enter, waiter can go to kitchen
#
# ALLOWS:
#   IN:  Traffic from anywhere (Traefik Ingress sends customer requests here)
#   OUT: Only to checkout-svc (the kitchen) + DNS (so it can resolve service names)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway
spec:
  podSelector:
    matchLabels:
      app: gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from: []                            # Allow from anywhere (Traefik)
      ports:
        - port: 8000
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: checkout               # Can ONLY reach checkout
      ports:
        - port: 8001
    - to:                                 # DNS resolution (required!)
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/13-allow-checkout.yaml << 'YAML'
# Checkout NetworkPolicy
# The kitchen — receives orders from waiter, talks to menu board,
# stockroom, and record book
#
# ALLOWS:
#   IN:  Only from gateway (the waiter brings orders)
#   OUT: To pricing, inventory, postgres, and DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-checkout
spec:
  podSelector:
    matchLabels:
      app: checkout
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - port: 8001
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: pricing
      ports:
        - port: 8002
    - to:
        - podSelector:
            matchLabels:
              app: inventory
      ports:
        - port: 8003
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
    - to:                                 # DNS
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/14-allow-pricing-inventory.yaml << 'YAML'
# Pricing & Inventory NetworkPolicies
# The menu board and stockroom — only the kitchen staff (checkout) can enter
#
# ALLOWS:
#   IN:  Only from checkout
#   OUT: DNS only (these services don't call anything else)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-pricing
spec:
  podSelector:
    matchLabels:
      app: pricing
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 8002
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-inventory
spec:
  podSelector:
    matchLabels:
      app: inventory
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 8003
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

cat > security/fixes/15-allow-postgres.yaml << 'YAML'
# PostgreSQL NetworkPolicy
# The record book — locked in a cage, only the head chef (checkout) has the key
#
# ALLOWS:
#   IN:  Only from checkout on port 5432
#   OUT: Nothing (Postgres doesn't need to call any other service)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - port: 5432
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YAML

echo "   ✓ NetworkPolicies created (default-deny + 5 allow rules)"

echo ""
echo "================================================"
echo "✅ ALL FILES CREATED SUCCESSFULLY"
echo "================================================"
echo ""
echo "Files created in security/fixes/:"
ls -1 security/fixes/
echo ""
echo "================================================"
echo "NEXT STEPS — Apply the fixes to your cluster:"
echo "================================================"
echo ""
echo "Step 1: Apply the hardened deployments (one at a time):"
echo "  kubectl apply -f security/fixes/03-postgres.yaml"
echo "  kubectl apply -f security/fixes/04-pricing.yaml"
echo "  kubectl apply -f security/fixes/05-inventory.yaml"
echo "  kubectl apply -f security/fixes/06-checkout.yaml"
echo "  kubectl apply -f security/fixes/07-gateway.yaml"
echo ""
echo "Step 2: Delete old toolbox and apply hardened version:"
echo "  kubectl delete pod toolbox --ignore-not-found"
echo "  kubectl apply -f security/fixes/10-toolbox.yaml"
echo ""
echo "Step 3: Apply NetworkPolicies:"
echo "  kubectl apply -f security/fixes/11-default-deny.yaml"
echo "  kubectl apply -f security/fixes/12-allow-gateway.yaml"
echo "  kubectl apply -f security/fixes/13-allow-checkout.yaml"
echo "  kubectl apply -f security/fixes/14-allow-pricing-inventory.yaml"
echo "  kubectl apply -f security/fixes/15-allow-postgres.yaml"
echo ""
echo "Step 4: Verify everything still works:"
echo "  kubectl get pods     # All should be Running"
echo "  # Test from your Windows browser: http://localhost:8080/health"
echo ""
