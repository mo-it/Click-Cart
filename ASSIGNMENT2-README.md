# Click-Cart — Assignment 2: Security, Observability & Testing

## Added Structure
## Tools Used
| Tool | Purpose |
|------|---------|
| Trivy | Image + config vulnerability scanning |
| Kubescape | NSA framework compliance audit |
| Prometheus | Metrics collection |
| Grafana | Dashboard visualisation |
| Loki | Log aggregation |
| Promtail | Log shipping |

## Key Findings
| Priority | Finding | Status |
|----------|---------|--------|
| P1 | No NetworkPolicies | Fix prepared |
| P1 | Postgres: no runAsNonRoot | Fix prepared |
| P2 | CVE-2025-68121 (gosu, CRITICAL) | Needs rebuild |
| P2 | CVE-2025-62727 (Starlette DoS) | Upgrade req. |
| P3 | No rate limiting | Planned |

Service Source Code

Gateway service: https://github.com/mo-it/Click-Cart/blob/main/services/gateway/main.py
Checkout service: https://github.com/mo-it/Click-Cart/blob/main/services/checkout/main.py
Inventory service: https://github.com/mo-it/Click-Cart/blob/main/services/inventory/main.py
Pricing service: https://github.com/mo-it/Click-Cart/blob/main/services/pricing/main.py

Kubernetes Manifests (Original)

All K8s manifests: https://github.com/mo-it/Click-Cart/tree/main/k8s

Security Fixes (Hardened Manifests + NetworkPolicies)

All security fixes: https://github.com/mo-it/Click-Cart/tree/main/security/fixes
Default-deny NetworkPolicy: https://github.com/mo-it/Click-Cart/blob/main/security/fixes/11-default-deny.yaml
Hardened Postgres: https://github.com/mo-it/Click-Cart/blob/main/security/fixes/03-postgres.yaml

Security Scan Results

All scan results: https://github.com/mo-it/Click-Cart/tree/main/security/scans
Trivy — Postgres image: https://github.com/mo-it/Click-Cart/blob/main/security/scans/trivy-image-postgres.txt
Trivy — config (before): https://github.com/mo-it/Click-Cart/blob/main/security/scans/trivy-config-before.txt
Kubescape NSA (before): https://github.com/mo-it/Click-Cart/blob/main/security/scans/kubescape-nsa-before.txt
Container escape test: https://github.com/mo-it/Click-Cart/blob/main/security/scans/bad-pod-escape-test.txt
Container hardening tests: https://github.com/mo-it/Click-Cart/blob/main/security/scans/container-tests.txt

Observability

Observability manifests: https://github.com/mo-it/Click-Cart/tree/main/observability/manifests
STRIDE threat model: https://github.com/mo-it/Click-Cart/blob/main/security/stride-threat-model.md


Loki manifest: https://github.com/mo-it/Click-Cart/blob/main/observability/manifests/loki.yaml
Promtail manifest: https://github.com/mo-it/Click-Cart/blob/main/observability/manifests/promtail.yaml
Grafana dashboard: https://github.com/mo-it/Click-Cart/blob/main/observability/dashboards/click-cart-observability.json
Failure scenario script: https://github.com/mo-it/Click-Cart/blob/main/observability/failure-scenario.sh
