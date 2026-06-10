#!/bin/bash
for i in $(seq 1 60); do
  result=$(curl -sf -X POST http://127.0.0.1:8545 -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
  if echo "$result" | grep -q '"result"'; then
    curl -sf -X POST http://127.0.0.1:8545 -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"miner_start","params":[0],"id":1}' > /dev/null
    echo "miner_start(0) called - remote sealing active, 0 CPU threads"
    exit 0
  fi
  sleep 2
done
echo "WARNING: RPC not ready after 120s"
exit 1
