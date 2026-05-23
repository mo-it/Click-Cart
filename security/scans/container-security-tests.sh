#!/bin/bash
echo "=== CONTAINER SECURITY TESTS ==="
echo "Test 1: Write to filesystem"; kubectl exec deploy/checkout -- sh -c 'touch /app/hack' 2>&1
echo "Test 2: K8s API token"; kubectl exec deploy/checkout -- sh -c 'ls /var/run/secrets/kubernetes.io/serviceaccount/' 2>&1
echo "Test 3: Install packages"; kubectl exec deploy/checkout -- sh -c 'apt-get update' 2>&1
echo "Test 4: Current user"; kubectl exec deploy/checkout -- sh -c 'whoami && id' 2>&1
