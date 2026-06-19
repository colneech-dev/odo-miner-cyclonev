<#
  deploy-usbip.ps1 - ext4 rootfs deploy via usbipd (for removable SD readers that
  wsl --mount rejects with 0x8007000f). RUN ELEVATED.

  Attaches the USB card reader into WSL2, mounts the ext4 rootfs (LABEL=rootfs),
  and deploys:
    - odo-miner-pipe          (latest build, from deploy-staging)
    - S90odod                 (auto-detect init, from linux/overlay)
    - S50sshd + sshd_config + /root/.ssh/authorized_keys  (enable remote SSH)
  Reports the current on-card state and whether /usr/sbin/sshd is present, then
  unmounts and returns the reader to Windows. Logs to deploy-usbip.log.
  The FAT bitstream is handled separately by deploy-full.ps1.
#>
param([string]$BusId)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$log  = Join-Path $here "deploy-usbip.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-usbip $(Get-Date -Format o) ===" | Set-Content $log

# Source files (host paths).
$src = @{
    bin      = (Join-Path $here "odo-miner-pipe")
    odod     = (Join-Path $repo "linux\overlay\etc\init.d\S90odod")
    sshd     = (Join-Path $repo "linux\overlay\etc\init.d\S50sshd")
    sshdcfg  = (Join-Path $repo "linux\overlay\etc\ssh\sshd_config")
    authkeys = (Join-Path $repo "linux\overlay\root\.ssh\authorized_keys")
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
echo '--- current state ---'
ls -la "$m"/usr/bin/odo-miner* 2>/dev/null || echo '(no odo binaries)'
if [ -x "$m/usr/sbin/sshd" ]; then
  echo "sshd present: $(ls -la "$m/usr/sbin/sshd")"
else
  echo "WARNING: $m/usr/sbin/sshd NOT present -> openssh not in this rootfs;"
  echo "         SSH needs a full Buildroot rebuild + reflash, not just this overlay."
fi
ls -la "$m/etc/init.d/" | grep -E 'sshd|S50' || echo '(no existing sshd init)'
echo '--- deploying ---'
cp __BIN__      "$m/usr/bin/odo-miner-pipe"     && chmod 0755 "$m/usr/bin/odo-miner-pipe"     || { echo FAIL bin;  umount "$m"; exit 6; }
cp __ODOD__     "$m/etc/init.d/S90odod"         && chmod 0755 "$m/etc/init.d/S90odod"         || { echo FAIL odod; umount "$m"; exit 7; }
cp __SSHD__     "$m/etc/init.d/S50sshd"         && chmod 0755 "$m/etc/init.d/S50sshd"         || { echo FAIL sshd; umount "$m"; exit 8; }
mkdir -p "$m/etc/ssh" "$m/root/.ssh"
cp __SSHDCFG__  "$m/etc/ssh/sshd_config"        && chmod 0644 "$m/etc/ssh/sshd_config"        || { echo FAIL cfg;  umount "$m"; exit 9; }
cp __AUTHKEYS__ "$m/root/.ssh/authorized_keys"  && chmod 0600 "$m/root/.ssh/authorized_keys"  || { echo FAIL keys; umount "$m"; exit 10; }
chown -R root:root "$m/root/.ssh"; chmod 700 "$m/root" "$m/root/.ssh"
sync
echo '--- after deploy ---'
ls -la "$m/usr/bin/odo-miner-pipe" "$m/etc/init.d/S90odod" "$m/etc/init.d/S50sshd" "$m/etc/ssh/sshd_config" "$m/root/.ssh/authorized_keys"
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
    $sh = $sh.Replace('__BIN__',      (wsl wslpath -a ($src.bin      -replace '\\','/')).Trim())
    $sh = $sh.Replace('__ODOD__',     (wsl wslpath -a ($src.odod     -replace '\\','/')).Trim())
    $sh = $sh.Replace('__SSHD__',     (wsl wslpath -a ($src.sshd     -replace '\\','/')).Trim())
    $sh = $sh.Replace('__SSHDCFG__',  (wsl wslpath -a ($src.sshdcfg  -replace '\\','/')).Trim())
    $sh = $sh.Replace('__AUTHKEYS__', (wsl wslpath -a ($src.authkeys -replace '\\','/')).Trim())
    $sh = $sh -replace "`r", ""

    $shFile = Join-Path $here "_rootfs.sh"
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
