# Click-Cart STRIDE Threat Model

## Overview
This threat model analyses the Click-Cart e-commerce platform using the STRIDE framework
(Microsoft, 2009). Each data flow between components is assessed for six threat categories:
Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service and
Elevation of Privilege.

## System Scope
Gateway → Checkout → [Pricing, Inventory] + PostgreSQL, deployed on K3s with Traefik Ingress.

## Threat Analysis

| # | Data Flow | Threat | STRIDE Category | Severity | Mitigation Applied | Residual Risk |
|---|-----------|--------|-----------------|----------|---------------------|---------------|
| T1 | Browser → Traefik Ingress | Eavesdropping on checkout data (item, quantity) transmitted in cleartext | Information Disclosure | High | TLS termination planned at Traefik with self-signed certificate | Self-signed cert does not prevent MITM in production; requires CA-signed cert |
| T2 | Browser → Traefik Ingress | Attacker impersonates the Click-Cart website | Spoofing | Medium | TLS certificate binds hostname to server identity | No client authentication; relies on browser trust model |
| T3 | Traefik → Gateway | Forged or replayed HTTP requests to the gateway from within the cluster | Spoofing | Medium | NetworkPolicy restricts ingress to gateway from Traefik only | No request authentication between Traefik and Gateway; mTLS via service mesh would address this |
| T4 | Gateway → Checkout | Malicious gateway pod sends crafted checkout requests | Tampering | Medium | NetworkPolicy: only gateway can reach checkout on port 8001; input validation via Pydantic schema | No mutual authentication; a compromised gateway pod could send arbitrary requests |
| T5 | Checkout → Pricing | Tampered price returned by a compromised pricing pod | Tampering | High | NetworkPolicy: only checkout can reach pricing; fallback prices provide a sanity baseline | No cryptographic integrity on pricing responses; production should add signed price tokens or mTLS |
| T6 | Checkout → Inventory | False stock count returned by compromised inventory pod | Tampering | Medium | NetworkPolicy: only checkout can reach inventory | Same as T5; no response integrity verification |
| T7 | Checkout → PostgreSQL | SQL injection via checkout parameters | Tampering | High | Parameterised queries used throughout (psycopg2 `%s` placeholders); input validation via Pydantic | Postgres user has broad database access; principle of least-privilege DB role not yet applied |
| T8 | Checkout → PostgreSQL | Stolen database credentials used to dump checkout_audit table | Information Disclosure | Critical | Secrets removed from Git; loaded from `.env` file at deploy time; `automountServiceAccountToken: false` on all pods | Secrets stored as base64 in K3s datastore (not encrypted at rest); `--secrets-encryption` flag recommended |
| T9 | Any pod → Kubernetes API | Compromised pod uses mounted ServiceAccount token to query API, list secrets, or create privileged pods | Elevation of Privilege | Critical | `automountServiceAccountToken: false` on all deployments; container escape test confirmed token is not mounted | Default namespace ServiceAccount still exists; per-service ServiceAccounts with minimal RBAC recommended |
| T10 | Any pod → Host | Container escape via privileged pod or hostPID/hostPath mounts | Elevation of Privilege | Critical | Pod Security Standards (baseline) applied in warn/audit mode; `readOnlyRootFilesystem: true`; `capabilities.drop: [ALL]` on application pods | PSS not in enforce mode due to Postgres root requirement; production should use `enforce=restricted` with operator-managed databases |
| T11 | Any pod → Any pod | Lateral movement across flat network after initial compromise | Elevation of Privilege | High | Default-deny NetworkPolicy applied; explicit allow rules per service pair | DNS egress is broadly allowed (required for service discovery); production should use DNS-aware policies (e.g., Cilium) |
| T12 | External → Checkout | Flood of fake checkout requests causing resource exhaustion | Denial of Service | Medium | Resource limits (CPU/memory) set on all pods; KEDA autoscaling on pricing | No rate limiting at Gateway or Ingress level; Traefik rate-limit middleware recommended |
| T13 | Checkout → Pricing | Pricing service failure cascading to checkout unavailability | Denial of Service | Medium | Circuit breaker (pybreaker, fail_max=3, 30s reset); fallback prices for known items; retry with exponential backoff | Circuit breaker does not cover unknown items; inventory has no fallback mechanism |
| T14 | Checkout audit log | Attacker modifies or deletes audit records after compromise | Repudiation | Medium | Structured JSON logging with request IDs; Loki log aggregation (immutable once ingested) | No log signing or tamper-evident logging; production should use append-only log storage |
| T15 | Container images | Supply chain attack via compromised base image or dependency | Tampering | High | Trivy image scanning (HIGH/CRITICAL); SBOM generation (CycloneDX) | Images not signed with Cosign; no admission-time signature verification; production should add Kyverno `verifyImages` policy |

## Risk Summary

| STRIDE Category | Count | Critical | High | Medium |
|-----------------|-------|----------|------|--------|
| Spoofing | 2 | 0 | 0 | 2 |
| Tampering | 4 | 0 | 2 | 2 |
| Repudiation | 1 | 0 | 0 | 1 |
| Information Disclosure | 2 | 1 | 1 | 0 |
| Denial of Service | 2 | 0 | 0 | 2 |
| Elevation of Privilege | 4 | 2 | 1 | 1 |
| **Total** | **15** | **3** | **4** | **8** |

## Key Takeaways
1. **Elevation of Privilege is the dominant risk category** — container escape, API token abuse, and lateral movement represent the highest-impact threats. Mitigations applied (PSS, NetworkPolicy, `automountServiceAccountToken: false`) address the most critical vectors.
2. **Information Disclosure through secrets management** is the second priority — plaintext secrets in Git have been remediated, but encryption at rest (`--secrets-encryption`) remains a recommended next step.
3. **Tampering risks on east-west traffic** are partially mitigated by NetworkPolicies but not fully addressed — mutual TLS (mTLS) via a service mesh would provide cryptographic integrity and authentication on all inter-service communication.
4. **Denial of Service is partially mitigated** by circuit breakers and resource limits, but the platform lacks rate limiting at the Ingress layer.

## References
- Microsoft. (2009). *The STRIDE Threat Model*. Microsoft Security Development Lifecycle.
- OWASP. (2025). *Kubernetes Top 10*. https://owasp.org/www-project-kubernetes-top-ten/
- NSA/CISA. (2022). *Kubernetes Hardening Guide v1.2*.
