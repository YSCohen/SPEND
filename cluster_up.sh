#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST_ROOT="$PROJECT_ROOT"

# ============================================================
# Argument parsing - default to upstream if no name is given
# ============================================================
DEV_NAME="${1:-}"
DEV_NAME="${DEV_NAME#--}" # tolerate the old --name flag form

if [ -z "$DEV_NAME" ] || [ "$DEV_NAME" = "upstream" ]; then
    REPO_NAME="main-repo"
    TARGET_FILE="target-upstream.yaml"
else
    REPO_NAME="dev-repo-$DEV_NAME"
    TARGET_FILE="target-$DEV_NAME.yaml"
    if [ ! -f "$PROJECT_ROOT/k8s/flux-system/targets/$TARGET_FILE" ]; then
        echo "❌ Unknown target: $DEV_NAME"
        echo "   Usage: ./cluster_up.sh [name]   (no name = upstream, production-like)"
        echo "   Available targets:"
        for f in "$PROJECT_ROOT"/k8s/flux-system/targets/target-*.yaml; do
            f="$(basename "$f")"
            f="${f#target-}"
            echo "     ${f%.yaml}"
        done
        exit 1
    fi
fi

echo "=========================================================="
echo "🚀 Deploying Equity Trading System"
echo "   Source : $REPO_NAME"
echo "   Target : $TARGET_FILE"
echo "=========================================================="

# ============================================================
# Detect container engine (CONTAINER_ENGINE=docker|podman overrides)
# ============================================================
ENGINE=""
if [ -n "${CONTAINER_ENGINE:-}" ]; then
    if ! "$CONTAINER_ENGINE" info >/dev/null 2>&1; then
        echo "❌ ERROR: CONTAINER_ENGINE=$CONTAINER_ENGINE, but it is not running."
        exit 1
    fi
    ENGINE="$CONTAINER_ENGINE"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE="docker"
else
    echo "❌ ERROR: Neither Docker nor Podman is running."
    exit 1
fi
echo "✅ Container engine: $ENGINE"

# ============================================================
# Detect socket path
# ============================================================
USER_ID=$(id -u)
ACTUAL_SOCK="/var/run/docker.sock"
OSTYPE_VAL="${OSTYPE:-unknown}"

if [[ "$ENGINE" == "podman" ]]; then
    if [ -S "/run/user/$USER_ID/podman/podman.sock" ]; then
        ACTUAL_SOCK="/run/user/$USER_ID/podman/podman.sock"
    elif [ -S "/run/podman/podman.sock" ]; then
        ACTUAL_SOCK="/run/podman/podman.sock"
    else
        ACTUAL_SOCK="$HOME/.local/share/containers/podman/machine/podman.sock"
    fi
else
    if [[ "$OSTYPE_VAL" =~ ^(msys|cygwin|win32)$ ]]; then
        ACTUAL_SOCK="//var/run/docker.sock"
    elif [ ! -S "$ACTUAL_SOCK" ]; then
        if [ -S "/run/user/$USER_ID/docker.sock" ]; then
            ACTUAL_SOCK="/run/user/$USER_ID/docker.sock"
        elif [ -S "$HOME/.docker/run/docker.sock" ]; then
            ACTUAL_SOCK="$HOME/.docker/run/docker.sock"
        fi
    fi
fi
echo "✅ Socket: $ACTUAL_SOCK"

# ============================================================
# Sanity check
# ============================================================
if [ ! -d "$PROJECT_ROOT/k8s" ]; then
    echo "❌ ERROR: '$PROJECT_ROOT/k8s' not found. Is the repo checkout intact?"
    exit 1
fi

cd "$PROJECT_ROOT/k8s"
echo "DOCKER_HOST_PATH=$ACTUAL_SOCK" >.env

# ============================================================
# Tear down any previous environment
# ============================================================
echo "🧹 Tearing down previous environment..."
set +e
$ENGINE compose up -d >/dev/null 2>&1
$ENGINE exec k8s-toolbox k3d cluster delete dev-cluster >/dev/null 2>&1
$ENGINE compose down -v >/dev/null 2>&1
$ENGINE network rm k3d-network >/dev/null 2>&1
$ENGINE rm -f $($ENGINE ps -aq -f name=k3d-dev-cluster) >/dev/null 2>&1
set -e

# ============================================================
# Start toolbox + create cluster (injects Flux controllers only)
# ============================================================
echo "📦 Starting k8s-toolbox..."
$ENGINE compose up -d --build

echo "🚀 Creating cluster (bootstrapping Flux controllers)..."

# Use --no-host-dns to stop k3d from touching /etc/resolv.conf
$ENGINE exec -e HOST_ROOT="$PROJECT_ROOT" -i k8s-toolbox \
    k3d cluster create --config k8s/k3d-config.yaml \
    --k3s-arg "--resolv-conf=/tmp/custom-resolv.conf@server:*" \
    --k3s-arg "--resolv-conf=/tmp/custom-resolv.conf@agent:*"

# ============================================================
# Wait for API server - check the API endpoint directly,
# not just node readiness, to avoid the openapi dial error
# ============================================================
echo "⏳ Waiting for Kubernetes API server..."
until $ENGINE exec k8s-toolbox kubectl get --raw /readyz >/dev/null 2>&1; do
    echo "   ...still waiting"
    sleep 5
done
echo "✅ API server is ready."

# ============================================================
# Bootstrapping Flux (Pure IaC)
# ============================================================
echo "📦 Bootstrapping Flux Controllers (Declarative Kustomize)..."

# Apply the 4-line kustomization.yaml file directly from your repo.
# Kubernetes will automatically download the required images in the background!
$ENGINE exec -i k8s-toolbox kubectl apply -k "k8s/flux-system"

# Wait for Flux CRDs to be established before we apply targets
echo "⏳ Waiting for Flux CRDs to initialize..."
until $ENGINE exec k8s-toolbox kubectl get crd gitrepositories.source.toolkit.fluxcd.io >/dev/null 2>&1; do
    echo "   ...waiting for Flux CRDs"
    sleep 5
done
echo "✅ Flux CRDs are ready."

# ============================================================
# Apply the correct target (GitRepository + Kustomization)
# ============================================================
echo "🔄 Applying target: $TARGET_FILE"
$ENGINE exec -i k8s-toolbox \
    kubectl apply -f "k8s/flux-system/targets/$TARGET_FILE"

# ============================================================
# Force an immediate reconciliation so we don't wait 1 minute
# ============================================================
echo "⚡ Forcing Flux sync..."
$ENGINE exec -i k8s-toolbox flux reconcile source git "$REPO_NAME"
$ENGINE exec -i k8s-toolbox flux reconcile kustomization 1-infra --with-source

echo ""
echo "📈 ======================================================= 📈"
echo "   DEPLOYMENT INITIATED - Flux is reconciling the system     "
echo "   Services come online as images pull; watch with:          "
echo "   'make status' (or 'flux get kustomizations')              "
echo " --------------------------------------------------------- "
echo " 🟢 API Gateway       -> http://api.localhost:8080"
echo " 📊 Streamlit UI      -> http://streamlit.localhost:8080"
echo " 🦗 Locust Load Test  -> http://locust.localhost:8080"
echo " 🔭 Grafana Metrics   -> http://grafana.localhost:8080"
echo " 🐘 Adminer Database  -> http://adminer.localhost:8080"
echo " 🔴 RedisInsight      -> http://redisinsight.localhost:8080"
echo " "
echo " 🔐 Default System Credentials:"
echo "    Grafana UI -> User: admin | Pass: Rust!"
echo "    PostgreSQL -> Run 'make adminer-info' to fetch auto-generated credentials"
echo "📈 ======================================================= 📈"
