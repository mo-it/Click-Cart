#!/bin/bash
echo "=== FAILURE SCENARIO ==="
echo "--- Baseline ---"
curl -s -X POST -H "Content-Type: application/json" -d '{"item_id":"WM-100","quantity":1}' http://localhost:8080/api/checkout | python3 -m json.tool
echo "--- Breaking inventory ---"
sudo k3s kubectl scale deployment inventory --replicas=0
sudo k3s kubectl wait --for=delete pod -l app=inventory --timeout=30s
echo "--- Sending 20 failing requests ---"
for i in $(seq 1 20); do curl -s -X POST -w "\nHTTP:%{http_code}\n" -H "Content-Type: application/json" -H "X-Request-Id: fail-$i" -d '{"item_id":"WM-100","quantity":1}' http://localhost:8080/api/checkout; sleep 1; done
echo "--- Recovering ---"
sudo k3s kubectl scale deployment inventory --replicas=1; sleep 15
echo "--- Recovery requests ---"
for i in $(seq 1 10); do curl -s -X POST -w "\nHTTP:%{http_code}\n" -H "Content-Type: application/json" -H "X-Request-Id: recover-$i" -d '{"item_id":"WM-100","quantity":1}' http://localhost:8080/api/checkout; sleep 1; done
echo "=== DONE — Check Grafana (Last 30 min) ==="
