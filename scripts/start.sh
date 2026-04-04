#!/bin/bash
# start.sh — Start Claude Cluster locally
set -e

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENRESTY_BIN="$(command -v openresty 2>/dev/null || true)"

if [ -z "$OPENRESTY_BIN" ]; then
    echo "Error: openresty not found. Run scripts/setup-mac.sh first."
    exit 1
fi

# Ensure required directories
mkdir -p "$CLUSTER_DIR/projects" "$CLUSTER_DIR/logs"

# Symlink the Nchan .so into the cluster's modules/ directory
# so that "load_module modules/ngx_nchan_module.so" in nginx.conf works
OPENRESTY_REAL="$(readlink -f "$OPENRESTY_BIN" 2>/dev/null || readlink "$OPENRESTY_BIN" || echo "$OPENRESTY_BIN")"
OPENRESTY_PREFIX="$(cd "$(dirname "$OPENRESTY_REAL")/../.." && pwd)"
NCHAN_SRC="$OPENRESTY_PREFIX/nginx/modules/ngx_nchan_module.so"

if [ ! -f "$NCHAN_SRC" ]; then
    echo "Error: Nchan module not found at $NCHAN_SRC"
    echo "Run scripts/setup-mac.sh to build it."
    exit 1
fi

mkdir -p "$CLUSTER_DIR/modules"
ln -sf "$NCHAN_SRC" "$CLUSTER_DIR/modules/ngx_nchan_module.so"

# On macOS, nchan is a dynamic module — inject load_module into a temp conf
# (Docker image has nchan statically compiled, no load_module needed)
CONF="$CLUSTER_DIR/conf/nginx.conf"
if ! grep -q 'load_module.*nchan' "$CONF" 2>/dev/null; then
    CONF="/tmp/claude-cluster-nginx.conf"
    { echo "load_module $CLUSTER_DIR/modules/ngx_nchan_module.so;"; cat "$CLUSTER_DIR/conf/nginx.conf"; } > "$CONF"
fi

echo "OpenResty:  $OPENRESTY_BIN ($($OPENRESTY_BIN -v 2>&1))"
echo "Nchan:      $NCHAN_SRC"
echo "Cluster:    $CLUSTER_DIR"
echo ""
echo "Starting Claude Cluster on http://localhost:8080"
echo "Press Ctrl+C to stop"
echo ""

exec "$OPENRESTY_BIN" -p "$CLUSTER_DIR/" -c "$CONF"
