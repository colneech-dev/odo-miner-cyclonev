<#
  epoch_build_deploy.ps1 - build a pipelined-miner bitstream for a given
  OdoCrypt epoch and stage it on the board as /boot/fpga_next.rbf, ready for
  the board's own epoch-update.sh (cron, */5) to swap in + reboot at the
  epoch boundary. See docs/pipelined-miner-scope.md WS2/WS3 and
  linux/overlay/usr/sbin/epoch-update.sh.

  This is the OPERATOR side of epoch auto-renewal: it does the actual
  Quartus compile (manual/operator-triggered for now -- a cron'd compile
  farm is future scope), then hands off to the board's own timer for the
  reboot-at-boundary step.

  Steps (mirrors the manual recipe used to bring up 1781827200):
    1. odo_gen <epoch> <throughput>  -> hdl/src/pipelined/odo_<epoch>.v
    2. point pipelined_miner_hw.tcl's fileset at that file
    3. set ODOKEY in odo_miner.qsf
    4. qsys-generate (epoch RTL is pulled in via the qsys component fileset,
       unlike soc_top.v which Quartus reads directly -- qsys-generate must
       re-run to pick it up)
    5. quartus_sh --flow compile
    6. scp the .rbf to the board as /boot/fpga_next.rbf (does NOT touch the
       live fpga.rbf or reboot -- epoch-update.sh applies it at the boundary)

  Usage:
    .\epoch_build_deploy.ps1 -Epoch 1781913600 -Throughput 6 -BoardIp <your-board-ip>

  Run from anywhere; paths are resolved relative to the repo root. The script
  writes its own log to hdl/quartus/build_epoch_<epoch>.log -- do NOT wrap the
  call in your own `| Tee-Object -FilePath <relative path>`: step 4 does an
  internal Push-Location/Pop-Location into hdl/qsys, and an outer pipeline
  using a RELATIVE log path will fail to resolve once that happens (the
  script's own steps still complete fine; only the external wrapper breaks).
  If you want a copy of the output, use an ABSOLUTE path with Tee-Object.
#>
param(
    [Parameter(Mandatory=$true)][long]$Epoch,
    [int]$Throughput = 6,   # T=6 @ 156.25 MHz is the deployed config; per-epoch Fmax varies, so the Fmax gate (step 5) checks each build against the actual miner clock
    # No default: this is a public repo (CLAUDE.md bans committing real LAN
    # IPs) and the board's address is environment-specific. Always pass it.
    [Parameter(Mandatory=$true)][string]$BoardIp,
    [string]$SshKey = "tools/testnet/odo-miner",
    # Filename to stage the built .rbf as on the board's FAT boot partition.
    # Default "fpga_next.rbf" is the slot epoch-update.sh's cron job watches
    # for the CURRENTLY CONFIGURED pool's auto-renewal -- only use the default
    # when this epoch is the next one for whatever pool the board is presently
    # mining. Building an epoch for a DIFFERENT pool (e.g. a one-off mainnet
    # bitstream while the board mines testnet) must use a different name (e.g.
    # "fpga_mainnet.rbf") so it doesn't get silently auto-applied on the next
    # unrelated epoch rollover.
    [string]$StageAs = "fpga_next.rbf"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    $rtlFile = "hdl/src/pipelined/odo_$Epoch.v"
    $qsysTcl = "hdl/qsys/pipelined_miner_hw.tcl"
    $qsf     = "hdl/quartus/odo_miner.qsf"

    Write-Host "[1/6] odo_gen $Epoch $Throughput odo_ -> $rtlFile"
    # The third arg is a literal module-name PREFIX (odo_gen.cpp: "%spre_mix"
    # etc) -- it must be "odo_" (with the trailing underscore) to match what
    # odo_miner_core.v instantiates (odo_encrypt). Omitting it silently
    # produces un-prefixed modules (encrypt, pre_mix, ...) that compile fine
    # standalone but fail Quartus elaboration with "undefined entity
    # odo_encrypt" when wired into the wrapper -- caught the hard way on the
    # 1781913600 epoch build.
    # Always regenerate: the file may exist from a previous run with a different
    # -Throughput value (a mismatch between the generated odo_<epoch>.v
    # localparam THROUGHPUT and the QSF VERILOG_MACRO THROUGHPUT produces a
    # wrong hash -> 0 shares). Regeneration is <1s so there is no reason to cache it.
    wsl bash -c "cd '$($repo -replace '\\','/' -replace '^C:','/mnt/c')' && third_party/odo-miner/src/verilog/odo_gen $Epoch $Throughput odo_ > $rtlFile"
    if (-not (Test-Path $rtlFile) -or (Get-Item $rtlFile).Length -eq 0) {
        throw "odo_gen produced an empty/missing $rtlFile"
    }
    if (-not (Select-String -Path $rtlFile -Pattern '^module odo_encrypt\(' -Quiet)) {
        throw "$rtlFile has no 'module odo_encrypt(' -- wrong/missing module prefix (delete and re-run to regenerate with odo_gen ... odo_)"
    }
    # Verify the generated file has the right localparam THROUGHPUT
    if (-not (Select-String -Path $rtlFile -Pattern "localparam THROUGHPUT = $Throughput;" -Quiet)) {
        throw "$rtlFile does not contain 'localparam THROUGHPUT = $Throughput;' -- odo_gen may have failed silently"
    }
    # Also copy to Qsys submodules so Quartus picks up the correct file even
    # if qsys-generate (step 4) is skipped or stale. This is the REAL file
    # Quartus reads via the soc_system.qip reference.
    $submodules = "hdl/qsys/soc_system/synthesis/submodules"
    if (Test-Path $submodules) {
        Copy-Item $rtlFile "$submodules/odo_$Epoch.v" -Force
        Write-Host "      copied to $submodules/odo_$Epoch.v"
    }

    Write-Host "[2/6] point $qsysTcl at odo_$Epoch.v"
    # NOTE: the epoch-numbered filename is always odo_<digits>.v — the pattern
    # must require digits only (\d+), not [\d_a-z]+, or it also matches the
    # fixed, non-epoch-specific odo_miner_core.v fileset line (its "miner_core"
    # suffix matches [_a-z]+ too) and clobbers that reference with a duplicate
    # of the epoch file, silently dropping odo_miner_core.v from the fileset.
    (Get-Content $qsysTcl) -replace 'add_fileset_file odo_\d+\.v(\s+)VERILOG PATH \.\./src/pipelined/odo_\d+\.v', "add_fileset_file odo_$Epoch.v`$1VERILOG PATH ../src/pipelined/odo_$Epoch.v" |
        Set-Content $qsysTcl
    if (-not (Select-String -Path $qsysTcl -Pattern "odo_$Epoch\.v" -Quiet)) {
        throw "failed to update $qsysTcl fileset reference"
    }

    Write-Host "[3/6] set ODOKEY=$Epoch in $qsf"
    (Get-Content $qsf) -replace 'VERILOG_MACRO "ODOKEY=\d+"', "VERILOG_MACRO `"ODOKEY=$Epoch`"" |
        Set-Content $qsf
    if (-not (Select-String -Path $qsf -Pattern "ODOKEY=$Epoch" -Quiet)) {
        throw "failed to update $qsf ODOKEY"
    }

    Write-Host "[4/6] qsys-generate (picks up the new epoch RTL fileset)"
    $qsysGen = "C:\altera_lite\25.1std\quartus\sopc_builder\bin\qsys-generate.exe"
    Push-Location hdl/qsys
    & $qsysGen soc_system.qsys --synthesis=VERILOG --output-directory=soc_system "--search-path=$(Get-Location),`$"
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) { throw "qsys-generate failed (rc=$rc)" }

    Write-Host "[5/6] quartus_sh --flow compile (this takes ~25 min)"
    $log = "hdl/quartus/build_epoch_$Epoch.log"
    & "C:\altera_lite\25.1std\quartus\bin64\quartus_sh.exe" --flow compile "hdl/quartus/odo_miner" 2>&1 |
        Tee-Object -FilePath $log
    if (-not (Test-Path "hdl/quartus/output_files/odo_miner.rbf")) {
        throw "compile did not produce odo_miner.rbf -- check $log"
    }
    $rbfTime = (Get-Item "hdl/quartus/output_files/odo_miner.rbf").LastWriteTime
    Write-Host "      built: $rbfTime"

    # Fmax safety check: per-epoch LUT patterns affect routing, so Fmax varies
    # per epoch. A build that meets 0 errors can still have a timing violation
    # (Critical Warning). Parse the STA report and abort if Fmax < miner clock.
    $staRpt = "hdl/quartus/output_files/odo_miner.sta.rpt"
    if (Test-Path $staRpt) {
        $fmaxLine = Select-String -Path $staRpt -Pattern "pll_miner.*PLL_OUTPUT_COUNTER.*divclk" |
            Where-Object { $_ -match "(\d+\.\d+) MHz" } | Select-Object -First 1
        if ($fmaxLine -and $fmaxLine.Line -match "; (\d+\.\d+) MHz") {
            $fmax = [double]$Matches[1]
            # Derive miner clock from soc_top.v defparams. Must match the
            # u_pll_miner-QUALIFIED defparam name, not a bare "clk0_multiply_by"
            # — soc_top.v declares u_pll_fab (55 MHz fabric clock) BEFORE
            # u_pll_miner, so an unqualified pattern silently grabs u_pll_fab's
            # multiplier/divider instead and validates Fmax against the wrong
            # (much lower) target, making this gate never actually catch a
            # miner-clock timing violation.
            $stv = Get-Content "hdl/src/soc_top.v" -Raw
            $mul = if ($stv -match "u_pll_miner\.clk0_multiply_by\s*=\s*(\d+)") { [double]$Matches[1] } else { 3 }
            $div = if ($stv -match "u_pll_miner\.clk0_divide_by\s*=\s*(\d+)") { [double]$Matches[1] } else { 1 }
            $targetMhz = 50.0 * $mul / $div
            Write-Host "      Fmax=$fmax MHz  target=$targetMhz MHz  margin=$([math]::Round($fmax-$targetMhz,2)) MHz"
            if ($fmax -lt $targetMhz) {
                throw "TIMING VIOLATION: Fmax $fmax MHz < target $targetMhz MHz for epoch $Epoch. Lower the miner clock (u_pll_miner clk0_multiply_by/divide_by in soc_top.v) and rebuild."
            }
        }
    }

    Write-Host "[6/6] staging on the board as /boot/$StageAs"
    $rbf = "hdl/quartus/output_files/odo_miner.rbf"
    $md5 = (Get-FileHash $rbf -Algorithm MD5).Hash

    # SSH refuses world/group-readable key files. The repo checkout is on a
    # Windows filesystem (no real POSIX perms), so copy the key into WSL's own
    # filesystem and chmod it there before use -- using $SshKey directly (as
    # exposed through /mnt/c/...) fails with "bad permissions" / publickey
    # denied, and a bare wsl bash -c pipeline does NOT surface that as a
    # script-terminating error by default, so this used to silently print
    # "DONE" while staging nothing. Check exit codes explicitly now too.
    $wslKeyTmp = "/tmp/epoch_deploy_key"
    wsl bash -c "cp '$($SshKey -replace '\\','/')' $wslKeyTmp && chmod 600 $wslKeyTmp"
    if ($LASTEXITCODE -ne 0) { throw "failed to stage SSH key into WSL" }

    # Pin the board's host key into a repo-local (gitignored) known_hosts file
    # instead of disabling verification outright: StrictHostKeyChecking=no +
    # UserKnownHostsFile=/dev/null accepts a DIFFERENT key on every single run,
    # so it can't detect a key that legitimately changed vs. one substituted by
    # a MITM on the LAN path. accept-new + a persistent file pins on first
    # contact and then verifies on every run after. Relative path (like
    # $SshKey above) so `wsl`'s automatic cwd translation resolves it under
    # $repo without needing manual drive-letter handling.
    $knownHostsRel = "scripts/.epoch_autorenew/known_hosts"
    New-Item -ItemType Directory -Force -Path (Join-Path $repo "scripts/.epoch_autorenew") | Out-Null
    $knownHostsWin = Join-Path $repo $knownHostsRel
    if (-not (Test-Path $knownHostsWin)) { New-Item -ItemType File -Path $knownHostsWin | Out-Null }
    $sshOpts = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$knownHostsRel"

    wsl bash -c "scp -i $wslKeyTmp $sshOpts '$($rbf -replace '\\','/')' root@${BoardIp}:/tmp/${StageAs}.staging"
    if ($LASTEXITCODE -ne 0) { throw "scp to board failed (rc=$LASTEXITCODE)" }

    $remoteMd5 = wsl bash -c "ssh -i $wslKeyTmp $sshOpts root@$BoardIp 'mkdir -p /mnt/boot && mount -t vfat /dev/mmcblk0p1 /mnt/boot && mv /tmp/${StageAs}.staging /mnt/boot/$StageAs && sync && md5sum /mnt/boot/$StageAs && umount /mnt/boot'"
    if ($LASTEXITCODE -ne 0) { throw "staging on board failed (rc=$LASTEXITCODE): $remoteMd5" }
    if ($remoteMd5 -notmatch [regex]::Escape($md5.ToLower())) {
        throw "staged file md5 mismatch: local=$md5 remote-report=$remoteMd5"
    }

    Write-Host ""
    Write-Host "DONE. Epoch $Epoch staged as /boot/$StageAs (md5 $md5, verified)."
    if ($StageAs -eq "fpga_next.rbf") {
        Write-Host "The board's epoch-update.sh cron job will swap it in and reboot automatically"
        Write-Host "once the currently-running miner's job epoch diverges from its baked epoch."
    } else {
        Write-Host "Staged under a non-default name -- NOT in the auto-renewal path. Apply manually:"
        Write-Host "  cp /boot/$StageAs /boot/fpga.rbf  (after backing up fpga.rbf) + reboot"
    }
}
finally {
    Pop-Location
}
