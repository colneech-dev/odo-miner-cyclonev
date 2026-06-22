<#
  deploy-fan-thermal.ps1 — SD-card deploy for the fan/thermal feature.
  RUN ELEVATED (Run as administrator). No FPGA bitstream change in this round —
  only the kernel (new CONFIG_W1* + spi0-disabled DTS) and the three HPS/UI
  binaries (odo-miner-pipe, odo-ui, odo-webd) move. Logs to deploy-fan-thermal.log.

  Assumes the SD card is disk 2 (USB card reader). Pass -Disk <N> if different.
#>
param([int]$Disk = 2, [int]$BootPart = 1, [int]$RootPart = 2)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-fan-thermal.log"
function Log($m){ $m | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-fan-thermal $(Get-Date -Format o) (disk $Disk) ===" | Set-Content $log

$zImage = Join-Path $here "zImage"
$dtb    = Join-Path $here "socfpga_cyclone5_qmtech_odo.dtb"
$bin    = Join-Path $here "odo-miner-pipe"
$ui     = Join-Path $here "odo-ui"
$webd   = Join-Path $here "odo-webd"

try {
    # --- 0. disk online + writable ---------------------------------------
    $d = Get-Disk -Number $Disk
    Log "disk ${Disk}: $($d.FriendlyName)  offline=$($d.IsOffline) ro=$($d.IsReadOnly)"
    if ($d.IsReadOnly) { Set-Disk -Number $Disk -IsReadOnly $false }
    if ($d.IsOffline)  { Set-Disk -Number $Disk -IsOffline  $false; Start-Sleep -Milliseconds 800 }

    # --- 1. FAT boot: drive letter + kernel/DTB ---------------------------
    $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    if (-not $bp.DriveLetter) {
        Set-Partition -DiskNumber $Disk -PartitionNumber $BootPart -NewDriveLetter F
        Start-Sleep -Milliseconds 500
        $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    }
    $DL = $bp.DriveLetter
    Log "boot FAT = ${DL}:"

    if (-not (Test-Path "${DL}:\zImage_prefan.bak") -and (Test-Path "${DL}:\zImage")) {
        Copy-Item "${DL}:\zImage" "${DL}:\zImage_prefan.bak" -Force
        Log "backed up existing zImage -> zImage_prefan.bak"
    }
    if (-not (Test-Path "${DL}:\socfpga_cyclone5_qmtech_odo_prefan.dtb.bak") -and (Test-Path "${DL}:\socfpga_cyclone5_qmtech_odo.dtb")) {
        Copy-Item "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" "${DL}:\socfpga_cyclone5_qmtech_odo_prefan.dtb.bak" -Force
        Log "backed up existing dtb -> socfpga_cyclone5_qmtech_odo_prefan.dtb.bak"
    }

    Copy-Item $zImage "${DL}:\zImage" -Force
    Copy-Item $dtb    "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" -Force
    $zh = (Get-FileHash "${DL}:\zImage" -Algorithm MD5).Hash
    $dh = (Get-FileHash "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" -Algorithm MD5).Hash
    $zhSrc = (Get-FileHash $zImage -Algorithm MD5).Hash
    $dhSrc = (Get-FileHash $dtb -Algorithm MD5).Hash
    Log "zImage md5 on card = $zh (expect $zhSrc)"
    Log "dtb    md5 on card = $dh (expect $dhSrc)"
    if ($zh -ne $zhSrc -or $dh -ne $dhSrc) { throw "KERNEL/DTB MD5 MISMATCH" }
    Log "KERNEL+DTB OK"

    # --- 2. ext4 rootfs via WSL -----------------------------------------
    $phys = "\\.\PHYSICALDRIVE$Disk"
    wsl --unmount $phys 2>$null | Out-Null
    $m = wsl --mount $phys --partition $RootPart 2>&1
    Log "wsl --mount: $m (rc=$LASTEXITCODE)"
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed (rc=$LASTEXITCODE)" }

    $mnt = "/mnt/wsl/PHYSICALDRIVE${Disk}p${RootPart}"
    $wbin  = wsl wslpath -a ($bin  -replace '\\','/')
    $wui   = wsl wslpath -a ($ui   -replace '\\','/')
    $wwebd = wsl wslpath -a ($webd -replace '\\','/')
    $sh = @"
set -e
m=$mnt
test -d \$m/usr/bin || { echo 'ROOTFS NOT FOUND; mount contents:'; ls -la \$m; exit 2; }
echo '--- current binaries ---'
ls -la \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/usr/bin/odo-webd 2>/dev/null || echo '(none)'
cp $wbin  \$m/usr/bin/odo-miner-pipe && chmod 0755 \$m/usr/bin/odo-miner-pipe
cp $wui   \$m/usr/bin/odo-ui         && chmod 0755 \$m/usr/bin/odo-ui
cp $wwebd \$m/usr/bin/odo-webd       && chmod 0755 \$m/usr/bin/odo-webd
sync
echo '--- after deploy ---'
ls -la \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/usr/bin/odo-webd
md5sum \$m/usr/bin/odo-miner-pipe \$m/usr/bin/odo-ui \$m/usr/bin/odo-webd
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
