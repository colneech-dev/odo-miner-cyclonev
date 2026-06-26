#!/bin/sh
# epoch-update.sh - self-apply a staged next-epoch bitstream once the pool's
# job actually moves to a new epoch (Phase 2 v1: reboot-reconfigure, see
# docs/pipelined-miner-scope.md WS3 v1). Runtime FPGA-manager reconfig is
# blocked on this kernel (no fpga_bridge sysfs), so "stage on the FAT boot
# partition, reboot once the trigger fires" is the reconfig mechanism.
#
# Trigger: status.json's "epoch" (the CURRENT JOB's epoch, from the pool's
# mining.notify -> odokey) vs "bitstream_epoch" (what's actually baked into
# the running FPGA, fixed at daemon startup). These are the authoritative
# values -- NOT a wall-clock guess against epoch_next. A wall-clock predictor
# (current_epoch + epoch_interval) looks right but is NOT reliable: OdoCrypt
# epoch = ntime - ntime%interval is computed from the chain's block time, and
# on a low-activity chain (e.g. this testnet) block times lag well behind
# wall-clock, so "epoch_next" can pass with no real epoch change yet -- and
# conversely a chain catching up could jump the epoch early. Comparing
# epoch != bitstream_epoch directly is exact regardless of block cadence.
#
# The build host (the off-board compile machine) is responsible for placing
# the NEXT epoch's bitstream at /boot/fpga_next.rbf (scp) ahead of time, once
# it knows (or guesses) what odokey is coming next -- this script only cares
# about that fixed filename, and only applies it once the pool's job has
# actually moved past the currently-baked epoch.
#
# Run via cron (see /etc/cron/crontabs/root), e.g. every 5 minutes:
#   */5 * * * * /usr/sbin/epoch-update.sh >>/var/log/epoch-update.log 2>&1

STATUS_FILE="${ODOD_STATUS_FILE:-/run/odod/status.json}"
BOOT_DEV=/dev/mmcblk0p1
BOOT_MNT=/mnt/boot
STAGED=fpga_next.rbf

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[ -f "$STATUS_FILE" ] || { log "no status file ($STATUS_FILE); nothing to do"; exit 0; }

job_epoch=$(grep -o '"epoch": *[0-9]*' "$STATUS_FILE" | head -1 | grep -o '[0-9]*$')
bake_epoch=$(grep -o '"bitstream_epoch": *[0-9]*' "$STATUS_FILE" | grep -o '[0-9]*$')

if [ -z "$job_epoch" ] || [ -z "$bake_epoch" ]; then
    exit 0   # daemon hasn't reported these fields yet (old binary, or just starting)
fi

if [ "$job_epoch" = "$bake_epoch" ]; then
    exit 0   # still on the correct epoch; nothing to do
fi

mkdir -p "$BOOT_MNT"
mount -t vfat "$BOOT_DEV" "$BOOT_MNT" 2>/dev/null || { log "mount $BOOT_DEV failed"; exit 1; }

if [ ! -f "$BOOT_MNT/$STAGED" ]; then
    log "ERROR: job epoch ($job_epoch) != baked epoch ($bake_epoch) but no $STAGED staged; shares will reject until the build host stages the next bitstream"
    umount "$BOOT_MNT"
    exit 1
fi

log "job epoch ($job_epoch) != baked epoch ($bake_epoch); applying staged $STAGED"
cp "$BOOT_MNT/fpga.rbf" "$BOOT_MNT/fpga_prev.rbf"
mv "$BOOT_MNT/$STAGED" "$BOOT_MNT/fpga.rbf"
sync
umount "$BOOT_MNT"
log "swapped in $STAGED as fpga.rbf; rebooting"
sync
reboot
