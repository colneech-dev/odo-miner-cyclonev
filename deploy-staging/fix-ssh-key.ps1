<#
  fix-ssh-key.ps1 — append your public key (default ~/.ssh/id_ed25519.pub, or
  pass -PubKey) to the board's root authorized_keys via usbipd (rootfs
  partition), without removing any existing key. RUN ELEVATED.

  Use this when sshd is key-only (PasswordAuthentication no in
  linux/overlay/etc/ssh/sshd_config) and the rootfs you flashed doesn't yet
  trust your key — e.g. after a fresh build where linux/overlay/root/.ssh/
  authorized_keys is the empty template. Mounts the SD card's rootfs over USB
  and appends your key so SSH works without a serial-console round trip.
#>
param([string]$BusId, [string]$PubKey = "$env:USERPROFILE\.ssh\id_ed25519.pub")

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "fix-ssh-key.log"
function Log($m){ ($m | Out-String).TrimEnd() | Tee-Object -FilePath $log -Append | Out-Host }
"=== fix-ssh-key $(Get-Date -Format o) ===" | Set-Content $log

if (-not (Test-Path $PubKey)) { throw "public key not found: $PubKey" }
$keyLine = (Get-Content $PubKey -Raw).Trim()
Log "key to add: $keyLine"

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

ak="$m/root/.ssh/authorized_keys"
echo '--- before ---'
cat "$ak" 2>/dev/null || echo '(no authorized_keys)'

KEY='__KEY__'
if ! grep -qF "$KEY" "$ak" 2>/dev/null; then
  mkdir -p "$m/root/.ssh"
  echo "$KEY" >> "$ak"
  chmod 0600 "$ak"
  chown root:root "$ak"
  echo 'key appended'
else
  echo 'key already present, no change'
fi

echo '--- after ---'
cat "$ak"
sync
umount "$m"; sync
echo 'SSH KEY FIX OK'
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

    $sh = $bashTemplate.Replace('__KEY__', $keyLine)
    $sh = $sh -replace "`r", ""

    $shFile = Join-Path $here "_fix_ssh_key.sh"
    [System.IO.File]::WriteAllText($shFile, $sh, (New-Object System.Text.UTF8Encoding($false)))
    $wsh = (wsl wslpath -a ($shFile -replace '\\','/')).Trim()
    $out = wsl -u root bash $wsh 2>&1
    $rc = $LASTEXITCODE
    Log $out
    if ($rc -ne 0) { throw "ssh key fix failed (rc=$rc)" }
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    if ($BusId) { usbipd detach --busid $BusId 2>&1 | ForEach-Object { Log $_ } }
    Log "=== done ==="
}
