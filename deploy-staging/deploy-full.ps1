<#
  deploy-full.ps1 - complete SD-card deploy for the corrected-epoch pipelined build.
  RUN ELEVATED (Run as administrator). Handles disk online state, FAT bitstream,
  and ext4 rootfs (binary + init) in one pass. Logs to deploy-full.log.

  Assumes the SD card is disk 2 (USB card reader, ~14.6 GB). If Get-Disk shows a
  different number for the card reader, pass it:  .\deploy-full.ps1 -Disk <N>
#>
param([int]$Disk = 2, [int]$BootPart = 1, [int]$RootPart = 2)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-full.log"
function Log($m){ $m | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-full $(Get-Date -Format o) (disk $Disk) ===" | Set-Content $log

$rbf  = Join-Path $here "fpga_pipe_1781827200.rbf"
$bin  = Join-Path $here "odo-miner-pipe"
$init = Join-Path $here "S90odod"
$expectRbf = "0CFBDA4DE0687BF9DA18DD02B50C315A"

try {
    # --- 0. disk online + writable ---------------------------------------
    $d = Get-Disk -Number $Disk
    Log "disk ${Disk}: $($d.FriendlyName)  offline=$($d.IsOffline) ro=$($d.IsReadOnly)"
    if ($d.IsReadOnly) { Set-Disk -Number $Disk -IsReadOnly $false }
    if ($d.IsOffline)  { Set-Disk -Number $Disk -IsOffline  $false; Start-Sleep -Milliseconds 800 }

    # --- 1. FAT boot: drive letter + bitstream ---------------------------
    $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    if (-not $bp.DriveLetter) {
        Set-Partition -DiskNumber $Disk -PartitionNumber $BootPart -NewDriveLetter F
        Start-Sleep -Milliseconds 500
        $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    }
    $DL = $bp.DriveLetter
    Log "boot FAT = ${DL}:"
    if (-not (Test-Path "${DL}:\fpga_prev.rbf") -and (Test-Path "${DL}:\fpga.rbf")) {
        Copy-Item "${DL}:\fpga.rbf" "${DL}:\fpga_prev.rbf" -Force
        Log "backed up existing fpga.rbf -> fpga_prev.rbf"
    }
    Copy-Item $rbf "${DL}:\fpga.rbf" -Force
    $dh = (Get-FileHash "${DL}:\fpga.rbf" -Algorithm MD5).Hash
    Log "fpga.rbf md5 on card = $dh  (expect $expectRbf)"
    if ($dh -ne $expectRbf) { throw "BITSTREAM MD5 MISMATCH" }
    Log "BITSTREAM OK"

    # --- 2. ext4 rootfs via WSL -----------------------------------------
    $phys = "\\.\PHYSICALDRIVE$Disk"
    wsl --unmount $phys 2>$null | Out-Null
    $m = wsl --mount $phys --partition $RootPart 2>&1
    Log "wsl --mount: $m (rc=$LASTEXITCODE)"
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed (rc=$LASTEXITCODE)" }

    $mnt = "/mnt/wsl/PHYSICALDRIVE${Disk}p${RootPart}"
    $wbin  = wsl wslpath -a ($bin  -replace '\\','/')
    $winit = wsl wslpath -a ($init -replace '\\','/')
    $sh = @"
set -e
m=$mnt
test -d \$m/usr/bin || { echo 'ROOTFS NOT FOUND; mount contents:'; ls -la \$m; exit 2; }
echo '--- current on-card init (what reboot would start) ---'
grep -nE 'DAEMON=|pick_daemon|devmem|odo-miner' \$m/etc/init.d/S90odod 2>/dev/null | head -20 || echo '(no S90odod)'
echo '--- current binaries ---'
ls -la \$m/usr/bin/odo-miner* 2>/dev/null || echo '(none)'
cp $wbin  \$m/usr/bin/odo-miner-pipe && chmod 0755 \$m/usr/bin/odo-miner-pipe
cp $winit \$m/etc/init.d/S90odod   && chmod 0755 \$m/etc/init.d/S90odod
sync
echo '--- after deploy ---'
ls -la \$m/usr/bin/odo-miner-pipe \$m/etc/init.d/S90odod
md5sum \$m/usr/bin/odo-miner-pipe \$m/etc/init.d/S90odod
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
