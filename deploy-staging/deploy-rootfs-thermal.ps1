<#
  deploy-rootfs-thermal.ps1 — rootfs half of the fan/thermal deploy, via usbipd
  (wsl --mount rejects this card reader with 0x8007000f, and deploy-usbip.ps1's
  last run deployed a STALE odo-miner-pipe — likely WSL DrvFs cache staleness
  right after the Windows-side file was overwritten). RUN ELEVATED.

  This version hashes each source file FROM INSIDE WSL right before copying and
  aborts if it doesn't match the Windows-computed hash, then re-reads the
  on-card hash after copy to confirm. Deploys odo-miner-pipe + odo-ui + odo-webd
  (the kernel/DTB were already deployed via deploy-fan-thermal.ps1's FAT step).
#>
param([string]$BusId)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-rootfs-thermal.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-rootfs-thermal $(Get-Date -Format o) ===" | Set-Content $log

$files = @{
    "odo-miner-pipe" = Join-Path $here "odo-miner-pipe"
    "odo-ui"         = Join-Path $here "odo-ui"
    "odo-webd"       = Join-Path $here "odo-webd"
}
$expect = @{}
foreach ($k in $files.Keys) {
    if (-not (Test-Path $files[$k])) { throw "missing source: $($files[$k])" }
    $expect[$k] = (Get-FileHash $files[$k] -Algorithm MD5).Hash.ToLower()
    Log "expect $k = $($expect[$k])"
}

$bashTemplate = @'
set -e
echo '--- block devices ---'
lsblk -o NAME,SIZE,FSTYPE,LABEL
part=$(blkid -L rootfs 2>/dev/null)
if [ -z "$part" ]; then echo 'FAIL: no partition with LABEL=rootfs found'; exit 3; fi
echo "rootfs partition = [$part]"
m=/mnt/odoroot
umount "$m" 2>/dev/null || true
umount "$part" 2>/dev/null || true
mkdir -p "$m"
if ! mount "$part" "$m"; then echo "FAIL: mount $part -> $m failed"; exit 5; fi
echo "mounted $part on $m"
if [ ! -f "$m/etc/init.d/S90odod" ] || [ ! -d "$m/usr/bin" ]; then
  echo "SAFETY ABORT: $part does not look like the odo board rootfs"; ls -la "$m" | head; umount "$m"; exit 4
fi

echo '--- verifying source hashes as seen from WSL (catches DrvFs staleness) ---'
SRC_BIN="__SRC_BIN__"
SRC_UI="__SRC_UI__"
SRC_WEBD="__SRC_WEBD__"
got_bin=$(md5sum "$SRC_BIN"   | awk '{print $1}')
got_ui=$(md5sum "$SRC_UI"     | awk '{print $1}')
got_webd=$(md5sum "$SRC_WEBD" | awk '{print $1}')
echo "odo-miner-pipe: $got_bin  (expect __EXP_BIN__)"
echo "odo-ui:         $got_ui  (expect __EXP_UI__)"
echo "odo-webd:       $got_webd  (expect __EXP_WEBD__)"
if [ "$got_bin" != "__EXP_BIN__" ] || [ "$got_ui" != "__EXP_UI__" ] || [ "$got_webd" != "__EXP_WEBD__" ]; then
  echo "FAIL: source hash mismatch as seen from WSL -- ABORTING, nothing written"
  umount "$m"
  exit 11
fi
echo 'SOURCE HASHES OK'

echo '--- current on-card state ---'
ls -la "$m"/usr/bin/odo-miner-pipe "$m"/usr/bin/odo-ui "$m"/usr/bin/odo-webd 2>/dev/null || echo '(some not present yet)'

echo '--- deploying ---'
cp "$SRC_BIN"  "$m/usr/bin/odo-miner-pipe" && chmod 0755 "$m/usr/bin/odo-miner-pipe"
cp "$SRC_UI"   "$m/usr/bin/odo-ui"         && chmod 0755 "$m/usr/bin/odo-ui"
cp "$SRC_WEBD" "$m/usr/bin/odo-webd"       && chmod 0755 "$m/usr/bin/odo-webd"
sync

echo '--- verifying on-card hashes ---'
out_bin=$(md5sum "$m/usr/bin/odo-miner-pipe" | awk '{print $1}')
out_ui=$(md5sum "$m/usr/bin/odo-ui"          | awk '{print $1}')
out_webd=$(md5sum "$m/usr/bin/odo-webd"      | awk '{print $1}')
echo "odo-miner-pipe: $out_bin"
echo "odo-ui:         $out_ui"
echo "odo-webd:       $out_webd"
if [ "$out_bin" != "__EXP_BIN__" ] || [ "$out_ui" != "__EXP_UI__" ] || [ "$out_webd" != "__EXP_WEBD__" ]; then
  echo "FAIL: on-card hash mismatch after copy"
  umount "$m"
  exit 12
fi
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
    $sh = $sh.Replace('__SRC_BIN__',  (wsl wslpath -a ($files["odo-miner-pipe"] -replace '\\','/')).Trim())
    $sh = $sh.Replace('__SRC_UI__',   (wsl wslpath -a ($files["odo-ui"]         -replace '\\','/')).Trim())
    $sh = $sh.Replace('__SRC_WEBD__', (wsl wslpath -a ($files["odo-webd"]       -replace '\\','/')).Trim())
    $sh = $sh.Replace('__EXP_BIN__',  $expect["odo-miner-pipe"])
    $sh = $sh.Replace('__EXP_UI__',   $expect["odo-ui"])
    $sh = $sh.Replace('__EXP_WEBD__', $expect["odo-webd"])
    $sh = $sh -replace "`r", ""

    $shFile = Join-Path $here "_rootfs_thermal.sh"
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
