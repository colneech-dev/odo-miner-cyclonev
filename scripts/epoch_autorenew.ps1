<#
  epoch_autorenew.ps1 - unattended wrapper around epoch_build_deploy.ps1.

  Designed to run on a recurring schedule (e.g. daily via Task Scheduler) and
  no-op on every run except the ones where it's actually time to act. Reads
  the board's OWN status.json as the source of truth for what epoch is coming
  next, for whichever pool the board is currently mining (testnet 86400s or
  mainnet 864000s -- this script doesn't need to know which, it just reads
  epoch_next/epoch_interval off the daemon).

  Logic each run:
    1. SSH to the board, read /run/odod/status.json.
    2. Lead time = min($LeadDays, interval/4) -- scales down automatically for
       a short interval (testnet) so the lead time never exceeds the cycle
       itself, while still giving mainnet's 10-day cycle a comfortable
       multi-day buffer for retries.
    3. If epoch_next is further out than the lead time: not due yet, exit
       quietly (this is the common case, most runs do nothing).
    4. If due: check $MarkerDir for a "this epoch_next already built+staged"
       marker (written on success) -- skip if present (idempotent re-runs,
       e.g. Task Scheduler firing again before the next boundary).
    5. Otherwise: run epoch_build_deploy.ps1 -Epoch epoch_next (default
       -StageAs fpga_next.rbf -- correct here since epoch_next IS the next
       epoch for whichever pool is CURRENTLY live on the board). On success,
       write the marker. On failure, throw (no marker written, so the next
       scheduled run retries) and append to the failure log.

  Usage:
    .\epoch_autorenew.ps1 -BoardIp <your-board-ip> [-Throughput 6] [-LeadDays 2]

  Exit code 0 on success-or-not-due-yet, non-zero on a real failure (so
  Task Scheduler's history/alerting reflects actual problems, not routine
  no-ops).
#>
param(
    # No default: this is a public repo (CLAUDE.md bans committing real LAN
    # IPs) and the board's address is environment-specific. Always pass it.
    [Parameter(Mandatory=$true)][string]$BoardIp,
    [string]$SshKey = "tools/testnet/odo-miner",
    [int]$Throughput = 6,   # must match QSF VERILOG_MACRO THROUGHPUT
    [double]$LeadDays = 2.0
)

$ErrorActionPreference = "Stop"
# See the matching comment in epoch_build_deploy.ps1 -- PS 7.3+ turns any
# stderr write from a directly-invoked native exe into a terminating error
# under $ErrorActionPreference="Stop", regardless of exit code. This script
# calls epoch_build_deploy.ps1 directly (& ...), so it needs the same guard
# even though its own wsl/ssh calls weren't observed to trigger it.
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$markerDir = Join-Path $repo "scripts\.epoch_autorenew"
$logFile   = Join-Path $markerDir "autorenew.log"
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null

function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Push-Location $repo

    # 1. Mount the SSH key (same pattern as epoch_build_deploy.ps1).
    $wslKeyTmp = "/tmp/epoch_autorenew_key"
    wsl bash -c "cp '$($SshKey -replace '\\','/')' $wslKeyTmp && chmod 600 $wslKeyTmp"
    if ($LASTEXITCODE -ne 0) { throw "failed to stage SSH key into WSL" }

    # Pin the board's host key into a repo-local (gitignored) known_hosts file
    # instead of disabling verification outright — see the matching comment in
    # epoch_build_deploy.ps1. accept-new pins on first contact, then verifies
    # on every run after (unlike StrictHostKeyChecking=no + /dev/null, which
    # accepts a different key every single run and so never actually detects one).
    $knownHostsRel = "scripts/.epoch_autorenew/known_hosts"
    if (-not (Test-Path (Join-Path $repo $knownHostsRel))) {
        New-Item -ItemType File -Path (Join-Path $repo $knownHostsRel) | Out-Null
    }
    $sshOpts = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$knownHostsRel"

    $statusJson = wsl bash -c "ssh -i $wslKeyTmp $sshOpts -o ConnectTimeout=10 root@$BoardIp 'cat /run/odod/status.json' 2>/dev/null"
    if ($LASTEXITCODE -ne 0 -or -not $statusJson) { throw "could not read status.json from the board (board unreachable or daemon not running)" }

    $status = $statusJson | ConvertFrom-Json
    $epochNext     = [long]$status.epoch_next
    $epochInterval = [long]$status.epoch_interval
    $bitstreamEpoch = [long]$status.bitstream_epoch
    if ($epochNext -eq 0 -or $epochInterval -eq 0) { throw "status.json missing epoch_next/epoch_interval (old daemon build?)" }

    $nowUnix = [long][double]::Parse((Get-Date -UFormat %s -Millisecond 0))
    $remaining = $epochNext - $nowUnix
    $leadSeconds = [Math]::Min($LeadDays * 86400, $epochInterval / 4.0)

    Log "pool=$($status.pool) bitstream_epoch=$bitstreamEpoch epoch_next=$epochNext remaining=$([Math]::Round($remaining/3600,1))h lead=$([Math]::Round($leadSeconds/3600,1))h"

    if ($remaining -gt $leadSeconds) {
        Log "not due yet -- nothing to do"
        exit 0
    }

    $marker = Join-Path $markerDir "staged_$epochNext.done"
    if (Test-Path $marker) {
        Log "epoch $epochNext already built+staged (marker present) -- nothing to do"
        exit 0
    }

    Log "DUE: building epoch $epochNext (T=$Throughput) and staging as fpga_next.rbf"
    & (Join-Path $PSScriptRoot "epoch_build_deploy.ps1") -Epoch $epochNext -Throughput $Throughput -BoardIp $BoardIp -SshKey $SshKey -StageAs fpga_next.rbf
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw "epoch_build_deploy.ps1 exited with code $LASTEXITCODE" }

    Set-Content -Path $marker -Value "built $(Get-Date -Format o), epoch_next was $epochNext"
    Log "SUCCESS: epoch $epochNext staged as fpga_next.rbf; board's epoch-update.sh cron will swap it in at the boundary"
}
catch {
    Log "FAILURE: $($_.Exception.Message)"
    exit 1
}
finally {
    Pop-Location
}
