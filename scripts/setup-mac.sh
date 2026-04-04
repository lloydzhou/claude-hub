#!/bin/bash
# setup-mac.sh — Build Nchan dynamic module for Homebrew OpenResty (macOS)
set -e

NCHAN_VERSION="1.3.8"

echo "=== Claude Cluster — macOS Setup ==="

# --- Locate OpenResty ---
OPENRESTY_BIN="$(command -v openresty 2>/dev/null || true)"
if [ -z "$OPENRESTY_BIN" ]; then
    echo "OpenResty not found. Installing via Homebrew..."
    brew install openresty/brew/openresty --without-geoip
    OPENRESTY_BIN="$(command -v openresty)"
fi

if ! openresty -V 2>&1 | grep -q '\-\-with-compat'; then
    echo "ERROR: Installed OpenResty lacks --with-compat. Cannot build dynamic modules."
    exit 1
fi

OPENRESTY_VERSION="$(openresty -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
echo "OpenResty ${OPENRESTY_VERSION} (--with-compat ✓)"

# Resolve install prefix — follow symlinks to get the real path
OPENRESTY_REAL="$(readlink -f "$OPENRESTY_BIN" 2>/dev/null)"
if [ -z "$OPENRESTY_REAL" ]; then
    # macOS readlink doesn't support -f; resolve manually
    OPENRESTY_TARGET="$(readlink "$OPENRESTY_BIN" 2>/dev/null || echo "$OPENRESTY_BIN")"
    if [[ "$OPENRESTY_TARGET" != /* ]]; then
        OPENRESTY_REAL="$(cd "$(dirname "$OPENRESTY_BIN")" && cd "$(dirname "$OPENRESTY_TARGET")" && pwd)/$(basename "$OPENRESTY_TARGET")"
    else
        OPENRESTY_REAL="$OPENRESTY_TARGET"
    fi
fi
OPENRESTY_PREFIX="$(cd "$(dirname "$OPENRESTY_REAL")/../.." && pwd)"
echo "OpenResty prefix: $OPENRESTY_PREFIX"
MODULES_DIR="$OPENRESTY_PREFIX/nginx/modules"
NCHAN_SO="$MODULES_DIR/ngx_nchan_module.so"

if [ -f "$NCHAN_SO" ]; then
    echo "Nchan module already installed: $NCHAN_SO"
    echo ""
    echo "=== Done. Run: ./scripts/start.sh ==="
    exit 0
fi

# --- Build ---
echo "Building Nchan v${NCHAN_VERSION} dynamic module..."
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"

echo "  Fetching OpenResty source..."
curl -sL "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" | tar xz

echo "  Fetching Nchan v${NCHAN_VERSION}..."
curl -sL "https://github.com/slact/nchan/archive/refs/tags/v${NCHAN_VERSION}.tar.gz" | tar xz
mv "nchan-${NCHAN_VERSION}" nchan

cd "openresty-${OPENRESTY_VERSION}"

echo "  Configuring..."
./configure --with-compat --add-dynamic-module="$TMPDIR/nchan" > /dev/null

echo "  Compiling module..."
NGINX_BUILD="$(ls -d build/nginx-*/)"
cd "$NGINX_BUILD"
make modules -j"$(sysctl -n hw.ncpu)"

mkdir -p "$MODULES_DIR"
cp objs/ngx_nchan_module.so "$NCHAN_SO"
echo "  Installed: $NCHAN_SO"

echo ""
echo "=== Done. Run: ./scripts/start.sh ==="
