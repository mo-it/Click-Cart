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
