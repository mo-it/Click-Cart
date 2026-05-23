#!/bin/bash
echo "=== Trivy Scans ==="
for IMG in gateway checkout inventory pricing; do trivy image --severity HIGH,CRITICAL "docker.io/library/$IMG:latest" 2>&1 | tee "security/scans/trivy-image-$IMG.txt"; done
trivy image --severity HIGH,CRITICAL docker.io/library/postgres:16-alpine 2>&1 | tee security/scans/trivy-image-postgres.txt
trivy config . --severity HIGH,CRITICAL --report summary 2>&1 | tee security/scans/trivy-config-before.txt
