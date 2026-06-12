#!/bin/bash
BR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
T="$BR/output/target"
K=$(ls -d "$BR"/output/build/linux-* 2>/dev/null | head -1)
echo "=== fbtft fb_* drivers built as modules ==="
find "$T/lib/modules" -iname 'fb_*' 2>/dev/null | sed 's#.*/##' | sort
echo
echo "=== kernel config: fbtft controllers (=y or =m) ==="
grep -iE 'CONFIG_FB_TFT_ST7789|CONFIG_FB_TFT_ILI9341|CONFIG_FB_TFT_ST7735|CONFIG_FB_TFT=|CONFIG_FB_TFT_FBTFT' "$K/.config" 2>/dev/null | grep -vE '# '
echo
echo "=== all FB_TFT_ options set ==="
grep -iE 'CONFIG_FB_TFT_[A-Z0-9]+=(y|m)' "$K/.config" 2>/dev/null
