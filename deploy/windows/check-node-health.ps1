param(
  [string]$RpcUrl = "",
  [string]$RemoteRpcUrl = "https://www.ethii.net/rpc"
)

$ErrorActionPreference = "Stop"

function Invoke-Rpc {
  param(
    [string]$Url,
    [string]$Method,
    [object[]]$Params = @(),
    [int]$TimeoutSec = 8
  )

  $body = @{
    jsonrpc = "2.0"
    method  = $Method
    params  = $Params
    id      = 1
  } | ConvertTo-Json -Compress

  Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSec
}

function Test-RpcUrl {
  param([string]$Url)
  try {
    $resp = Invoke-Rpc -Url $Url -Method "web3_clientVersion" -TimeoutSec 3
    if ($resp.result) { return $true }
  } catch { }
  return $false
}

function Resolve-LocalRpcUrl {
  param([string]$PreferredUrl)

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($PreferredUrl)) {
    $candidates += $PreferredUrl
  }

  foreach ($p in 8545..8555) {
    $candidates += "http://127.0.0.1:$p"
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-RpcUrl -Url $candidate) {
      return $candidate
    }
  }

  return $null
}

function Hex-To-Int64 {
  param([string]$Hex)
  if ([string]::IsNullOrWhiteSpace($Hex)) { return $null }
  [Convert]::ToInt64($Hex, 16)
}

Write-Host "ETHII Node Health Check" -ForegroundColor Cyan

$EffectiveRpcUrl = Resolve-LocalRpcUrl -PreferredUrl $RpcUrl
if (-not $EffectiveRpcUrl) {
  Write-Host "ERROR: Could not reach local node RPC on 127.0.0.1 ports 8545-8555." -ForegroundColor Red

  $nodeProc = Get-Process -Name "ethii","ethii-windows-amd64","geth" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($nodeProc) {
    Write-Host "Detected node process (PID $($nodeProc.Id), Name $($nodeProc.ProcessName)), but RPC is not responding." -ForegroundColor Yellow
    try {
      $listen = Get-NetTCPConnection -State Listen -OwningProcess $nodeProc.Id -ErrorAction Stop |
        Select-Object -ExpandProperty LocalPort -Unique |
        Sort-Object
      if ($listen) {
        Write-Host "Listening TCP ports: $($listen -join ', ')" -ForegroundColor Yellow
      }
    } catch { }

    try {
      $procMeta = Get-CimInstance Win32_Process -Filter "ProcessId = $($nodeProc.Id)" -ErrorAction Stop
      $cmdLine = $procMeta.CommandLine
      if ($cmdLine) {
        if ($cmdLine -match "AppData\\Local\\Ethereum") {
          Write-Host "WARN: Detected default Ethereum datadir in use (AppData\\Local\\Ethereum). This is mainnet path, not ETHII relay." -ForegroundColor Yellow
        }
        if ($cmdLine -notmatch "--networkid\s+20482") {
          Write-Host "WARN: Running node command line does not include --networkid 20482." -ForegroundColor Yellow
        }
      }
    } catch { }
  } else {
    Write-Host "No running ETHII/geth process detected." -ForegroundColor Yellow
  }

  Write-Host ""
  Write-Host "Try this on that PC:" -ForegroundColor Cyan
  Write-Host "1) Run one-click-relay.bat to start the node." -ForegroundColor Cyan
  Write-Host "2) Wait 10-20 seconds." -ForegroundColor Cyan
  Write-Host "3) Re-run this health check script." -ForegroundColor Cyan
  Write-Host ""
  Write-Host "If your RPC is on a custom port, run:" -ForegroundColor Cyan
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\check-node-health.ps1 -RpcUrl http://127.0.0.1:PORT"
  exit 1
}

Write-Host "Local RPC : $EffectiveRpcUrl"
Write-Host "Remote RPC: $RemoteRpcUrl"
Write-Host ""

try {
  $client = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "web3_clientVersion").result
  $chainIdHex = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "eth_chainId").result
  $syncing = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "eth_syncing").result
  $peerHex = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "net_peerCount").result
  $blockHex = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "eth_blockNumber").result
  $hashrateHex = $null
  $hashrateAvailable = $false
  try {
    $hashrateHex = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "miner_hashrate").result
    if (-not [string]::IsNullOrWhiteSpace($hashrateHex)) {
      $hashrateAvailable = $true
    }
  } catch {
    # Relay profiles may not expose miner_hashrate; treat as informational.
  }

  $nodeInfo = (Invoke-Rpc -Url $EffectiveRpcUrl -Method "admin_nodeInfo").result
  $cfg = $nodeInfo.protocols.eth.config

  $chainIdDec = Hex-To-Int64 $chainIdHex
  $peerCount = Hex-To-Int64 $peerHex
  $blockNum = Hex-To-Int64 $blockHex
  $hashrate = Hex-To-Int64 $hashrateHex

  Write-Host "Client               : $client"
  Write-Host "Chain ID             : $chainIdDec ($chainIdHex)"
  Write-Host "Block Height         : $blockNum ($blockHex)"
  Write-Host "Peer Count           : $peerCount ($peerHex)"
  Write-Host "Syncing              : $syncing"
  if ($hashrateAvailable) {
    Write-Host "Local CPU Hashrate   : $hashrate ($hashrateHex)"
  } else {
    Write-Host "Local CPU Hashrate   : unavailable (miner_hashrate not exposed by this node profile)"
  }
  Write-Host "TerminalTotalDiff    : $($cfg.terminalTotalDifficulty)"
  Write-Host "TTD Passed           : $($cfg.terminalTotalDifficultyPassed)"
  Write-Host ""

  if ($chainIdDec -eq 20482) {
    Write-Host "PASS: chainId is 20482." -ForegroundColor Green
  } else {
    Write-Host "WARN: chainId is not 20482." -ForegroundColor Yellow
  }

  if ($peerCount -gt 0) {
    Write-Host "PASS: at least one peer connected." -ForegroundColor Green
  } else {
    Write-Host "WARN: no peers connected yet." -ForegroundColor Yellow
  }

  if ($syncing -eq $false) {
    Write-Host "PASS: node reports fully synced." -ForegroundColor Green
  } else {
    Write-Host "WARN: node still syncing." -ForegroundColor Yellow
  }

  if (-not $hashrateAvailable) {
    Write-Host "PASS: local CPU mining RPC is unavailable in relay profile (expected)." -ForegroundColor Green
  } elseif ($hashrate -eq 0) {
    Write-Host "PASS: local CPU mining is OFF." -ForegroundColor Green
  } else {
    Write-Host "WARN: local mining hashrate is non-zero." -ForegroundColor Yellow
  }

  if ($cfg.terminalTotalDifficulty) {
    Write-Host "WARN: merge/beacon mode flag detected in chain config." -ForegroundColor Yellow
  } else {
    Write-Host "PASS: no merge TTD configured (pure PoW mode)." -ForegroundColor Green
  }

  try {
    $remoteBlockHex = (Invoke-Rpc -Url $RemoteRpcUrl -Method "eth_blockNumber").result
    $remoteBlock = Hex-To-Int64 $remoteBlockHex
    Write-Host ""
    Write-Host "Remote Height        : $remoteBlock ($remoteBlockHex)"
    if ($remoteBlock -ne $null -and $blockNum -ne $null) {
      $delta = $remoteBlock - $blockNum
      Write-Host "Height Delta         : $delta"
      if ([Math]::Abs($delta) -le 5) {
        Write-Host "PASS: local height is close to remote." -ForegroundColor Green
      } else {
        Write-Host "WARN: local height differs from remote by more than 5 blocks." -ForegroundColor Yellow
      }
    }
  } catch {
    Write-Host ""
    Write-Host "WARN: could not query remote RPC: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
catch {
  Write-Host "ERROR: health check failed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}