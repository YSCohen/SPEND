#!/usr/bin/env bash
# k3s_manager.sh - Interactive utility to manage K3s nodes over Tailscale and FluxCD

# Function to check if K3s is installed
check_installation() {
    if command -v k3s &>/dev/null; then
        if systemctl is-active --quiet k3s; then
            echo -e "\e[32m[Installed - Control Plane (Active)]\e[0m"
        elif systemctl is-active --quiet k3s-agent; then
            echo -e "\e[32m[Installed - Worker Node (Active)]\e[0m"
        else
            echo -e "\e[33m[Installed - Inactive/Unknown State]\e[0m"
        fi
    else
        echo -e "\e[31m[Not Installed]\e[0m"
    fi
}

# Function to ensure Tailscale is up and return the IP
setup_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        read -p "Tailscale is not installed. Install it now? (y/N): " install_ts
        if [[ ! "$install_ts" =~ ^[Yy]$ ]]; then
            echo "❌ Aborted: Tailscale is required for this operation."
            return 1
        fi
        echo "📦 Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    sudo systemctl enable tailscaled >/dev/null 2>&1 || true

    if ! tailscale status &>/dev/null; then
        echo "⚠️ Tailscale is not connected. Please authenticate:"
        sudo tailscale up
    fi

    TAILSCALE_IP=$(tailscale ip -4)
    echo "✅ Tailscale IP detected: ${TAILSCALE_IP}"
}

# Function to configure rootless kubectl access
setup_rootless_kubectl() {
    echo "🔧 Configuring rootless kubectl access..."
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    sed -i "s/127.0.0.1/${TAILSCALE_IP}/g" ~/.kube/config

    echo "✅ Kubectl is now accessible without sudo (config written to ~/.kube/config)."
}

# Function to install/join a Control Plane
install_control_plane() {
    setup_tailscale || return

    read -p "Are you joining an EXISTING Control Plane? (y/N): " join_existing
    if [[ "$join_existing" =~ ^[Yy]$ ]]; then
        read -p "Enter the existing Control Plane Tailscale IP: " JOIN_IP
        read -p "Enter the K3S_TOKEN: " JOIN_TOKEN

        if [ -z "$JOIN_IP" ] || [ -z "$JOIN_TOKEN" ]; then
            echo "❌ ERROR: IP and Token are required to join."
            return
        fi

        echo "📦 Joining Existing HA Cluster as a Control Plane..."
        curl -sfL https://get.k3s.io | K3S_TOKEN="${JOIN_TOKEN}" INSTALL_K3S_EXEC="server \
          --server https://${JOIN_IP}:6443 \
          --node-ip=${TAILSCALE_IP} \
          --flannel-iface=tailscale0 \
          --flannel-backend=vxlan \
          --bind-address=${TAILSCALE_IP} \
          --advertise-address=${TAILSCALE_IP} \
          --tls-san=${TAILSCALE_IP}" sh -s -
    else
        echo "📦 Initializing New HA K3s Server (embedded etcd)..."
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
          --cluster-init \
          --node-ip=${TAILSCALE_IP} \
          --flannel-iface=tailscale0 \
          --flannel-backend=vxlan \
          --bind-address=${TAILSCALE_IP} \
          --advertise-address=${TAILSCALE_IP} \
          --tls-san=${TAILSCALE_IP}" sh -s -
    fi

    echo "⏳ Waiting for K3s API to become available..."
    until sudo k3s kubectl get nodes &>/dev/null; do sleep 2; done

    if ! command -v flux &>/dev/null; then curl -s https://fluxcd.io/install.sh | sudo bash; fi
    if ! command -v helm &>/dev/null; then curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; fi

    setup_rootless_kubectl
    echo "🎉 Control Plane Bootstrap Complete!"
}

# Function to install a Worker Node
install_worker() {
    setup_tailscale || return

    read -p "Enter the Control Plane Tailscale IP: " CP_IP
    read -p "Enter the K3S_TOKEN: " WORKER_TOKEN

    if [ -z "$CP_IP" ] || [ -z "$WORKER_TOKEN" ]; then
        echo "❌ ERROR: Control Plane IP and Token are required."
        return
    fi

    echo "📦 Joining K3s Cluster as a Worker..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
      --node-ip=${TAILSCALE_IP} \
      --flannel-iface=tailscale0" \
        K3S_URL="https://${CP_IP}:6443" \
        K3S_TOKEN="${WORKER_TOKEN}" sh -s -

    echo "🎉 Worker Node Bootstrap Complete!"
}

# Function to show the current token and IP
show_token() {
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Unknown")

    if sudo test -f /var/lib/rancher/k3s/server/node-token; then
        echo "======================================"
        echo "📍 Control Plane IP: ${TAILSCALE_IP}"
        echo "🔑 Current K3s Cluster Token:"
        sudo cat /var/lib/rancher/k3s/server/node-token
        echo ""
        echo "======================================"
    else
        echo "❌ Token not found. This node might not be a Control Plane."
    fi
}

# Function to setup Local USB Storage purely via K3s auto-deploy
setup_local_storage() {
    echo "💽 Configuring Local USB Storage..."
    read -p "Enter the local mount path [/mnt/usb-storage]: " USB_PATH
    USB_PATH=${USB_PATH:-/mnt/usb-storage}

    echo "Generating Kubernetes manifest for local storage..."
    cat <<EOF | sudo tee /var/lib/rancher/k3s/server/manifests/usb-storage.yaml >/dev/null
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: usb-storage-pv
spec:
  capacity:
    storage: 500Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: ${USB_PATH}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: usb-storage-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 500Gi
EOF
    echo "✅ Local storage manifest deployed directly to K3s! (Bypassing Flux)"
}

# Function to uninstall K3s
uninstall_k3s() {
    read -p "⚠️ Are you sure you want to uninstall K3s? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
            echo "🗑️ Uninstalling Control Plane..."
            /usr/local/bin/k3s-uninstall.sh
        elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
            echo "🗑️ Uninstalling Worker Node..."
            /usr/local/bin/k3s-agent-uninstall.sh
        else
            echo "❌ No uninstall scripts found. Is K3s installed?"
        fi
    else
        echo "Aborted."
    fi
}

# Function to bootstrap FluxCD
bootstrap_flux() {
    if ! command -v flux &>/dev/null; then
        echo "❌ Flux CLI is not installed. Please install a Control Plane first."
        return
    fi

    echo ""
    echo "🚢 Bootstrapping FluxCD..."

    read -s -p "Enter your GITHUB_TOKEN: " GITHUB_TOKEN
    echo ""
    read -p "Enter GitHub Owner [SM26-Industrial-Software-Dev]: " GITHUB_OWNER
    GITHUB_OWNER=${GITHUB_OWNER:-SM26-Industrial-Software-Dev}
    read -p "Enter Repository Name [SPEND]: " GITHUB_REPO
    GITHUB_REPO=${GITHUB_REPO:-SPEND}
    read -p "Enter Branch [main]: " GITHUB_BRANCH
    GITHUB_BRANCH=${GITHUB_BRANCH:-main}
    read -p "Enter Path [./k8s/clusters/k3s]: " GITHUB_PATH
    GITHUB_PATH=${GITHUB_PATH:-./k8s/clusters/k3s}

    export GITHUB_TOKEN=$GITHUB_TOKEN

    flux bootstrap github \
        --owner="${GITHUB_OWNER}" \
        --repository="${GITHUB_REPO}" \
        --branch="${GITHUB_BRANCH}" \
        --path="${GITHUB_PATH}" \
        --personal=false \
        --token-auth

    unset GITHUB_TOKEN
    echo "✅ Flux bootstrap complete!"
}

# Function to setup Make Developer Toolbox
setup_make_toolbox() {
    if ! command -v make &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            echo "📦 Installing Make..."
            sudo apt-get update
            sudo apt-get install -y make
        else
            echo "❌ Make is not installed and apt-get is unavailable. Install make with your package manager and re-run."
            return 1
        fi
    else
        echo "✅ Make is already installed."
    fi

    echo "⬇️ Downloading Developer Toolbox (Makefiles)..."

    local REPO_OWNER="SM26-Industrial-Software-Dev"
    local REPO_NAME="SPEND"
    local REF="main"

    read -p "Branch or tag to fetch Makefiles from [main]: " input_ref
    REF="${input_ref:-main}"

    if [ -f ~/Makefile ]; then
        read -p "⚠️ ~/Makefile already exists. Overwrite it? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "Aborted. No changes made."
            return 0
        fi
    fi

    if curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REF}/make/k3s.mk" -o ~/Makefile; then
        echo "✅ Make commands imported to ~/Makefile. Run 'make help' from your home directory to see available commands."
    else
        echo "❌ Download failed. ~/Makefile was not updated correctly."
        return 1
    fi
}

# Function to update this script from the repository
update_self() {
    local REPO_OWNER="SM26-Industrial-Software-Dev"
    local REPO_NAME="SPEND"
    local SCRIPT_PATH="k3s_manager.sh"

    read -p "Branch or tag to update from [main]: " REF
    REF="${REF:-main}"

    local RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REF}/${SCRIPT_PATH}"
    local TMP_FILE
    TMP_FILE=$(mktemp)

    echo "⬇️  Pulling k3s_manager.sh from '${REF}'..."
    if ! curl -fsSL "$RAW_URL" -o "$TMP_FILE"; then
        echo "❌ Update failed: could not download the script (network or repository issue)."
        rm -f "$TMP_FILE"
        return 1
    fi

    # Sanity check: non-empty, looks like a shell script, and parses.
    if [ ! -s "$TMP_FILE" ] || ! head -n1 "$TMP_FILE" | grep -q '^#!'; then
        echo "❌ Update aborted: downloaded file is empty or doesn't look like a script."
        rm -f "$TMP_FILE"
        return 1
    fi
    if ! bash -n "$TMP_FILE"; then
        echo "❌ Update aborted: downloaded script failed a syntax check."
        rm -f "$TMP_FILE"
        return 1
    fi

    # Show exactly what's changing before committing to it.
    echo ""
    echo "📋 Changes to be applied:"
    diff -u "$0" "$TMP_FILE" || true
    echo ""
    read -p "Apply this update? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        rm -f "$TMP_FILE"
        return 0
    fi

    # Keep a rollback copy before overwriting the running script.
    cp "$0" "$0.bak"
    echo "🗄️  Backed up current script to $0.bak"

    mv "$TMP_FILE" "$0"
    chmod +x "$0"
    echo "✅ Successfully updated. Please re-run the script."
    echo "   Roll back anytime with: cp $0.bak $0"
    exit 0
}

# Function to list current cluster nodes
list_nodes() {
    echo "📋 Current Cluster Nodes:"
    if command -v kubectl &>/dev/null; then
        kubectl get nodes -o wide
    else
        sudo k3s kubectl get nodes -o wide
    fi
}

# Main Menu Loop
while true; do
    echo ""
    echo "======================================"
    echo " 🚀 K3s Cluster Manager "
    echo " Status: $(check_installation)"
    echo "======================================"
    echo "1) Bootstrap/Join Control Plane"
    echo "2) Join as Worker Node"
    echo "3) Show Cluster Info (Token & IP)"
    echo "4) List Nodes"
    echo "5) Configure Local USB Storage"
    echo "6) Bootstrap FluxCD"
    echo "7) Setup Make Toolbox"
    echo "8) Uninstall K3s"
    echo "9) Update Manager"
    echo "10) Exit"
    echo "======================================"
    read -p "Select an option [1-10]: " choice

    case $choice in
    1) install_control_plane ;;
    2) install_worker ;;
    3) show_token ;;
    4) list_nodes ;;
    5) setup_local_storage ;;
    6) bootstrap_flux ;;
    7) setup_make_toolbox ;;
    8) uninstall_k3s ;;
    9) update_self ;;
    10)
        echo "Goodbye!"
        exit 0
        ;;
    *) echo "❌ Invalid option. Please try again." ;;
    esac
done
