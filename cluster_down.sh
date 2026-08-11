#!/usr/bin/env bash

set -euo pipefail

# Dynamically find the project root and export it for Docker Compose
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST_ROOT="$PROJECT_ROOT"

echo "=========================================================="
echo "🛑 Shutting Down the Full Equity Trading Environment"
echo "=========================================================="

# ============================================================
# Detect container engine
# ============================================================
ENGINE=""
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE="docker"
else
    echo "❌ ERROR: Neither Docker nor Podman is running."
    exit 1
fi
echo "✅ Container engine: $ENGINE"

# Navigate to K8s directory
cd "$PROJECT_ROOT/k8s"

# Tear down the cluster using the toolbox
echo "🧹 Destroying k3d cluster..."
set +e # Disable strict mode temporarily in case the cluster is already gone
$ENGINE exec k8s-toolbox k3d cluster delete dev-cluster >/dev/null 2>&1

# Tear down the Compose stack and clean up zombie networks
echo "📦 Tearing down k8s-toolbox and volumes..."
$ENGINE compose down -v >/dev/null 2>&1
$ENGINE network rm k3d-network >/dev/null 2>&1
$ENGINE rm -f $($ENGINE ps -aq -f name=k3d-dev-cluster) >/dev/null 2>&1
set -e

echo "✅ Teardown complete."
