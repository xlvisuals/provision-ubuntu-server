#!/usr/bin/env bash
# upgrade_pypy.sh — upgrade PyPy 3.11 to the latest release (or a specified version)
#
# Usage:
#   sudo ./upgrade_pypy.sh                        # upgrades to latest
#   sudo ./upgrade_pypy.sh pypy3.11-v7.3.23       # upgrades to a specific version
#
# PyPy is installed to /opt/<version-dir>/ with symlinks in /usr/local/bin/.
# Old versions are left in /opt/ and must be removed manually.
#
set -euo pipefail

PYPY_FALLBACK_VERSION="pypy3.11-v8.0.1"
PYPY_BASE_URL="https://downloads.python.org/pypy"

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

# --- Detect architecture ---
PYPY_ARCH=$(uname -m | sed 's/x86_64/linux64/;s/aarch64/aarch64/')

# --- Determine target version ---
if [[ -n "${1:-}" ]]; then
    PYPY_FILENAME="${1}-${PYPY_ARCH}.tar.bz2"
    echo "  Target version specified: $1"
else
    echo "  Fetching latest PyPy 3.11 release ..."
    PYPY_FILENAME=$(curl -fsSL --max-time 15 "$PYPY_BASE_URL/versions.json" 2>/dev/null \
        | grep -oP "pypy3\.11-v[\d.]+-${PYPY_ARCH}\.tar\.bz2" \
        | sort -V | tail -n1 || true)

    if [[ -z "$PYPY_FILENAME" ]]; then
        echo "  [!] Could not fetch latest version — using fallback $PYPY_FALLBACK_VERSION"
        PYPY_FILENAME="${PYPY_FALLBACK_VERSION}-${PYPY_ARCH}.tar.bz2"
    fi
    echo "  Latest: ${PYPY_FILENAME%.tar.bz2}"
fi

PYPY_DIRNAME="${PYPY_FILENAME%.tar.bz2}"

# --- Check current version ---
CURRENT_VERSION=$(pypy3 --version 2>&1 | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
echo "  Current version: $CURRENT_VERSION"

if [[ -d "/opt/$PYPY_DIRNAME" ]]; then
    echo "  /opt/$PYPY_DIRNAME already exists — nothing to do."
    exit 0
fi

# --- Download ---
echo ""
echo "  Downloading $PYPY_FILENAME ..."
TMP_DIR=$(mktemp -d /tmp/pypy-upgrade-XXXXXX)
cd "$TMP_DIR"

if ! wget -q "$PYPY_BASE_URL/$PYPY_FILENAME"; then
    echo "  [!] Download failed: $PYPY_BASE_URL/$PYPY_FILENAME" >&2
    rm -rf "$TMP_DIR"
    exit 1
fi

# --- Extract and install ---
echo "  Extracting ..."
tar -xjf "$PYPY_FILENAME"
mv "$PYPY_DIRNAME" /opt/
cd /
rm -rf "$TMP_DIR"

# --- Update symlinks ---
echo "  Updating symlinks ..."
ln -sf "/opt/$PYPY_DIRNAME/bin/pypy3" /usr/local/bin/pypy3.11
ln -sf "/opt/$PYPY_DIRNAME/bin/pypy3" /usr/local/bin/pypy3
ln -sf "/opt/$PYPY_DIRNAME/bin/pypy3" /usr/local/bin/pypy

# --- Bootstrap pip ---
echo "  Updating pip ..."
/usr/local/bin/pypy3.11 -m ensurepip
/usr/local/bin/pypy3.11 -m pip install --upgrade --root-user-action=ignore pip virtualenv

# --- Verify ---
NEW_VERSION=$(pypy3 --version 2>&1 | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
echo ""
echo "  [V] PyPy upgraded: $CURRENT_VERSION -> $NEW_VERSION"
echo ""
echo "  Old versions in /opt/ can be removed once you've confirmed the new version works:"
ls /opt/ | grep pypy | sed "s/^/    rm -rf \/opt\//" | grep -v "$PYPY_DIRNAME" || true
