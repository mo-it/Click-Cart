# Click Cart - Nanoservices on K3s

A microservices-based checkout workflow running on Kubernetes (K3s) with KEDA autoscaling, circuit breakers, structured logging, request correlation and PostgreSQL persistence.

Built with Python/FastAPI. Extends the Lab 9/12 patterns (gateway → checkout → pricing + inventory) with six production-grade enhancements.

## Architecture
Browser → Traefik Ingress → Gateway → Checkout → [Pricing, Inventory] + PostgreSQL

Four FastAPI microservices running on K3s with KEDA autoscaling, structured JSON logging, and X-Request-Id correlation.

## Quick Start

### Prerequisites
- Ubuntu 22.04 VM (VirtualBox)
- Docker, K3s, Helm, KEDA installed

### Build and Deploy
```bash
chmod +x scripts/*.sh
./scripts/build.sh
for f in k8s/[0-9]*.yaml; do kubectl apply -f "$f"; done
```

### Access
- UI: http://localhost/ (or http://localhost:8080/ via NAT port forward)
- Health: http://localhost/health
- Architecture: http://localhost/api/arch
- Ping: http://localhost/api/ping
- Checkout: POST http://localhost/api/checkout

### Run Tests
```bash
./scripts/test-functional.sh
./scripts/test-reliability.sh
./scripts/test-scaling.sh
```

## Products

| ID     | Name                  | Price    | Stock |
|--------|-----------------------|----------|-------|
| WM-100 | Wireless Mouse        | €29.99   | 42    |
| BH-200 | Bluetooth Headphones  | €49.99   | 15    |
| UC-300 | USB-C Cable           | €9.99    | 100   |
| MK-400 | Mechanical Keyboard   | €199.99  | 3     |
| PS-500 | Phone Stand           | €14.50   | 0     |

## Production Enhancements

1. **Structured JSON logging**: machine-parseable, every line has request_id
2. **Circuit breaker** (pybreaker): opens after 3 failures, 30s recovery
3. **Retry with backoff**: 2 retries at 0.5s, 1s intervals
4. **Fallback pricing**: cached prices when pricing-svc is down
5. **Startup probe**: 30s boot window before K8s considers it failed
6. **Readiness endpoint**: /ready checks actual PostgreSQL connectivity

## Security

- All FastAPI containers run as non-root (appuser, UID 1000)
- PostgreSQL credentials managed via Kubernetes Secret (stringData)
- PostgreSQL runs as default postgres user (documented exception)
ENDOFREADME
