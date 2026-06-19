<#
  deploy-rootfs.ps1 — ext4 rootfs half of the SD deploy (must run ELEVATED).
  Mounts SD disk 2 partition 2 via WSL, copies odo-miner-pipe + S90odod, verifies,
  unmounts. Writes a log to rootfs-deploy.log next to this script.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "rootfs-deploy.log"
"=== rootfs deploy $(Get-Date -Format o) ===" | Set-Content $log

$phys = "\\.\PHYSICALDRIVE2"
$disk = 2
$part = 2

try {
    wsl --unmount $phys 2>$null | Out-Null
    $m = wsl --mount $phys --partition $part 2>&1
    "mount: $m (rc=$LASTEXITCODE)" | Add-Content $log
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed" }

    $mnt  = "/mnt/wsl/PHYSICALDRIVE${disk}p${part}"
    $bin  = wsl wslpath -a "C:/Users/builder/Documents/GitHub/odo-miner-cyclonev/deploy-staging/odo-miner-pipe"
    $init = wsl wslpath -a "C:/Users/builder/Documents/GitHub/odo-miner-cyclonev/deploy-staging/S90odod"

    $script = @"
set -e
test -d $mnt/usr/bin || { echo 'ROOTFS NOT FOUND; contents:'; ls -la $mnt; exit 2; }
echo '--- before ---'
ls -la $mnt/usr/bin/odo-miner* $mnt/etc/init.d/S90odod 2>/dev/null || true
cp $bin  $mnt/usr/bin/odo-miner-pipe && chmod 0755 $mnt/usr/bin/odo-miner-pipe
cp $init $mnt/etc/init.d/S90odod   && chmod 0755 $mnt/etc/init.d/S90odod
sync
echo '--- after ---'
ls -la $mnt/usr/bin/odo-miner-pipe $mnt/etc/init.d/S90odod
md5sum $mnt/usr/bin/odo-miner-pipe $mnt/etc/init.d/S90odod
echo '--- which init starts (grep DAEMON) ---'
grep -nE 'DAEMON|pick_daemon|devmem' $mnt/etc/init.d/S90odod | head
"@
    $out = wsl -u root bash -c $script 2>&1
    $rc  = $LASTEXITCODE
    $out | Add-Content $log
    "rootfs rc=$rc" | Add-Content $log
}
catch { "ERROR: $($_.Exception.Message)" | Add-Content $log }
finally {
    wsl --unmount $phys 2>&1 | Add-Content $log
    "=== done ===" | Add-Content $log
}
