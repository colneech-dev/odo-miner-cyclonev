<#
  deploy-thermal-j10.ps1 - SD-card deploy for the J10 fabric-PIO fan/thermal
  rebuild (replaces the abandoned J12/HPS-pin approach). RUN ELEVATED.

  Moves: fpga.rbf (new pio_thermal peripheral), board DTB (onewire/spi0-disable
  nodes removed), and odo-miner-pipe (thermal.c rewritten for /dev/mem PIO
  access). zImage is NOT touched -- no kernel functional dependency on this
  round's DTS/config changes. Logs to deploy-thermal-j10.log.

  Assumes the SD card is disk 2 (USB card reader). Pass -Disk <N> if different.
#>
param([int]$Disk = 2, [int]$BootPart = 1, [int]$RootPart = 2)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-thermal-j10.log"
function Log($m){ $m | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-thermal-j10 $(Get-Date -Format o) (disk $Disk) ===" | Set-Content $log

$rbf = Join-Path $here "fpga_thermal_j10.rbf"
$dtb = Join-Path $here "socfpga_cyclone5_qmtech_odo.dtb"
$bin = Join-Path $here "odo-miner-pipe"

try {
    # --- 0. disk online + writable ---------------------------------------
    $d = Get-Disk -Number $Disk
    Log "disk ${Disk}: $($d.FriendlyName)  offline=$($d.IsOffline) ro=$($d.IsReadOnly)"
    if ($d.IsReadOnly) { Set-Disk -Number $Disk -IsReadOnly $false }
    if ($d.IsOffline)  { Set-Disk -Number $Disk -IsOffline  $false; Start-Sleep -Milliseconds 800 }

    # --- 1. FAT boot: drive letter + bitstream + dtb ----------------------
    $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    if (-not $bp.DriveLetter) {
        Set-Partition -DiskNumber $Disk -PartitionNumber $BootPart -NewDriveLetter F
        Start-Sleep -Milliseconds 500
        $bp = Get-Partition -DiskNumber $Disk -PartitionNumber $BootPart
    }
    $DL = $bp.DriveLetter
    Log "boot FAT = ${DL}:"

    if (-not (Test-Path "${DL}:\fpga_prej10.rbf") -and (Test-Path "${DL}:\fpga.rbf")) {
        Copy-Item "${DL}:\fpga.rbf" "${DL}:\fpga_prej10.rbf" -Force
        Log "backed up existing fpga.rbf -> fpga_prej10.rbf"
    }
    if (-not (Test-Path "${DL}:\socfpga_cyclone5_qmtech_odo_prej10.dtb.bak") -and (Test-Path "${DL}:\socfpga_cyclone5_qmtech_odo.dtb")) {
        Copy-Item "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" "${DL}:\socfpga_cyclone5_qmtech_odo_prej10.dtb.bak" -Force
        Log "backed up existing dtb -> socfpga_cyclone5_qmtech_odo_prej10.dtb.bak"
    }

    Copy-Item $rbf "${DL}:\fpga.rbf" -Force
    Copy-Item $dtb "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" -Force
    $rh = (Get-FileHash "${DL}:\fpga.rbf" -Algorithm MD5).Hash
    $dh = (Get-FileHash "${DL}:\socfpga_cyclone5_qmtech_odo.dtb" -Algorithm MD5).Hash
    $rhSrc = (Get-FileHash $rbf -Algorithm MD5).Hash
    $dhSrc = (Get-FileHash $dtb -Algorithm MD5).Hash
    Log "fpga.rbf md5 on card = $rh (expect $rhSrc)"
    Log "dtb      md5 on card = $dh (expect $dhSrc)"
    if ($rh -ne $rhSrc -or $dh -ne $dhSrc) { throw "BITSTREAM/DTB MD5 MISMATCH" }
    Log "BITSTREAM + DTB OK"

    # --- 2. ext4 rootfs via WSL -----------------------------------------
    $phys = "\\.\PHYSICALDRIVE$Disk"
    wsl --unmount $phys 2>$null | Out-Null
    $m = wsl --mount $phys --partition $RootPart 2>&1
    Log "wsl --mount: $m (rc=$LASTEXITCODE)"
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed (rc=$LASTEXITCODE)" }

    $mnt = "/mnt/wsl/PHYSICALDRIVE${Disk}p${RootPart}"
    $wbin = wsl wslpath -a ($bin -replace '\\','/')
    $sh = @"
set -e
m=$mnt
test -d \$m/usr/bin || { echo 'ROOTFS NOT FOUND; mount contents:'; ls -la \$m; exit 2; }
echo '--- current binary ---'
ls -la \$m/usr/bin/odo-miner-pipe 2>/dev/null || echo '(none)'
cp $wbin \$m/usr/bin/odo-miner-pipe && chmod 0755 \$m/usr/bin/odo-miner-pipe
sync
echo '--- after deploy ---'
ls -la \$m/usr/bin/odo-miner-pipe
md5sum \$m/usr/bin/odo-miner-pipe
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
