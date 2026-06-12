#!/bin/bash
# Diagnose a built SD image: partition table + A2 bootloader content.
IMG="${1:-$HOME/sdcard-images/odo-miner-cyclonev-20260611-130547.img}"
echo "=== image: $IMG ==="
ls -la "$IMG"
echo
echo "=== partition table (sfdisk dump) ==="
sfdisk -d "$IMG" 2>&1
echo
echo "=== fdisk -l ==="
fdisk -l "$IMG" 2>&1
echo
# Find the A2 (type a2) partition start sector from sfdisk
A2_START=$(sfdisk -d "$IMG" 2>/dev/null | awk -F'[ ,=]+' '/type=a2|type=A2/{for(i=1;i<=NF;i++) if($i=="start") print $(i+1)}')
echo "=== A2 partition start sector: ${A2_START:-<not found>} ==="
if [ -n "$A2_START" ]; then
  echo "First 64 bytes of A2 partition (should be SPL header, NOT all zeros):"
  dd if="$IMG" bs=512 skip="$A2_START" count=1 2>/dev/null | xxd | head -4
fi
echo
echo "=== FAT boot partition (p1) file listing ==="
P1_START=$(sfdisk -d "$IMG" 2>/dev/null | awk -F'[ ,=]+' '/type=c|type=b/{for(i=1;i<=NF;i++) if($i=="start"){print $(i+1); exit}}')
echo "p1 start sector: ${P1_START:-<not found>}"
if [ -n "$P1_START" ]; then
  OFF=$((P1_START * 512))
  mdir -i "$IMG"@@$OFF 2>&1 || echo "(mdir failed; will mount-check instead)"
fi
