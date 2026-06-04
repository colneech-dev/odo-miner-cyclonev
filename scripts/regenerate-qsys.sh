#!/bin/bash
# Regenerate Qsys DDR3 system from updated soc_system.qsys
# Run from project root directory

cd "c:\Users\Colin\Documents\GitHub\odo-miner-cyclonev"

QSYS_FILE="hdl/qsys/soc_system.qsys"
OUTPUT_DIR="hdl/qsys/soc_system"

echo "[*] Regenerating Qsys system: $QSYS_FILE"

# Check if qsys-generate is available
if ! command -v qsys-generate &> /dev/null; then
    echo "[!] ERROR: qsys-generate not found in PATH"
    echo "[!] Add Quartus bin directory to PATH:"
    echo '    export PATH="/c/intelFPGA/25.1std/quartus/bin:$PATH"'
    exit 1
fi

# Generate HDL from Qsys
qsys-generate "$QSYS_FILE" --synthesis=VERILOG --output-directory="$OUTPUT_DIR"

if [ $? -eq 0 ]; then
    echo "[OK] Qsys regeneration complete!"
    echo "[*] Generated files in: $OUTPUT_DIR/synthesis/"
    ls -la "$OUTPUT_DIR/synthesis/" | head -10
else
    echo "[!] Qsys generation failed!"
    exit 1
fi
