#!/bin/bash
# Check whether the built image supports the RTL8192EU USB wifi adapter.
BR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
K=$(ls -d "$BR"/output/build/linux-* 2>/dev/null | head -1)
T="$BR/output/target"

echo "=== kernel config (driver + stack + USB host) ==="
grep -iE 'CONFIG_RTL8XXXU|CONFIG_CFG80211|CONFIG_MAC80211|CONFIG_USB_EHCI_HCD|CONFIG_USB_DWC2|CONFIG_WLAN=|CONFIG_RTL_CARDS|CONFIG_USB_GADGET' "$K/.config" 2>/dev/null | sort
echo "  (blank above = none set)"
echo
echo "=== buildroot wifi packages ==="
grep -iE 'LINUX_FIRMWARE|WPA_SUPPLICANT|PACKAGE_IW=|RTL87|RTL81|WIRELESS_TOOLS|WILC' "$BR/.config" 2>/dev/null | grep -E '=y|="' | head -30
echo
echo "=== RTL8192EU firmware in rootfs? ==="
find "$T/lib/firmware" -iname '*8192e*' 2>/dev/null
ls "$T/lib/firmware/rtlwifi/" 2>/dev/null | head || echo "(no rtlwifi firmware dir)"
echo
echo "=== userspace tools in rootfs? ==="
for f in usr/sbin/wpa_supplicant usr/sbin/iw sbin/udhcpc usr/sbin/dhcpcd usr/bin/wpa_passphrase; do
  [ -e "$T/$f" ] && echo "  yes: $f" || echo "  MISSING: $f"
done
echo
echo "=== rtl8xxxu module built (if =m)? ==="
find "$T/lib/modules" -iname 'rtl8xxxu*' 2>/dev/null || echo "(no rtl8xxxu module)"
