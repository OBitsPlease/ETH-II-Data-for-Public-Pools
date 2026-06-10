#!/bin/bash
# ETH II Public Pool Setup Script - Linux
# Chain ID: 20482
#
# Usage:
#   ./setup-pool.sh --etherbase 0xYOUR_ADDRESS           (first run / start)
#   ./setup-pool.sh --etherbase 0xYOUR_ADDRESS --restart (stop existing then start fresh)
#   ./setup-pool.sh --stop                               (stop only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ETHII_EXE="$SCRIPT_DIR/ethii"
STRATUM_EXE="$SCRIPT_DIR/stratum"
GENESIS_FILE="$REPO_ROOT/genesis.json"
STATIC_NODES="$REPO_ROOT/static-nodes.json"

DATA_DIR="/opt/eth2-pool/data"
STRATUM_PORT=3335
A10_PORT=3336
DASHBOARD_PORT=8082
ETHERBASE=""
DO_STOP=false
DO_RESTART=false
PID_FILE="$DATA_DIR/pool.pids"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --etherbase) ETHERBASE="$2"; shift 2 ;;
        --datadir)   DATA_DIR="$2"; shift 2 ;;
        --stratum-port) STRATUM_PORT="$2"; shift 2 ;;
        --stop)      DO_STOP=true; shift ;;
        --restart)   DO_RESTART=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

stop_pool() {
    echo "Stopping ETH II pool services..."
    local stopped=0
    if [[ -f "$PID_FILE" ]]; then
        while IFS= read -r pid; do
            pid="${pid// /}"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null && echo "  Stopped PID $pid"
                stopped=$((stopped+1))
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
    # Also kill any stray processes
    for name in ethii stratum; do
        mapfile -t pids < <(pgrep -x "$name" 2>/dev/null || true)
        for pid in "${pids[@]}"; do
            if [[ -n "$pid" ]]; then
                kill "$pid" 2>/dev/null && echo "  Stopped stray $name PID $pid"
                stopped=$((stopped+1))
            fi
        done
    done
    if [[ $stopped -eq 0 ]]; then
        echo "  No running pool processes found."
    else
        echo "  Stopped $stopped process(es)."
    fi
}

if $DO_STOP || $DO_RESTART; then
    stop_pool
    if $DO_STOP; then exit 0; fi
    echo "Waiting 5 seconds before restart..."
    sleep 5
fi

# Validate
if [[ -z "$ETHERBASE" ]]; then
    echo "ERROR: --etherbase is required"
    echo "Usage: $0 --etherbase 0xYOUR_ADDRESS"
    exit 1
fi
if [[ ! "$ETHERBASE" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: Etherbase must be a valid Ethereum address (0x...)"
    exit 1
fi
for f in "$ETHII_EXE" "$STRATUM_EXE" "$GENESIS_FILE" "$STATIC_NODES"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f"
        exit 1
    fi
done
chmod +x "$ETHII_EXE" "$STRATUM_EXE"

# Stop any already-running instance
if pgrep -x ethii > /dev/null 2>&1 || pgrep -x stratum > /dev/null 2>&1; then
    echo "Found existing pool processes - stopping them first..."
    stop_pool
    sleep 3
fi

echo "=== ETH II Public Pool Setup ==="
echo "  Chain ID:    20482"
echo "  Etherbase:   $ETHERBASE"
echo "  Data dir:    $DATA_DIR"
echo "  Stratum:     0.0.0.0:$STRATUM_PORT"
echo ""

mkdir -p "$DATA_DIR"

# Init genesis if not already done
if [[ ! -d "$DATA_DIR/geth/chaindata" ]]; then
    echo "Initializing genesis block (chain ID 20482)..."
    "$ETHII_EXE" --datadir "$DATA_DIR" --state.scheme hash init "$GENESIS_FILE" 2>&1 | \
        grep -E "INFO|WARN|ERROR" | sed 's/^/  /' || true
    echo "Genesis initialized."
else
    echo "Chain data already exists, skipping genesis init."
fi

# Copy static-nodes.json to geth subdir (must exist after genesis init)
mkdir -p "$DATA_DIR/geth"
cp "$STATIC_NODES" "$DATA_DIR/geth/static-nodes.json"
echo "Copied static nodes -> $DATA_DIR/geth/static-nodes.json"

# Write etherbase file — this geth build reads it at startup to set the block coinbase
echo "$ETHERBASE" > "$DATA_DIR/geth/etherbase.txt"
echo "Wrote etherbase -> $DATA_DIR/geth/etherbase.txt"

NODE_LOG="$DATA_DIR/node.log"
STRATUM_LOG="$DATA_DIR/stratum.log"
STRATUM_ERR_LOG="$DATA_DIR/stratum.err.log"

echo ""
echo "Starting ETH II node..."
# Detect external IP so geth advertises the correct P2P address to bootstrap nodes
EXTERNAL_IP=$(curl -sf --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
              curl -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
              curl -sf --connect-timeout 5 https://icanhazip.com 2>/dev/null || true)
if [[ -n "$EXTERNAL_IP" ]]; then
    echo "  Detected external IP: $EXTERNAL_IP"
    NAT_FLAG="--nat extip:$EXTERNAL_IP"
else
    echo "  WARNING: Could not detect external IP, using --nat any (UPnP/STUN fallback)"
    NAT_FLAG="--nat any"
fi
"$ETHII_EXE" \
    --datadir "$DATA_DIR" \
    --networkid 20482 \
    --syncmode full \
    --gcmode archive \
    --state.scheme hash \
    --http --http.addr 127.0.0.1 --http.port 8545 \
    --http.api eth,net,web3,miner,admin,debug,ethash \
    --http.corsdomain '*' \
    --http.vhosts '*' \
    --port 30303 \
    $NAT_FLAG \
    --miner.pending.feeRecipient "$ETHERBASE" \
    --verbosity 3 \
    --bootnodes "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303,enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303" \
    >> "$NODE_LOG" 2>&1 &
NODE_PID=$!
echo "  Node PID: $NODE_PID  Log: $NODE_LOG"

# Wait for RPC to come up
echo "Waiting for node RPC to start..."
RPC_READY=false
for i in $(seq 1 60); do
    sleep 2
    result=$(curl -sf -X POST http://127.0.0.1:8545 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    if echo "$result" | grep -q '"result"'; then
        RPC_READY=true
        break
    fi
done
if ! $RPC_READY; then
    echo "WARNING: Node RPC not responding after 120s. Check: $NODE_LOG"
    exit 1
fi
echo "  Node RPC ready."
# Bootstrap peer connections and recover from genesis stall
echo "Bootstrapping peer connections..."
BOOTSTRAP_ENODES=(
  "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303"
  "enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"
  "enode://011eb4ce88a91a6f782ddf87c2cf18c5af57194390fb539f63af507f053fb36de4687905b220cce05b0759be95a7810cc204b90257c294778fa6a1683ee3d413@134.209.126.146:30303"
)
for en in "${BOOTSTRAP_ENODES[@]}"; do
  curl -sf -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$en\"],\"id\":1}" > /dev/null || true
  curl -sf -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addTrustedPeer\",\"params\":[\"$en\"],\"id\":1}" > /dev/null || true
done

# If stuck at block 0, trigger debug_sync with remote chain head
echo "Checking for genesis stall..."
sleep 10
REMOTE_JSON=$(curl -sf -X POST https://www.ethii.net/rpc -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' 2>/dev/null || true)
TARGET_HASH=$(echo "$REMOTE_JSON" | grep -oP '"hash":"\K[^"]+' || true)
TARGET_NUM_HEX=$(echo "$REMOTE_JSON" | grep -oP '"number":"\K[^"]+' || true)
LOCAL_HEX=$(curl -sf -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | \
  grep -oP '"result":"\K[^"]+' || echo "0x0")
LOCAL_BLK=$((16#${LOCAL_HEX#0x}))
TARGET_BLK=$((16#${TARGET_NUM_HEX#0x}))
if [[ $LOCAL_BLK -eq 0 && $TARGET_BLK -gt 0 && -n "$TARGET_HASH" ]]; then
  echo "  Genesis stall detected (local=0, remote=$TARGET_BLK). Triggering debug_sync..."
  curl -sf -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"debug_sync\",\"params\":[\"$TARGET_HASH\"],\"id\":1}" > /dev/null || true
  echo "  debug_sync triggered."
else
  echo "  Node at block $LOCAL_BLK, no stall."
fi

# Start miner in remote/ASIC mode — 0 CPU threads means NO CPU mining.
# This only activates the work-serving subsystem so ASICs can receive PoW jobs
# via ethash_getWork / eth_submitWork.  The actual block-solving is done by
# connected ASIC miners through the stratum server.
miner_result=$(curl -sf -X POST http://127.0.0.1:8545 \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"miner_start","params":[0],"id":1}' 2>/dev/null || true)
if echo "$miner_result" | grep -q '"result"'; then
    echo "  Miner started (0 CPU threads — ASIC remote mining mode)."
else
    echo "  WARNING: miner_start returned: $miner_result"
fi

# Wait for sync before starting stratum
echo "Waiting for node to sync to canonical chain..."
echo "  (This may take a few minutes on first run)"
SYNC_READY=false
SYNC_WAIT=0
MAX_SYNC_WAIT=1800
while ! $SYNC_READY && [[ $SYNC_WAIT -lt $MAX_SYNC_WAIT ]]; do
    sleep 10
    SYNC_WAIT=$((SYNC_WAIT+10))
    SYNCING=$(curl -sf -X POST http://127.0.0.1:8545 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null || true)
    BLK_HEX=$(curl -sf -X POST http://127.0.0.1:8545 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | \
        grep -oP '"result":"\K[^"]+' || echo "0x0")
    LOCAL_BLK=$((16#${BLK_HEX#0x}))
    if echo "$SYNCING" | grep -q '"result":false' && [[ $LOCAL_BLK -gt 0 ]]; then
        SYNC_READY=true
    elif [[ $((SYNC_WAIT % 30)) -eq 0 ]]; then
        echo "  Waiting for peers... block $LOCAL_BLK (${SYNC_WAIT}s)"
    fi
done
if ! $SYNC_READY; then
    echo "WARNING: Sync timed out. Starting stratum anyway - check node log."
else
    echo "  Node synced to canonical chain."
fi

# Start stratum
echo "Starting stratum..."
"$STRATUM_EXE" \
    --node "http://127.0.0.1:8545" \
    --stratum "0.0.0.0:$STRATUM_PORT" \
    --a10-stratum "0.0.0.0:$A10_PORT" \
    --dashboard "0.0.0.0:$DASHBOARD_PORT" \
    --interval 500ms \
    --etherbase "$ETHERBASE" \
    > "$STRATUM_LOG" 2> "$STRATUM_ERR_LOG" &
STRATUM_PID=$!
sleep 3
if kill -0 "$STRATUM_PID" 2>/dev/null; then
    echo "  Stratum running PID $STRATUM_PID. Dashboard: http://127.0.0.1:$DASHBOARD_PORT"
else
    echo "  WARNING: Stratum may not have started. Check: $STRATUM_ERR_LOG"
fi

# Save PIDs for future stop/restart
echo -e "$NODE_PID\n$STRATUM_PID" > "$PID_FILE"
echo "PIDs saved to $PID_FILE"

echo ""
echo "=== Pool is running ==="
echo "  Stratum (regular):  YOUR-PUBLIC-IP:$STRATUM_PORT"
echo "  Stratum (A10/ASIC): YOUR-PUBLIC-IP:$A10_PORT"
echo "  Dashboard:          http://127.0.0.1:$DASHBOARD_PORT"
echo "  Node log:           $NODE_LOG"
echo "  Stratum log:        $STRATUM_LOG"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "IMPORTANT FIREWALL REQUIREMENTS:"
echo "  You must open the following ports — in BOTH of these places:"
echo ""
echo "  1. Your OS firewall (UFW, iptables, etc.):"
echo "     ufw allow $STRATUM_PORT/tcp"
echo "     ufw allow $A10_PORT/tcp"
echo "     ufw allow 30303/tcp"
echo "     ufw allow 30303/udp"
echo ""
echo "  2. Your CLOUD PROVIDER control-panel firewall (if applicable):"
echo "     DigitalOcean → Networking → Firewalls"
echo "     Hetzner      → Firewall rules in project"
echo "     AWS          → EC2 Security Groups"
echo "     Vultr        → Firewall Groups"
echo "     Google Cloud → VPC → Firewall rules"
echo ""
echo "  ⚠ If your cloud provider has a firewall, you MUST open port 30303"
echo "    there as well. UFW alone is NOT enough — cloud firewalls sit in"
echo "    front of the server and block traffic before it reaches UFW."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
# Quick self-test: can we reach the ETH II bootstrap nodes?
echo "Testing connectivity to ETH II network nodes..."
for host in 87.99.142.128 91.99.231.217; do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host/30303" 2>/dev/null; then
        echo "  ✓ $host:30303 reachable"
    else
        echo "  ✗ $host:30303 UNREACHABLE — check your outbound firewall rules"
    fi
done
echo ""
echo "To stop: ./setup-pool.sh --stop"
echo "To restart: ./setup-pool.sh --etherbase $ETHERBASE --restart"
