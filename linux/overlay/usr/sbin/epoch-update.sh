#!/bin/sh
# epoch-update.sh - self-apply a staged next-epoch bitstream at the epoch
# boundary (Phase 2 v1: reboot-reconfigure, see docs/pipelined-miner-scope.md
# WS3 v1). Runtime FPGA-manager reconfig is blocked on this kernel (no
# fpga_bridge sysfs), so "stage on the FAT boot partition, reboot at the
# boundary" is the reconfig mechanism.
#
# The build host (the off-board compile machine) is responsible for placing
# the NEXT epoch's bitstream at /boot/fpga_next.rbf (scp), named however it
# likes locally -- this script only cares about that fixed filename. This
# script does NOT build bitstreams; it only swaps + reboots once the
# currently-running miner reports its epoch is within REBOOT_MARGIN_S of
# epoch_next AND a staged fpga_next.rbf is present.
#
# Run via cron (see /etc/cron/crontabs/root), e.g. every 5 minutes:
#   */5 * * * * /usr/sbin/epoch-update.sh >>/var/log/epoch-update.log 2>&1

STATUS_FILE="${ODOD_STATUS_FILE:-/run/odod/status.json}"
BOOT_DEV=/dev/mmcblk0p1
BOOT_MNT=/mnt/boot
STAGED=fpga_next.rbf
REBOOT_MARGIN_S=60   # apply once we're within this many seconds of epoch_next

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[ -f "$STATUS_FILE" ] || { log "no status file ($STATUS_FILE); nothing to do"; exit 0; }

epoch_next=$(grep -o '"epoch_next": *[0-9]*' "$STATUS_FILE" | grep -o '[0-9]*$')
now=$(date +%s)

if [ -z "$epoch_next" ] || [ "$epoch_next" = "0" ]; then
    exit 0   # daemon hasn't reported a next-epoch time yet
fi

remaining=$((epoch_next - now))
if [ "$remaining" -gt "$REBOOT_MARGIN_S" ]; then
    exit 0   # not yet time
fi

mkdir -p "$BOOT_MNT"
mount -t vfat "$BOOT_DEV" "$BOOT_MNT" 2>/dev/null || { log "mount $BOOT_DEV failed"; exit 1; }

if [ ! -f "$BOOT_MNT/$STAGED" ]; then
    log "epoch boundary reached (remaining=${remaining}s) but no $STAGED staged; staying on current bitstream (shares will reject until the next build lands)"
    umount "$BOOT_MNT"
    exit 0
fi

log "epoch boundary reached (remaining=${remaining}s); applying staged $STAGED"
cp "$BOOT_MNT/fpga.rbf" "$BOOT_MNT/fpga_prev.rbf"
mv "$BOOT_MNT/$STAGED" "$BOOT_MNT/fpga.rbf"
sync
umount "$BOOT_MNT"
log "swapped in $STAGED as fpga.rbf; rebooting"
sync
reboot
