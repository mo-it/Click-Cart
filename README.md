# Checkout Platform — Nanoservices on K3s

A microservices-based checkout workflow running on Kubernetes (K3s) with KEDA autoscaling, circuit breakers, structured logging, request correlation, and PostgreSQL persistence.

Built with Python/FastAPI. Extends the Lab 9/12 patterns (gateway → checkout → pricing + inventory) with six production-grade enhancements.

## Architecture

```
Browser/curl → Traefik Ingress → gateway-svc (port 80)
                                       ↓
                                  checkout-svc (port 80)
                                  ↙    ↓    ↘
                        pricing-svc  inventory-svc  postgres-svc
                        (KEDA 0→5)                  (PVC + Secret)
```

## Services

| Service | Container Port | Service Port | Description |
|---------|---------------|-------------|-------------|
| Gateway | 8000 | 80 | UI, /api/arch, /api/ping, proxies /api/checkout |
| Checkout | 8001 | 80 | Orchestrates pricing + inventory with circuit breaker, writes audit to Postgres |
| Pricing | 8002 | 80 | Stateless price lookup (KEDA scale-to-zero) |
| Inventory | 8003 | 80 | Stock level lookup |
| PostgreSQL | 5432 | 5432 | Audit log with PVC persistence |

## Enhancements Beyond Lab Examples

| Enhancement | What It Does | Why It Matters |
|-------------|-------------|----------------|
| Structured JSON logging | Every log line is `{"timestamp", "service", "request_id", ...}` | Machine-parseable, `jq`-queryable, ELK/Loki-ready |
| Circuit breaker (`pybreaker`) | Opens after 3 failures, rejects for 30s, half-opens to test | Prevents cascading failure when dependency is down |
| Retry with exponential backoff | 2 retries with 0.5s→1s delay | Handles KEDA cold-start race condition |
| Graceful fallback pricing | Returns cached price when pricing-svc is down | Checkout succeeds (degraded) instead of hard-failing |
| Startup probe (separate from readiness) | Gives pod 30s to boot before K8s checks readiness | Prevents premature restarts during cold starts |
| `/ready` endpoint | Verifies actual Postgres connectivity | Traffic only routes when service can process requests |

## Prerequisites

- K3s installed (`curl -sfL https://get.k3s.io | sh -`)
- Docker (for building images)
- kubectl configured (`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`)
- KEDA (installed automatically by deploy.sh via Helm)

## Quick Start

```bash
# 1. Build all service images and import into K3s
chmod +x scripts/*.sh
./scripts/build.sh

# 2. Deploy everything
./scripts/deploy.sh

# 3. Test it
curl http://localhost/api/ping
curl -X POST http://localhost/api/checkout \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: test-001" \
  -d '{"item_id":"WIDGET-1","quantity":2}'

# 4. Open the UI
open http://localhost/
```

## Testing

```bash
# Functional tests (happy path, edge cases, X-Request-Id correlation)
./scripts/test-functional.sh

# Reliability tests (dependency down, bad rollout, Lab 3.7 diagnosis workflow)
./scripts/test-reliability.sh

# Scaling tests (cold vs warm latency, KEDA status, persistence proof)
./scripts/test-scaling.sh
```

## Available Items

| Item ID | Price | Stock | Test Scenario |
|---------|-------|-------|---------------|
| WIDGET-1 | €29.99 | 42 | Happy path |
| WIDGET-2 | €49.99 | 15 | Happy path |
| WIDGET-3 | €9.99 | 100 | Happy path |
| GADGET-1 | €199.99 | 3 | Low stock edge case |
| GADGET-2 | €14.50 | 0 | Out of stock |

## Teardown

```bash
./scripts/teardown.sh
```

## Project Structure

```
checkout-platform/
├── k8s/                          # Kubernetes manifests (numbered apply order)
│   ├── 01-postgres-secret.yaml   # Credentials (stringData)
│   ├── 02-postgres-pvc.yaml      # 1Gi local-path PVC
│   ├── 03-postgres.yaml          # Deployment + Service
│   ├── 04-pricing.yaml           # KEDA-managed (0→5 replicas)
│   ├── 05-inventory.yaml         # Fixed 1 replica
│   ├── 06-checkout.yaml          # Orchestrator + Postgres env
│   ├── 07-gateway.yaml           # Edge / UI / proxy
│   ├── 08-ingress.yaml           # Traefik (ingressClassName: traefik)
│   ├── 09-keda-pricing.yaml      # ScaledObject for pricing
│   └── 10-toolbox.yaml           # nicolaka/netshoot for debugging
├── services/
│   ├── gateway/                   # Python/FastAPI, port 8000
│   ├── checkout/                  # Python/FastAPI, port 8001, pybreaker
│   ├── pricing/                   # Python/FastAPI, port 8002
│   └── inventory/                 # Python/FastAPI, port 8003
├── scripts/
│   ├── build.sh                   # Build + import images into K3s
│   ├── deploy.sh                  # Install KEDA + apply all manifests
│   ├── test-functional.sh         # Happy path, edge cases, correlation
│   ├── test-reliability.sh        # Dependency down, bad rollout, R5 workflow
│   ├── test-scaling.sh            # Cold/warm latency, persistence proof
│   └── teardown.sh                # Clean removal of all resources
└── README.md
```
