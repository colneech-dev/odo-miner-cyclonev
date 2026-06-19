<#
  deploy-to-sd.ps1 — push the corrected-epoch pipelined build to the board's SD card.

  Deploys:
    1. fpga_pipe_1781827200.rbf -> FAT boot partition as fpga.rbf  (fixes share rejections)
       (keeps the old one as fpga_prev.rbf for rollback)
    2. odo-miner-pipe           -> ext4 rootfs /usr/bin/odo-miner-pipe (chmod +x)
    3. S90odod                  -> ext4 rootfs /etc/init.d/S90odod  (auto-detect init)

  Usage (run in an ELEVATED PowerShell, board powered off, SD card in the PC):
    1. Find the SD card's disk number and the boot drive letter:
         Get-Disk | ft Number,FriendlyName,Size
         Get-Volume | ft DriveLetter,FileSystemLabel,FileSystem,Size
    2. .\deploy-to-sd.ps1 -BootDrive F -SdDiskNumber <N>

  -BootDrive    : drive letter Windows assigned to the FAT boot partition (e.g. F)
  -SdDiskNumber : physical disk number of the SD card (from Get-Disk) — used to
                  wsl --mount the ext4 rootfs partition.
  -RootfsPartition : ext4 partition number on the card (default 2).
#>
param(
    [Parameter(Mandatory=$true)][string]$BootDrive,
    [Parameter(Mandatory=$true)][int]$SdDiskNumber,
    [int]$RootfsPartition = 2
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rbf  = Join-Path $here "fpga_pipe_1781827200.rbf"
$bin  = Join-Path $here "odo-miner-pipe"
$init = Join-Path $here "S90odod"

foreach ($f in @($rbf,$bin,$init)) {
    if (-not (Test-Path $f)) { throw "missing staged artifact: $f" }
}

# --- 1. FAT boot partition: bitstream -------------------------------------
$bootRoot = "${BootDrive}:\"
if (-not (Test-Path $bootRoot)) { throw "boot drive ${BootDrive}: not found — is the card inserted?" }
Write-Host "[1/3] Boot FAT ($bootRoot): backing up current fpga.rbf -> fpga_prev.rbf"
if (Test-Path "$bootRoot\fpga.rbf") { Copy-Item "$bootRoot\fpga.rbf" "$bootRoot\fpga_prev.rbf" -Force }
Copy-Item $rbf "$bootRoot\fpga.rbf" -Force
$srcHash = (Get-FileHash $rbf -Algorithm MD5).Hash
$dstHash = (Get-FileHash "$bootRoot\fpga.rbf" -Algorithm MD5).Hash
if ($srcHash -ne $dstHash) { throw "fpga.rbf copy verify MISMATCH ($srcHash != $dstHash)" }
Write-Host "      fpga.rbf written + verified (md5 $dstHash)"

# --- 2+3. ext4 rootfs via WSL mount ---------------------------------------
$phys = "\\.\PHYSICALDRIVE$SdDiskNumber"
Write-Host "[2/3] Mounting ext4 rootfs: wsl --mount $phys --partition $RootfsPartition"
wsl --unmount $phys 2>$null | Out-Null
wsl --mount $phys --partition $RootfsPartition
if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed (run elevated? correct disk number?)" }

# WSL mounts under /mnt/wsl/PHYSICALDRIVE<N>p<P>
$mnt = "/mnt/wsl/PHYSICALDRIVE${SdDiskNumber}p${RootfsPartition}"
$winBin  = (wsl wslpath -a ($bin  -replace '\\','/'))
$winInit = (wsl wslpath -a ($init -replace '\\','/'))

$script = @"
set -e
test -d $mnt/usr/bin || { echo 'rootfs not at expected mount; ls:'; ls $mnt; exit 1; }
cp $winBin  $mnt/usr/bin/odo-miner-pipe && chmod 0755 $mnt/usr/bin/odo-miner-pipe
cp $winInit $mnt/etc/init.d/S90odod   && chmod 0755 $mnt/etc/init.d/S90odod
sync
echo 'rootfs deploy OK:'
ls -la $mnt/usr/bin/odo-miner-pipe $mnt/etc/init.d/S90odod
md5sum $mnt/usr/bin/odo-miner-pipe $mnt/etc/init.d/S90odod
"@
Write-Host "[3/3] Writing rootfs files..."
wsl sudo bash -c $script
$rc = $LASTEXITCODE
wsl --unmount $phys
if ($rc -ne 0) { throw "rootfs deploy failed (rc=$rc)" }

Write-Host ""
Write-Host "DONE. Eject the card, return it to the board, power on."
Write-Host "Rollback: copy fpga_prev.rbf -> fpga.rbf on the boot partition."
