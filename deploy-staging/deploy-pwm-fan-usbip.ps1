<#
  deploy-pwm-fan-usbip.ps1 - ext4 rootfs deploy for the pwm_fan rebuild via
  usbipd (this card reader rejects wsl --mount with 0x8007000f -- see
  reference_sdcard_raw_deploy memory). RUN ELEVATED.

  Deploys odo-miner-pipe (duty-cycle fan control), odo-ui (fan_duty_pct
  display), and /etc/odo-web/index.html (fan_duty_pct on the web dashboard)
  to the ext4 rootfs (LABEL=rootfs). The FAT-partition bitstream copy is
  handled separately by deploy-pwm-fan.ps1 (already done).
#>
param([string]$BusId)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-pwm-fan-usbip.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-pwm-fan-usbip $(Get-Date -Format o) ===" | Set-Content $log

$src = @{
    bin  = (Join-Path $here "odo-miner-pipe")
    ui   = (Join-Path $here "odo-ui")
    html = (Join-Path $here "index.html")
}
foreach ($k in $src.Keys) { if (-not (Test-Path $src[$k])) { throw "missing source: $($src[$k])" } }

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
mkdir -p "$m/etc/odo-web"
echo '--- current state ---'
ls -la "$m/usr/bin/odo-miner-pipe" "$m/usr/bin/odo-ui" "$m/etc/odo-web/index.html" 2>/dev/null || echo '(some not present yet)'
echo '--- deploying ---'
cp __BIN__  "$m/usr/bin/odo-miner-pipe"     && chmod 0755 "$m/usr/bin/odo-miner-pipe"     || { echo FAIL bin;  umount "$m"; exit 6; }
cp __UI__   "$m/usr/bin/odo-ui"             && chmod 0755 "$m/usr/bin/odo-ui"             || { echo FAIL ui;   umount "$m"; exit 7; }
cp __HTML__ "$m/etc/odo-web/index.html"     && chmod 0644 "$m/etc/odo-web/index.html"     || { echo FAIL html; umount "$m"; exit 8; }
sync
echo '--- after deploy ---'
ls -la "$m/usr/bin/odo-miner-pipe" "$m/usr/bin/odo-ui" "$m/etc/odo-web/index.html"
md5sum "$m/usr/bin/odo-miner-pipe" "$m/usr/bin/odo-ui" "$m/etc/odo-web/index.html"
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
    $sh = $sh.Replace('__BIN__',  (wsl wslpath -a ($src.bin  -replace '\\','/')).Trim())
    $sh = $sh.Replace('__UI__',   (wsl wslpath -a ($src.ui   -replace '\\','/')).Trim())
    $sh = $sh.Replace('__HTML__', (wsl wslpath -a ($src.html -replace '\\','/')).Trim())
    $sh = $sh -replace "`r", ""

    $shFile = Join-Path $here "_rootfs_pwm.sh"
    [System.IO.File]::WriteAllText($shFile, $sh, (New-Object System.Text.UTF8Encoding($false)))
    $wsh = (wsl wslpath -a ($shFile -replace '\\','/')).Trim()
    $out = wsl -u root bash $wsh 2>&1
    $rc = $LASTEXITCODE
    Log $out
    if ($rc -ne 0) { throw "rootfs deploy failed (rc=$rc)" }
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    if ($BusId) { usbipd detach --busid $BusId 2>&1 | ForEach-Object { Log $_ } }
    Log "=== done ==="
}
