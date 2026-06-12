#!/bin/bash
# Compare the HPS DDR3/pinmux/pll handoff between the SoCDK board (what we built)
# and the DE10-Nano board (what the hardware likely needs).
UB=~/buildroot-2025.11.3/output/build/uboot-2023.10
SOCDK="$UB/board/altera/cyclone5-socdk/qts"
DE10="$UB/board/terasic/de10-nano/qts"

echo "############ sdram_config.h diff (DDR3 controller) ############"
diff <(cat "$SOCDK/sdram_config.h") <(cat "$DE10/sdram_config.h") | head -40
echo
echo "############ pinmux_config.h differs? ############"
if diff -q "$SOCDK/pinmux_config.h" "$DE10/pinmux_config.h" >/dev/null; then echo SAME; else echo DIFFERENT; fi
echo "############ pll_config.h differs? ############"
if diff -q "$SOCDK/pll_config.h" "$DE10/pll_config.h" >/dev/null; then echo SAME; else echo DIFFERENT; fi
echo "############ iocsr_config.h differs? ############"
if diff -q "$SOCDK/iocsr_config.h" "$DE10/iocsr_config.h" >/dev/null; then echo SAME; else echo DIFFERENT; fi
echo "############ sdram_config.h differs? ############"
if diff -q "$SOCDK/sdram_config.h" "$DE10/sdram_config.h" >/dev/null; then echo SAME; else echo DIFFERENT; fi
