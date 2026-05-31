#!/usr/bin/env bash
# setup-wsl.sh — one-shot WSL/Ubuntu bootstrap for odo-miner HPS development
# Usage: run inside WSL Ubuntu as a normal user (it will sudo where needed)

set -euo pipefail

REQUIRED_PACKAGES=(
  build-essential
  make
  git
  gcc-arm-linux-gnueabihf
  binutils-arm-linux-gnueabihf
  gcc-aarch64-linux-gnu
  gh
  rsync
)

echo "This script will install toolchain packages for building and cross-compiling."
read -p "Continue? [y/N] " yn
case "$yn" in
  [Yy]*) ;;
  *) echo "Aborted."; exit 1;;
esac

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Warning: This does not look like WSL. Proceeding anyway."
fi

echo "Updating apt caches..."
sudo apt-get update -y

# Install prerequisites
echo "Installing packages: ${REQUIRED_PACKAGES[*]}"
sudo apt-get install -y ${REQUIRED_PACKAGES[*]}

# Optional: enable multiverse for gh on older Ubuntu (no-op on modern releases)
# sudo add-apt-repository -y multiverse || true

# Verify installation
echo "Verifying toolchain installs..."
for cmd in gcc arm-linux-gnueabihf-gcc gh; do
  if command -v $cmd >/dev/null 2>&1; then
    echo "  OK: $cmd -> $(command -v $cmd)"
  else
    echo "  MISSING: $cmd (install may have failed)"
  fi
done

cat <<'EOF'

Done. Next steps:

1) Build the smoke test (native):
   cd /mnt/c/Users/builder/Documents/GitHub/odo-miner-cyclonev/hps
   make smoke_test

2) Cross-build for ARM locally:
   cd /mnt/c/Users/builder/Documents/GitHub/odo-miner-cyclonev/hps
   CC=arm-linux-gnueabihf-gcc make smoke_test

3) Copy the binary to your HPS board (use scp/rsync) and run as root:
   scp fpga_smoke_test user@hps-ip:/tmp/
   ssh user@hps-ip 'sudo /tmp/fpga_smoke_test'

If you prefer CI-built artifacts instead of installing locally, download
`fpga_smoke_test-arm` from the GitHub Actions run artifacts.
EOF
