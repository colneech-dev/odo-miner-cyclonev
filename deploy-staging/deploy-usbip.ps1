<#
  deploy-usbip.ps1 - ext4 rootfs deploy via usbipd (for removable SD readers that
  wsl --mount rejects with 0x8007000f). RUN ELEVATED.

  Attaches the USB card reader into WSL2, mounts the ext4 rootfs partition,
  copies odo-miner-pipe + S90odod, unmounts, and returns the reader to Windows.
  Logs to deploy-usbip.log. The FAT bitstream was already deployed by deploy-full.ps1.
#>
param([string]$BusId)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "deploy-usbip.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== deploy-usbip $(Get-Date -Format o) ===" | Set-Content $log

$bin  = Join-Path $here "odo-miner-pipe"
$init = Join-Path $here "S90odod"

# bash payload as a LITERAL here-string (no PowerShell interpolation). The two
# host paths are substituted via placeholders after wslpath conversion.
$bashTemplate = @'
echo '--- block devices ---'
lsblk -o NAME,SIZE,FSTYPE,LABEL
# The SD rootfs is the ext4 partition labelled "rootfs". Resolve it by label so
# we never touch WSL's own internal ext4 disks (sda/sdb/sdc).
part=$(blkid -L rootfs 2>/dev/null)
if [ -z "$part" ]; then echo 'FAIL: no partition with LABEL=rootfs found'; exit 3; fi
echo "candidate rootfs partition = [$part]"
m=/mnt/odoroot
umount "$m" 2>/dev/null
umount "$part" 2>/dev/null
mkdir -p "$m"
if ! mount "$part" "$m"; then echo "FAIL: mount $part -> $m failed"; exit 5; fi
echo "mounted $part on $m"
# Safety: confirm this is the BOARD rootfs, not something else, before writing.
if [ ! -f "$m/etc/init.d/S90odod" ] || [ ! -d "$m/usr/bin" ]; then
  echo "SAFETY ABORT: $part does not look like the odo board rootfs"
  ls -la "$m" 2>/dev/null | head
  umount "$m"; exit 4
fi
echo '--- current on-card init (what reboot would start) ---'
grep -nE 'DAEMON=|pick_daemon|devmem|odo-miner' "$m/etc/init.d/S90odod" 2>/dev/null | head -20 || echo '(no S90odod)'
echo '--- current binaries ---'
ls -la "$m"/usr/bin/odo-miner* 2>/dev/null || echo '(none)'
if ! cp __BIN__  "$m/usr/bin/odo-miner-pipe"; then echo 'FAIL: cp odo-miner-pipe'; umount "$m"; exit 6; fi
chmod 0755 "$m/usr/bin/odo-miner-pipe"
if ! cp __INIT__ "$m/etc/init.d/S90odod"; then echo 'FAIL: cp S90odod'; umount "$m"; exit 7; fi
chmod 0755 "$m/etc/init.d/S90odod"
sync
echo '--- after deploy ---'
ls -la "$m/usr/bin/odo-miner-pipe" "$m/etc/init.d/S90odod"
md5sum "$m/usr/bin/odo-miner-pipe" "$m/etc/init.d/S90odod"
umount "$m"
sync
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
    if (-not $BusId) { throw "could not auto-detect card reader BUSID; re-run with -BusId X-Y (see list above)" }
    Log "using BUSID = $BusId"

    usbipd bind   --busid $BusId 2>&1 | ForEach-Object { Log $_ }
    usbipd attach --wsl --busid $BusId 2>&1 | ForEach-Object { Log $_ }
    Start-Sleep -Seconds 3

    $wbin  = (wsl wslpath -a ($bin  -replace '\\','/')).Trim()
    $winit = (wsl wslpath -a ($init -replace '\\','/')).Trim()
    $sh = $bashTemplate.Replace('__BIN__', $wbin).Replace('__INIT__', $winit)
    $sh = $sh -replace "`r", ""   # LF-only

    # Execute as a FILE (preserves newlines; -c mangles them through wsl.exe).
    $shFile = Join-Path $here "_rootfs.sh"
    [System.IO.File]::WriteAllText($shFile, $sh, (New-Object System.Text.UTF8Encoding($false)))
    $wsh = (wsl wslpath -a ($shFile -replace '\\','/')).Trim()
    $out = wsl -u root bash $wsh 2>&1
    $rc = $LASTEXITCODE
    Log $out
    if ($rc -ne 0) { throw "rootfs copy failed (rc=$rc)" }
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    if ($BusId) { usbipd detach --busid $BusId 2>&1 | ForEach-Object { Log $_ } }
    Log "=== done ==="
}
