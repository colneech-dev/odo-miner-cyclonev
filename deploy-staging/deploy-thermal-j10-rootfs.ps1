<#
  deploy-thermal-j10-rootfs.ps1 - ext4 rootfs leg of the J10 thermal deploy,
  via usbipd (this card reader rejects wsl --mount with 0x8007000f -- see
  deploy-thermal-j10.ps1's failed run and deploy-usbip.ps1 for precedent).
  RUN ELEVATED.

  Deploys ONLY odo-miner-pipe (thermal.c rewritten for J10 fabric PIO).
  The FAT-partition leg (fpga.rbf + dtb) already completed successfully via
  deploy-thermal-j10.ps1 -- this script just finishes the rootfs half.
  Logs to deploy-thermal-j10-rootfs.log.
#>
param([string]$BusId)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-thermal-j10-rootfs.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-thermal-j10-rootfs $(Get-Date -Format o) ===" | Set-Content $log

$bin = Join-Path $here "odo-miner-pipe"
if (-not (Test-Path $bin)) { throw "missing source: $bin" }

$bashTemplate = @'
echo '--- block devices ---'
lsblk -o NAME,SIZE,FSTYPE,LABEL
part=$(blkid -L rootfs 2>/dev/null)
if [ -z "$part" ]; then echo 'FAIL: no partition with LABEL=rootfs found'; exit 3; fi
echo "rootfs partition = [$part]"
m=/mnt/odoroot
umount "$m" 2>/dev/null; umount "$part" 2>/dev/null
mkdir -p "$m"
if ! mount "$part" "$m"; then echo "FAIL: mount $part -> $m failed"; exit 5; fi
echo "mounted $part on $m"
if [ ! -f "$m/etc/init.d/S90odod" ] || [ ! -d "$m/usr/bin" ]; then
  echo "SAFETY ABORT: $part does not look like the odo board rootfs"; ls -la "$m" | head; umount "$m"; exit 4
fi
echo '--- current binary ---'
ls -la "$m/usr/bin/odo-miner-pipe" 2>/dev/null || echo '(none)'
echo '--- deploying ---'
cp __BIN__ "$m/usr/bin/odo-miner-pipe" && chmod 0755 "$m/usr/bin/odo-miner-pipe" || { echo FAIL bin; umount "$m"; exit 6; }
sync
echo '--- after deploy ---'
ls -la "$m/usr/bin/odo-miner-pipe"
md5sum "$m/usr/bin/odo-miner-pipe"
umount "$m"; sync
echo 'ROOTFS OK'
'@

try {
    Log "--- usbipd list ---"
    $list = usbipd list 2>&1
    Log $list
    if (-not $BusId) {
        $line = ($list | Select-String -Pattern 'Card Reader|SD ?Reader|Storage Device' | Select-Object -First 1)
        if ($line) { $BusId = ($line.ToString().Trim() -split '\s+')[0] }
    }
    if (-not $BusId) { throw "could not auto-detect card reader BUSID; re-run with -BusId X-Y" }
    Log "using BUSID = $BusId"

    usbipd bind   --busid $BusId 2>&1 | ForEach-Object { Log $_ }
    usbipd attach --wsl --busid $BusId 2>&1 | ForEach-Object { Log $_ }
    Start-Sleep -Seconds 3

    $sh = $bashTemplate
    $sh = $sh.Replace('__BIN__', (wsl wslpath -a ($bin -replace '\\','/')).Trim())
    $sh = $sh -replace "`r", ""

    $shFile = Join-Path $here "_rootfs_thermal.sh"
    [System.IO.File]::WriteAllText($shFile, $sh, (New-Object System.Text.UTF8Encoding($false)))
    $wsh = (wsl wslpath -a ($shFile -replace '\\','/')).Trim()
    $out = wsl -u root bash $wsh 2>&1
    $rc = $LASTEXITCODE
    Log $out
    if ($rc -ne 0) { throw "rootfs deploy failed (rc=$rc)" }

    $srcMd5 = (Get-FileHash $bin -Algorithm MD5).Hash
    Log "expected md5 (source) = $srcMd5"
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    if ($BusId) { usbipd detach --busid $BusId 2>&1 | ForEach-Object { Log $_ } }
    Log "=== done - eject the card and return it to the board ==="
}
