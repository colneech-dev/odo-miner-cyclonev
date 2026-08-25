<#
  epoch_autorenew.ps1 - unattended wrapper around epoch_build_deploy.ps1.

  Designed to run on a recurring schedule (e.g. daily via Task Scheduler) and
  no-op on every run except the ones where it's actually time to act. Reads
  the board's OWN status.json as the source of truth for what epoch is coming
  next, for whichever pool the board is currently mining (testnet 86400s or
  mainnet 864000s -- this script doesn't need to know which, it just reads
  epoch_next/epoch_interval off the daemon).

  Logic each run:
    0. If status.epoch != status.bitstream_epoch: an ACTIVE MISMATCH is
       already happening -- the board is mining status.epoch right now with
       the wrong bitstream baked in, shares are being rejected on THIS run,
       not some future one. Build status.epoch immediately, ignoring lead
       time entirely. This is not the same case as step 3 below: status.json's
       epoch_next field always means "the epoch after status.epoch", so once
       a boundary is actually missed and passes, epoch_next silently rolls
       forward to the epoch AFTER the broken one -- a lead-time check against
       epoch_next alone would then report "not due yet" for weeks while the
       board sits on a live, un-noticed mismatch. Hit this for real: the Aug
       25 boundary was missed (build crashed both prior attempts -- see the
       epoch_build_deploy.ps1 header), and once it passed, this script kept
       reporting "not due yet" against the NEXT boundary (Sep 4) forever,
       never coming back to fix the one that was actually broken.
    1. Otherwise: SSH to the board, read /run/odod/status.json (already done
       for step 0's check).
    2. Lead time = min($LeadDays, interval/4) -- scales down automatically for
       a short interval (testnet) so the lead time never exceeds the cycle
       itself, while still giving mainnet's 10-day cycle a comfortable
       multi-day buffer for retries.
    3. If epoch_next is further out than the lead time: not due yet, exit
       quietly (this is the common case, most runs do nothing).
    4. If due (step 0 or step 3): check $MarkerDir for a "this target epoch
       already built+staged" marker (written on success) -- skip if present
       (idempotent re-runs, e.g. Task Scheduler firing again before the next
       boundary).
    5. Otherwise: run epoch_build_deploy.ps1 -Epoch <target> (default
       -StageAs fpga_next.rbf -- correct in both cases: either it's the next
       epoch for whichever pool is CURRENTLY live on the board, or it's the
       CURRENT epoch during an active mismatch, and the board's own
       epoch-update.sh loop swaps fpga_next.rbf in as soon as it sees the
       mismatch regardless of which case staged it). On success, write the
       marker. On failure, throw (no marker written, so the next scheduled
       run retries) and append to the failure log.

  Usage:
    .\epoch_autorenew.ps1 -BoardIp <your-board-ip> [-Throughput 6] [-LeadDays 2]
        [-MinMarginNs 0.1] [-MaxSeedAttempts 6]

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
    [double]$LeadDays = 2.0,
    # Forwarded straight to epoch_build_deploy.ps1 -- see its param block for
    # rationale. Exposed here too since this is the unattended entry point,
    # and a hard epoch (needing more than the default 6 seed tries, or a
    # looser/tighter margin bar) shouldn't require editing the script.
    [double]$MinMarginNs = 0.1,
    [int]$MaxSeedAttempts = 6
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
    $currentEpoch   = [long]$status.epoch
    $bitstreamEpoch = [long]$status.bitstream_epoch
    $epochNext      = [long]$status.epoch_next
    $epochInterval  = [long]$status.epoch_interval
    if ($epochNext -eq 0 -or $epochInterval -eq 0) { throw "status.json missing epoch_next/epoch_interval (old daemon build?)" }

    if ($currentEpoch -ne 0 -and $currentEpoch -ne $bitstreamEpoch) {
        # ACTIVE MISMATCH -- see step 0 in the header comment. Build the
        # CURRENT epoch right now, not epoch_next (epoch_next has already
        # rolled past the broken one).
        $targetEpoch = $currentEpoch
        Log "MISMATCH: board is mining epoch $currentEpoch but bitstream is $bitstreamEpoch -- building $targetEpoch NOW, ignoring lead time"
    } else {
        $nowUnix = [long][double]::Parse((Get-Date -UFormat %s -Millisecond 0))
        $remaining = $epochNext - $nowUnix
        $leadSeconds = [Math]::Min($LeadDays * 86400, $epochInterval / 4.0)

        Log "pool=$($status.pool) bitstream_epoch=$bitstreamEpoch epoch_next=$epochNext remaining=$([Math]::Round($remaining/3600,1))h lead=$([Math]::Round($leadSeconds/3600,1))h"

        if ($remaining -gt $leadSeconds) {
            Log "not due yet -- nothing to do"
            exit 0
        }
        $targetEpoch = $epochNext
    }

    $marker = Join-Path $markerDir "staged_$targetEpoch.done"
    if (Test-Path $marker) {
        Log "epoch $targetEpoch already built+staged (marker present) -- nothing to do"
        exit 0
    }

    Log "DUE: building epoch $targetEpoch (T=$Throughput) and staging as fpga_next.rbf"
    & (Join-Path $PSScriptRoot "epoch_build_deploy.ps1") -Epoch $targetEpoch -Throughput $Throughput -BoardIp $BoardIp -SshKey $SshKey -StageAs fpga_next.rbf -MinMarginNs $MinMarginNs -MaxSeedAttempts $MaxSeedAttempts
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw "epoch_build_deploy.ps1 exited with code $LASTEXITCODE" }

    Set-Content -Path $marker -Value "built $(Get-Date -Format o), target epoch was $targetEpoch"
    $applyNote = if ($targetEpoch -eq $currentEpoch) { "immediately (mismatch already active)" } else { "at the boundary" }
    Log "SUCCESS: epoch $targetEpoch staged as fpga_next.rbf; board's epoch-update.sh cron will swap it in $applyNote"
}
catch {
    Log "FAILURE: $($_.Exception.Message)"
    exit 1
}
finally {
    Pop-Location
}
