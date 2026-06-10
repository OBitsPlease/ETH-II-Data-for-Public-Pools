# ETH II Public Pool Setup Script
# Run as Administrator
# Chain ID: 20482
#
# Usage:
#   .\setup-pool.ps1 -Etherbase 0xYOUR_ADDRESS           (first run / start)
#   .\setup-pool.ps1 -Etherbase 0xYOUR_ADDRESS -Restart  (stop existing then start fresh)
#   .\setup-pool.ps1 -Etherbase 0xYOUR_ADDRESS -StopPool (stop only)

param(
    [Parameter(Mandatory=$true)]
    [string]$Etherbase,
    [string]$DataDir = "C:\ETH-II-Pool\data",
    [int]$StratumPort = 3335,
    [int]$A10Port = 3336,
    [int]$DashboardPort = 8082,
    [switch]$StopPool,
    [switch]$Restart
)

# Script lives in windows\ subfolder; repo root is one level up
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = Split-Path -Parent $ScriptDir
$EthiiExe     = Join-Path $ScriptDir "ethii.exe"
$StratumExe   = Join-Path $ScriptDir "stratum.exe"
$GenesisFile  = Join-Path $RepoRoot "genesis.json"
$StaticNodes  = Join-Path $RepoRoot "static-nodes.json"
$PidFile      = Join-Path $DataDir "pool.pids"

function Invoke-PoolStop {
    Write-Host "Stopping ETH II pool services..." -ForegroundColor Yellow
    $stopped = 0
    if (Test-Path $PidFile) {
        Get-Content $PidFile | ForEach-Object {
            $pidVal = [int]$_.Trim()
            $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($proc) {
                $proc | Stop-Process -Force
                Write-Host ("  Stopped PID " + $pidVal + " (" + $proc.Name + ")") -ForegroundColor Green
                $stopped++
            }
        }
        Remove-Item $PidFile -Force
    }
    foreach ($procName in @("ethii", "stratum")) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host ("  Stopped stray " + $procName + " PID " + $p.Id) -ForegroundColor DarkYellow
            $stopped++
        }
    }
    if ($stopped -eq 0) {
        Write-Host "  No running pool processes found." -ForegroundColor DarkGray
    } else {
        Write-Host ("  Stopped " + $stopped + " process(es).") -ForegroundColor Green
    }
}

if ($StopPool -or $Restart) {
    Invoke-PoolStop
    if ($StopPool) { exit 0 }
    Write-Host "Waiting 5 seconds before restart..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

# Validate inputs
if ($Etherbase -notmatch "^0x[0-9a-fA-F]{40}$") {
    Write-Host "ERROR: Etherbase must be a valid Ethereum address (0x...)" -ForegroundColor Red
    exit 1
}
foreach ($reqFile in @($EthiiExe, $StratumExe, $GenesisFile, $StaticNodes)) {
    if (-not (Test-Path $reqFile)) {
        Write-Host ("ERROR: Required file not found: " + $reqFile) -ForegroundColor Red
        exit 1
    }
}

# Stop any already-running instance before starting fresh
$anyRunning = (Get-Process -Name "ethii","stratum" -ErrorAction SilentlyContinue | Measure-Object).Count
if ($anyRunning -gt 0) {
    Write-Host "Found existing pool processes - stopping them first..." -ForegroundColor Yellow
    Invoke-PoolStop
    Start-Sleep -Seconds 3
}

Write-Host "=== ETH II Public Pool Setup ===" -ForegroundColor Cyan
Write-Host "  Chain ID:    20482" -ForegroundColor Green
Write-Host "  Etherbase:   $Etherbase" -ForegroundColor Green
Write-Host "  Data dir:    $DataDir" -ForegroundColor Green
Write-Host ("  Stratum:     0.0.0.0:" + $StratumPort) -ForegroundColor Green
Write-Host ""


# Create data dir
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# Init genesis if not already done
$chaindata = Join-Path $DataDir "geth\chaindata"
if (-not (Test-Path $chaindata)) {
    Write-Host "Initializing genesis block (chain ID 20482)..." -ForegroundColor Yellow
    & $EthiiExe --datadir $DataDir --state.scheme hash init $GenesisFile 2>&1 |
        Where-Object { $_ -match "INFO|WARN|ERROR" } |
        ForEach-Object { Write-Host ("  " + $_) }
    Write-Host "Genesis initialized." -ForegroundColor Green
} else {
    Write-Host "Chain data already exists, skipping genesis init." -ForegroundColor DarkGray
}

# Copy static-nodes.json to geth subdir (must exist after genesis init)
$gethDir = Join-Path $DataDir "geth"
New-Item -ItemType Directory -Path $gethDir -Force | Out-Null
$staticDest = Join-Path $gethDir "static-nodes.json"
Copy-Item $StaticNodes $staticDest -Force
Write-Host ("Copied static nodes -> " + $staticDest)

# Detect external IP so geth advertises the correct P2P address to bootstrap nodes
Write-Host "Detecting external IP..." -ForegroundColor DarkGray
$externalIp = $null
foreach ($url in @("https://api.ipify.org","https://ifconfig.me","https://icanhazip.com")) {
    try {
        $externalIp = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).Content.Trim()
        if ($externalIp -match '^\d+\.\d+\.\d+\.\d+$') { break }
        $externalIp = $null
    } catch { $externalIp = $null }
}
if ($externalIp) {
    Write-Host ("  Detected external IP: " + $externalIp) -ForegroundColor Green
    $natFlag = "extip:$externalIp"
} else {
    Write-Host "  WARNING: Could not detect external IP, using --nat any (UPnP/STUN fallback)" -ForegroundColor Yellow
    $natFlag = "any"
}

# Build node launch args
$nodeArgs = @(
    "--datadir", ('"' + $DataDir + '"'),
    "--networkid", "20482",
    "--syncmode", "full",
    "--gcmode", "archive",
    "--state.scheme", "hash",
    "--http", "--http.addr", "127.0.0.1", "--http.port", "8545",
    "--http.api", "eth,net,web3,miner,admin,debug,ethash",
    "--http.corsdomain", "*",
    "--http.vhosts", "*",
    "--port", "30303",
    "--nat", $natFlag,
    "--miner.pending.feeRecipient", ('"' + $Etherbase + '"'),
    "--verbosity", "3",
    "--bootnodes", '"enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303,enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"'
)

$NodeLog       = Join-Path $DataDir "node.log"
$StratumLog    = Join-Path $DataDir "stratum.log"
$StratumErrLog = Join-Path $DataDir "stratum.err.log"

Write-Host ""
Write-Host "Starting ETH II node..." -ForegroundColor Yellow
$nodeProc = Start-Process -FilePath $EthiiExe -ArgumentList $nodeArgs -WindowStyle Minimized -RedirectStandardError $NodeLog -PassThru
Write-Host ("  Node PID: " + $nodeProc.Id + "  Log: " + $NodeLog) -ForegroundColor Green

# Wait for RPC to come up
Write-Host "Waiting for node RPC to start..." -ForegroundColor DarkYellow
$rpcReady = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST `
            -Headers @{'Content-Type'='application/json'} `
            -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -TimeoutSec 2
        if ($resp.result) { $rpcReady = $true; break }
    } catch { }
}
if (-not $rpcReady) {
    Write-Host ("WARNING: Node RPC not responding after 120s. Check: " + $NodeLog) -ForegroundColor Red
    exit 1
}
Write-Host "  Node RPC ready." -ForegroundColor Green
# Bootstrap peer connections and recover from genesis stall
$bootstrapEnodes = @(
    "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303",
    "enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303",
    "enode://011eb4ce88a91a6f782ddf87c2cf18c5af57194390fb539f63af507f053fb36de4687905b220cce05b0759be95a7810cc204b90257c294778fa6a1683ee3d413@134.209.126.146:30303"
)
Write-Host "Bootstrapping peer connections..." -ForegroundColor DarkYellow
foreach ($en in $bootstrapEnodes) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST -ContentType "application/json" -TimeoutSec 5 `
            -Body ((@{jsonrpc="2.0";id=1;method="admin_addPeer";params=@($en)}) | ConvertTo-Json -Compress) | Out-Null
        Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST -ContentType "application/json" -TimeoutSec 5 `
            -Body ((@{jsonrpc="2.0";id=1;method="admin_addTrustedPeer";params=@($en)}) | ConvertTo-Json -Compress) | Out-Null
    } catch { }
}

# If stuck at block 0, trigger debug_sync with remote chain head
Write-Host "Checking for genesis stall..." -ForegroundColor DarkGray
Start-Sleep -Seconds 10
try {
    $remoteHead = Invoke-RestMethod -Uri "https://www.ethii.net/rpc" -Method POST -ContentType "application/json" -TimeoutSec 10 `
        -Body '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'
    $targetHash  = $remoteHead.result.hash
    $targetBlock = [Convert]::ToInt64($remoteHead.result.number.Substring(2), 16)
    $localBlkResp = Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST -ContentType "application/json" -TimeoutSec 5 `
        -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    $localBlock = [Convert]::ToInt64($localBlkResp.result.Substring(2), 16)
    if ($localBlock -eq 0 -and $targetBlock -gt 0) {
        Write-Host ("  Genesis stall detected (local=0, remote=" + $targetBlock + "). Triggering debug_sync...") -ForegroundColor Yellow
        Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST -ContentType "application/json" -TimeoutSec 15 `
            -Body ((@{jsonrpc="2.0";id=1;method="debug_sync";params=@($targetHash)}) | ConvertTo-Json -Compress) | Out-Null
        Write-Host "  debug_sync triggered." -ForegroundColor Green
    } else {
        Write-Host ("  Node at block " + $localBlock + ", no stall.") -ForegroundColor Green
    }
} catch {
    Write-Host ("  Stall check skipped: " + $_.Exception.Message) -ForegroundColor DarkGray
}

# Start miner in remote/ASIC mode (0 CPU threads - PoW work is served to miners via stratum)
Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST `
    -Headers @{'Content-Type'='application/json'} `
    -Body '{"jsonrpc":"2.0","method":"miner_start","params":[0],"id":1}' -TimeoutSec 5 | Out-Null

# Wait for node to sync before starting stratum (prevents serving stale work on first run)
Write-Host "Waiting for node to sync to canonical chain..." -ForegroundColor DarkYellow
Write-Host "  (This may take a few minutes on first run)" -ForegroundColor DarkGray
$syncReady    = $false
$syncWaitSecs = 0
$maxSyncWait  = 1800
while (-not $syncReady -and $syncWaitSecs -lt $maxSyncWait) {
    Start-Sleep -Seconds 10
    $syncWaitSecs += 10
    try {
        $syncResp = Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST `
            -Headers @{'Content-Type'='application/json'} `
            -Body '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' -TimeoutSec 5
        $blkResp = Invoke-RestMethod -Uri "http://127.0.0.1:8545" -Method POST `
            -Headers @{'Content-Type'='application/json'} `
            -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -TimeoutSec 5
        $localBlk = [Convert]::ToInt64($blkResp.result, 16)
        if ($syncResp.result -eq $false -and $localBlk -gt 0) {
            $syncReady = $true
        } elseif ($syncWaitSecs % 30 -eq 0) {
            if ($syncResp.result -and $syncResp.result.currentBlock) {
                $cur = [Convert]::ToInt64($syncResp.result.currentBlock, 16)
                $hi  = [Convert]::ToInt64($syncResp.result.highestBlock, 16)
                Write-Host ("  Syncing... block " + $cur + " / " + $hi + " (" + $syncWaitSecs + "s)") -ForegroundColor DarkYellow
            } else {
                Write-Host ("  Waiting for peers... block " + $localBlk + " (" + $syncWaitSecs + "s)") -ForegroundColor DarkYellow
            }
        }
    } catch { }
}
if (-not $syncReady) {
    Write-Host "WARNING: Sync timed out. Starting stratum anyway - check node log." -ForegroundColor Yellow
} else {
    Write-Host "  Node synced to canonical chain." -ForegroundColor Green
}

# Start stratum
Write-Host "Starting stratum..." -ForegroundColor Yellow
$stratumArgs = (
    "--node `"http://127.0.0.1:8545`"" +
    " --stratum `"0.0.0.0:$StratumPort`"" +
    " --a10-stratum `"0.0.0.0:$A10Port`"" +
    " --dashboard `"0.0.0.0:$DashboardPort`"" +
    " --interval 500ms" +
    " --etherbase `"$Etherbase`""
)
$stratumProc = Start-Process -FilePath $StratumExe -ArgumentList $stratumArgs -WindowStyle Minimized `
    -RedirectStandardOutput $StratumLog -RedirectStandardError $StratumErrLog -PassThru
Start-Sleep -Seconds 3
$stratumCheck = Get-Process -Name "stratum" -ErrorAction SilentlyContinue
if ($stratumCheck) {
    Write-Host ("  Stratum running PID " + $stratumProc.Id + ". Dashboard: http://127.0.0.1:$DashboardPort") -ForegroundColor Green
} else {
    Write-Host ("  WARNING: Stratum may not have started. Check: " + $StratumErrLog) -ForegroundColor Red
}

# Save PIDs so -StopPool / -Restart can find the processes later
@($nodeProc.Id, $stratumProc.Id) | Set-Content $PidFile
Write-Host ("PIDs saved to " + $PidFile) -ForegroundColor DarkGray

Write-Host ""
Write-Host "=== Pool is running ===" -ForegroundColor Cyan
Write-Host ("  Stratum (regular):  YOUR-PUBLIC-IP:" + $StratumPort) -ForegroundColor White
Write-Host ("  Stratum (A10/ASIC): YOUR-PUBLIC-IP:" + $A10Port) -ForegroundColor White
Write-Host ("  Dashboard:          http://127.0.0.1:" + $DashboardPort) -ForegroundColor White
Write-Host ("  Node log:           " + $NodeLog) -ForegroundColor DarkGray
Write-Host ("  Stratum log:        " + $StratumLog) -ForegroundColor DarkGray
Write-Host ""
Write-Host ("IMPORTANT: Open ports " + $StratumPort + ", " + $A10Port + ", " + $DashboardPort + ", and 30303 (TCP+UDP) in your firewall.") -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter to exit (node and stratum will keep running in background)"

