param(
  [string]$DataDir = "C:\ETHII\ethii-data",
  [int]$P2pPort = 30303,
  [int]$RpcPort = 8545,
  [string]$BootnodesCsv = "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303,enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) {
  Write-Host "[ETHII relay] $msg" -ForegroundColor Cyan
}

function Assert-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host "[ETHII relay] Elevation required for firewall rule setup. Re-launching as Administrator..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DataDir `"$DataDir`" -P2pPort $P2pPort -RpcPort $RpcPort -BootnodesCsv `"$BootnodesCsv`""
    Start-Process -FilePath "powershell" -ArgumentList $argList -Verb RunAs | Out-Null
    exit 222
  }
}

function Get-BootnodeList {
  param([string]$Csv)

  $nodes = @()
  if (-not [string]::IsNullOrWhiteSpace($Csv)) {
    $nodes = $Csv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  }
  return ($nodes | Select-Object -Unique)
}

function Convert-ToTomlStringLiteral {
  param([string]$Value)

  if ($null -eq $Value) {
    return '""'
  }

  $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
  return '"' + $escaped + '"'
}

function Convert-ToTomlStringArray {
  param([string[]]$Values)

  if ($null -eq $Values -or $Values.Count -eq 0) {
    return "[]"
  }

  $items = $Values | ForEach-Object { Convert-ToTomlStringLiteral -Value $_ }
  return "[" + ($items -join ", ") + "]"
}

function Write-RelayConfigToml {
  param(
    [string]$DataDirPath,
    [string[]]$Nodes,
    [int]$ListenPort,
    [int]$MaxPeers
  )

  $configPath = Join-Path $DataDirPath "config.toml"
  $nodesArray = Convert-ToTomlStringArray -Values $Nodes
  $configText = @"
[Node.P2P]
MaxPeers = $MaxPeers
ListenAddr = ":$ListenPort"
NoDiscovery = false
StaticNodes = $nodesArray
TrustedNodes = $nodesArray
"@

  Set-Content -Path $configPath -Value $configText
  Write-Info "Wrote relay config with static/trusted peers: $configPath"
  return $configPath
}

function Find-NodeBinary {
  $scriptDir = Split-Path -Parent $PSCommandPath
  $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
  $workspaceRoot = Split-Path -Parent $repoRoot
  $bundleRoot = $scriptDir

  $candidates = @(
    (Join-Path $bundleRoot "ethii-windows-amd64.exe"),
    (Join-Path $bundleRoot "ethii.exe"),
    (Join-Path $bundleRoot "ethii-node-windows.exe"),
    (Join-Path $repoRoot "ethii-windows-amd64.exe"),
    (Join-Path $repoRoot "ethii.exe"),
    (Join-Path $repoRoot "ethii-node-windows.exe"),
    (Join-Path $workspaceRoot "ethii-windows-amd64.exe"),
    (Join-Path $workspaceRoot "ethii.exe"),
    (Join-Path $workspaceRoot "ethii-node-windows.exe"),
    (Join-Path $scriptDir "ethii-windows-amd64.exe"),
    (Join-Path $scriptDir "ethii.exe")
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

function Resolve-GenesisPath {
  $scriptDir = Split-Path -Parent $PSCommandPath
  $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
  $candidates = @(
    (Join-Path $scriptDir "genesis.json"),
    (Join-Path $repoRoot "genesis.json")
  )

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

function Set-FirewallRuleState {
  param(
    [string]$Name,
    [string]$Protocol,
    [int]$Port
  )

  $rule = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
  if (-not $rule) {
    New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $Port -Profile Any | Out-Null
    Write-Info "Opened firewall $Protocol port $Port ($Name)."
    return
  }

  $isEnabled = (Get-NetFirewallRule -DisplayName $Name | Select-Object -First 1).Enabled
  if ($isEnabled -ne "True") {
    Set-NetFirewallRule -DisplayName $Name -Enabled True | Out-Null
    Write-Info "Enabled existing firewall rule $Name."
  } else {
    Write-Info "Firewall rule already enabled: $Name."
  }
}

function Stop-DefaultEthereumService {
  try {
    $svc = Get-Service -Name "ethereum" -ErrorAction SilentlyContinue
    if ($svc) {
      if ($svc.Status -ne "Stopped") {
        Write-Info "Stopping conflicting Windows service: ethereum"
        Stop-Service -Name "ethereum" -Force -ErrorAction SilentlyContinue
      }

      # Prevent auto-restart into mainnet defaults on reboot/login.
      sc.exe config ethereum start= demand | Out-Null
      Write-Info "Set Windows service 'ethereum' startup type to manual."
    }
  } catch {
    Write-Info "Could not manage service 'ethereum': $($_.Exception.Message)"
  }
}

function Get-ExistingNodeProcesses {
  $names = @("ethii.exe", "ethii-windows-amd64.exe", "geth.exe")
  Get-CimInstance Win32_Process | Where-Object { $names -contains $_.Name }
}

function Is-ExpectedEthiiRelayProcess {
  param(
    [string]$CommandLine,
    [string]$ExpectedDataDir
  )

  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  $hasNetwork = $CommandLine -match "--networkid\s+20482"
  $hasDataDir = $CommandLine -match [Regex]::Escape($ExpectedDataDir)
  return ($hasNetwork -and $hasDataDir)
}

function Get-LocalChainIdHex {
  param(
    [int]$Port
  )

  try {
    $resp = Invoke-Rpc -Url "http://127.0.0.1:$Port" -Method "eth_chainId" -TimeoutSec 2
    return $resp.result
  } catch {
    return $null
  }
}

function Initialize-ChainData {
  param(
    [string]$NodeBinary,
    [string]$DataDirPath,
    [string]$GenesisPath
  )

  Write-Info "Initializing chain from genesis..."
  # Native command stderr behavior differs across PowerShell editions.
  # Evaluate init success strictly by process exit code, not stderr stream text.
  $prevNativeEap = $null
  $hadNativeEap = $false
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $hadNativeEap = $true
    $prevNativeEap = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }

  $initOutput = & $NodeBinary --datadir $DataDirPath --state.scheme hash init $GenesisPath 2>&1
  $initExit = $LASTEXITCODE
  if ($hadNativeEap) {
    $PSNativeCommandUseErrorActionPreference = $prevNativeEap
  }
  $ErrorActionPreference = $prevEap

  if ($initExit -eq 0) {
    Write-Info "Genesis initialization complete."
    return
  }

  $initText = ($initOutput | Out-String)
  if ($initText -match "incompatible genesis") {
    Write-Info "Detected incompatible existing chain data. Resetting local chain database..."
    $chainRoots = @(
      (Join-Path $DataDirPath "geth\chaindata"),
      (Join-Path $DataDirPath "geth\lightchaindata"),
      (Join-Path $DataDirPath "geth\nodes")
    )
    foreach ($path in $chainRoots) {
      if (Test-Path $path) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($hadNativeEap) {
      $PSNativeCommandUseErrorActionPreference = $false
    }
    $retryOutput = & $NodeBinary --datadir $DataDirPath --state.scheme hash init $GenesisPath 2>&1
    $retryExit = $LASTEXITCODE
    if ($hadNativeEap) {
      $PSNativeCommandUseErrorActionPreference = $prevNativeEap
    }
    $ErrorActionPreference = $prevEap
    if ($retryExit -ne 0) {
      throw "Genesis re-initialization failed after reset. Output: $($retryOutput | Out-String)"
    }
    Write-Info "Genesis initialization complete after chain reset."
    return
  }

  throw "Genesis initialization failed. Output: $initText"
}

function Invoke-Rpc {
  param(
    [string]$Url,
    [string]$Method,
    [object[]]$Params = @(),
    [int]$TimeoutSec = 5
  )

  $body = @{
    jsonrpc = "2.0"
    method  = $Method
    params  = $Params
    id      = 1
  } | ConvertTo-Json -Compress

  Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSec
}

function Hex-To-Int64 {
  param([string]$Hex)
  if ([string]::IsNullOrWhiteSpace($Hex)) { return $null }
  if ($Hex -notmatch "^0x") { return $null }
  return [Convert]::ToInt64($Hex.Substring(2), 16)
}

function Normalize-PeerList {
  param([object]$Peers)
  if ($null -eq $Peers) { return @() }
  if ($Peers -is [System.Array]) { return $Peers }
  return @($Peers)
}

function Try-BootstrapSync {
  param(
    [string]$RpcUrl,
    [string[]]$PeerEnodes
  )

  $ready = $false
  for ($i = 0; $i -lt 20; $i++) {
    try {
      $null = Invoke-Rpc -Url $RpcUrl -Method "web3_clientVersion" -TimeoutSec 2
      $ready = $true
      break
    } catch {
      Start-Sleep -Milliseconds 750
    }
  }

  if (-not $ready) {
    Write-Info "RPC did not become ready in time; skipping sync bootstrap."
    return
  }

  foreach ($peer in ($PeerEnodes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    try {
      $addPeer = Invoke-Rpc -Url $RpcUrl -Method "admin_addPeer" -Params @($peer)
      $addTrusted = Invoke-Rpc -Url $RpcUrl -Method "admin_addTrustedPeer" -Params @($peer)
      Write-Info "Peer bootstrap for $peer : addPeer=$($addPeer.result) addTrustedPeer=$($addTrusted.result)"
    } catch {
      Write-Info "Peer bootstrap call failed for $peer : $($_.Exception.Message)"
    }
  }

  # Get target block hash from the remote RPC — more reliable than waiting for
  # admin_peers to populate latestBlockHash after a fresh peer connection.
  $remoteRpc = "https://www.ethii.net/rpc"
  $targetHash = $null
  $targetBlock = $null

  try {
    $remoteHead = Invoke-Rpc -Url $remoteRpc -Method "eth_getBlockByNumber" -Params @("latest", $false) -TimeoutSec 10
    if ($remoteHead.result) {
      $targetHash  = $remoteHead.result.hash
      $targetBlock = Hex-To-Int64 $remoteHead.result.number
      Write-Info "Remote chain head: block=$targetBlock hash=$targetHash"
    }
  } catch {
    Write-Info "Could not fetch remote head for debug_sync seed: $($_.Exception.Message)"
  }

  try {
    $localBlock = 0

    # Wait up to 90 s for the node to either sync on its own or for us to trigger debug_sync.
    for ($j = 0; $j -lt 90; $j++) {
      $blockResp = Invoke-Rpc -Url $RpcUrl -Method "eth_blockNumber"
      $localBlock = Hex-To-Int64 $blockResp.result
      if ($localBlock -gt 0) { break }
      Start-Sleep -Seconds 1
    }

    if (($localBlock -eq 0) -and $targetHash -and ($targetBlock -gt 0)) {
      Write-Info "Detected genesis stall (local=0, remote=$targetBlock). Triggering debug_sync..."
      $null = Invoke-Rpc -Url $RpcUrl -Method "debug_sync" -Params @($targetHash) -TimeoutSec 15
      Write-Info "debug_sync accepted for target hash $targetHash"
    } else {
      Write-Info "Sync bootstrap check: local=$localBlock remote=$targetBlock. No debug_sync needed."
    }
  } catch {
    Write-Info "Sync bootstrap check skipped: $($_.Exception.Message)"
  }
}

Assert-Admin
Stop-DefaultEthereumService

$nodeBinary = Find-NodeBinary
if (-not $nodeBinary) {
  throw "Node binary not found. Place ethii-windows-amd64.exe (or ethii.exe) in the repo root or deploy\\windows folder."
}

$genesisPath = Resolve-GenesisPath
if (-not $genesisPath) {
  $scriptDir = Split-Path -Parent $PSCommandPath
  throw "genesis.json not found next to setup-relay-node.ps1 or in repo root above deploy\\windows. Script dir: $scriptDir"
}

Write-Info "Using node binary: $nodeBinary"
Write-Info "Using genesis: $genesisPath"
Write-Info "Using datadir: $DataDir"

$BootnodeEnodes = Get-BootnodeList -Csv $BootnodesCsv
if ($BootnodeEnodes.Count -eq 0) {
  throw "No bootnodes configured. Provide -BootnodesCsv with at least one enode URI."
}
$BootnodesCsv = ($BootnodeEnodes -join ",")
Write-Info "Using bootnodes: $BootnodesCsv"

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$relayConfigPath = Write-RelayConfigToml -DataDirPath $DataDir -Nodes $BootnodeEnodes -ListenPort $P2pPort -MaxPeers 50

Set-FirewallRuleState -Name "ETHII Relay P2P TCP 30303" -Protocol TCP -Port $P2pPort
Set-FirewallRuleState -Name "ETHII Relay P2P UDP 30303" -Protocol UDP -Port $P2pPort

# Always run genesis init. If chaindata exists with the correct ETHII genesis it will succeed
# silently. If chaindata exists with the wrong genesis (e.g. mainnet), Initialize-ChainData
# detects the "incompatible genesis" error, wipes the stale chaindata, and re-initializes.
Initialize-ChainData -NodeBinary $nodeBinary -DataDirPath $DataDir -GenesisPath $genesisPath

$nodeArgs = @(
  "--config", $relayConfigPath,
  "--datadir", $DataDir,
  "--networkid", "20482",
  "--syncmode", "full",
  "--snapshot=false",
  "--gcmode", "archive",
  "--state.scheme", "hash",
  "--http",
  "--http.addr", "127.0.0.1",
  "--http.port", "$RpcPort",
  "--http.corsdomain", "*",
  "--http.vhosts", "*",
  "--http.api", "eth,net,web3,admin,debug",
  "--port", "$P2pPort",
  "--maxpeers", "50",
  "--bootnodes", $BootnodesCsv
)

$existingNodes = Get-ExistingNodeProcesses
if ($existingNodes) {
  $matching = @()
  $conflicting = @()

  foreach ($proc in $existingNodes) {
    if (Is-ExpectedEthiiRelayProcess -CommandLine $proc.CommandLine -ExpectedDataDir $DataDir) {
      $matching += $proc
    } else {
      $conflicting += $proc
    }
  }

  if ($matching.Count -gt 0) {
    $chainHex = Get-LocalChainIdHex -Port $RpcPort
    if ($chainHex -eq "0x5002") {
      Write-Info "Detected running ETHII relay on chainId 20482. Restarting to ensure a clean launch."
      $conflicting += $matching
      $matching = @()
    } else {
      Write-Info "Detected running node on wrong or unknown chain (chainId=$chainHex). It will be replaced."
      $conflicting += $matching
      $matching = @()
    }
  }

  if ($conflicting.Count -gt 0) {
    Write-Info "Stopping conflicting node process(es) before starting ETHII relay..."
    foreach ($proc in $conflicting) {
      Write-Info "Stopping PID $($proc.ProcessId) [$($proc.Name)]"
      try {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
      } catch {
        Write-Info "Could not stop PID $($proc.ProcessId): $($_.Exception.Message)"
      }
    }
    Start-Sleep -Seconds 1
  }
}

Write-Info "Starting non-mining relay node..."
Start-Process -FilePath $nodeBinary -ArgumentList $nodeArgs -WindowStyle Normal | Out-Null
Write-Info "Relay node launched."
Try-BootstrapSync -RpcUrl "http://127.0.0.1:$RpcPort" -PeerEnodes $BootnodeEnodes
Write-Info "This profile does not enable CPU mining."
Write-Info "To verify: call miner_hashrate on http://127.0.0.1:$RpcPort"
