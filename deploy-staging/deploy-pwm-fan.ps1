<#
  deploy-pwm-fan.ps1 - SD-card deploy for the pwm_fan PWM speed-control
  rebuild (replaces the on/off-only fan bit on pio_thermal). RUN ELEVATED.

  Moves: fpga.rbf (new pwm_fan peripheral, pio_thermal shrunk to 3-bit),
  odo-miner-pipe (duty-cycle fan control), odo-ui (fan_duty_pct display),
  and /etc/odo-web/index.html (fan_duty_pct on the web dashboard). No DTB
  change this round (J10/Qsys-only rework, no kernel/DTS touched).
  Logs to deploy-pwm-fan.log.

  Assumes the SD card is disk 2 (USB card reader). Pass -Disk <N> if different.
#>
param([int]$Disk = 2, [int]$BootPart = 1, [int]$RootPart = 2)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-pwm-fan.log"
function Log($m){ $m | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-pwm-fan $(Get-Date -Format o) (disk $Disk) ===" | Set-Content $log

$rbf  = Join-Path $here "fpga_pwm_fan.rbf"
$bin  = Join-Path $here "odo-miner-pipe"
$ui   = Join-Path $here "odo-ui"
$html = Join-Path $here "index.html"

try {
    # --- 0. disk online + writable ---------------------------------------
    $d = Get-Disk -Number $Disk
    Log "disk ${Disk}: $($d.FriendlyName)  offline=$($d.IsOffline) ro=$($d.IsReadOnly)"
    if ($d.IsReadOnly) { Set-Disk -Number $Disk -IsReadOnly $false }
    if ($d.IsOffline)  { Set-Disk -Number $Disk -IsOffline  $false; Start-Sleep -Milliseconds 800 }

    # --- 1. FAT boot: drive letter + bitstream ----------------------------
    $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    if (-not $bp.DriveLetter) {
        Set-Partition -DiskNumber $Disk -PartitionNumber $BootPart -NewDriveLetter F
        Start-Sleep -Milliseconds 500
        $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    }
    $DL = $bp.DriveLetter
    Log "boot FAT = ${DL}:"

    if (-not (Test-Path "${DL}:\fpga_prepwm.rbf") -and (Test-Path "${DL}:\fpga.rbf")) {
        Copy-Item "${DL}:\fpga.rbf" "${DL}:\fpga_prepwm.rbf" -Force
        Log "backed up existing fpga.rbf -> fpga_prepwm.rbf"
    }

    Copy-Item $rbf "${DL}:\fpga.rbf" -Force
    $rh = (Get-FileHash "${DL}:\fpga.rbf" -Algorithm MD5).Hash
    $rhSrc = (Get-FileHash $rbf -Algorithm MD5).Hash
    Log "fpga.rbf md5 on card = $rh (expect $rhSrc)"
    if ($rh -ne $rhSrc) { throw "BITSTREAM MD5 MISMATCH" }
    Log "BITSTREAM OK"

    # --- 2. ext4 rootfs via WSL -----------------------------------------
    $phys = "\\.\PHYSICALDRIVE$Disk"
    wsl --unmount $phys 2>$null | Out-Null
    $m = wsl --mount $phys --partition $RootPart 2>&1
    Log "wsl --mount: $m (rc=$LASTEXITCODE)"
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed (rc=$LASTEXITCODE)" }

    $mnt = "/mnt/wsl/PHYSICALDRIVE${Disk}p${RootPart}"
    $wbin  = wsl wslpath -a ($bin  -replace '\\','/')
    $wui   = wsl wslpath -a ($ui   -replace '\\','/')
    $whtml = wsl wslpath -a ($html -replace '\\','/')
    $sh = @"
set -e
m=$mnt
test -d \$m/usr/bin || { echo 'ROOTFS NOT FOUND; mount contents:'; ls -la \$m; exit 2; }
mkdir -p \$m/etc/odo-web
echo '--- current binaries ---'
ls -la \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/etc/odo-web/index.html 2>/dev/null || echo '(some not present yet)'
cp $wbin  \$m/usr/bin/odo-miner-pipe  && chmod 0755 \$m/usr/bin/odo-miner-pipe
cp $wui   \$m/usr/bin/odo-ui          && chmod 0755 \$m/usr/bin/odo-ui
cp $whtml \$m/etc/odo-web/index.html  && chmod 0644 \$m/etc/odo-web/index.html
sync
echo '--- after deploy ---'
ls -la \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/etc/odo-web/index.html
md5sum \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/etc/odo-web/index.html
"@
    $out = wsl -u root bash -c $sh 2>&1
    $rc = $LASTEXITCODE
    $out | Tee-Object -FilePath $log -Append | Out-Host
    if ($rc -ne 0) { throw "rootfs copy failed (rc=$rc)" }
    Log "ROOTFS OK"
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    wsl --unmount "\\.\PHYSICALDRIVE$Disk" 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    Log "=== done - eject the card and return it to the board ==="
}
