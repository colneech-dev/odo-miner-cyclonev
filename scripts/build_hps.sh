#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

cd "${REPO_ROOT}/hps"
make clean all

echo "HPS build complete. Generated binaries: odod, fpga_smoke_test"