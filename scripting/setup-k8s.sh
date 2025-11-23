#!/bin/bash
# Kubernetes + Calico setup script
# Equivalent to cloud-init/k8s-full-calico.yaml
# Run as root on a fresh Ubuntu 22.04+ system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    error "Please run as root"
fi

log "Starting Kubernetes + Calico setup..."

# ============================================================================
# System Configuration
# ============================================================================

log "Configuring system settings..."

# Set timezone
timedatectl set-timezone UTC || warn "Failed to set timezone"

# Configure NTP
cat > /etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org
EOF
systemctl restart systemd-timesyncd || warn "Failed to restart timesyncd"

# Update and upgrade packages
log "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# Install base packages
log "Installing base packages..."
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    bash-completion \
    vim \
    htop \
    net-tools \
    iputils-ping \
    wget \
    git

# ============================================================================
# User Configuration
# ============================================================================

log "Configuring user and SSH..."

# Create user if it doesn't exist
if ! id -u matt &>/dev/null; then
    useradd -m -s /bin/bash -G sudo matt
    log "Created user 'matt'"
else
    log "User 'matt' already exists"
fi

# Add SSH key
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKDLDp6znRA+JepG9SOo4NAoB2NFToODqYf5ntRtYAON mat@Matthews-MBP.ip.lan"
mkdir -p /home/matt/.ssh
echo "$SSH_KEY" >> /home/matt/.ssh/authorized_keys
chmod 700 /home/matt/.ssh
chmod 600 /home/matt/.ssh/authorized_keys
chown -R matt:matt /home/matt/.ssh

# Configure sudoers
echo "matt ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/matt
chmod 0440 /etc/sudoers.d/matt

# SSH hardening
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
systemctl restart sshd || warn "Failed to restart SSH"

# ============================================================================
# Kernel Modules and Sysctls
# ============================================================================

log "Configuring kernel modules and sysctls..."

# Write modules config
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

# Write Kubernetes sysctls
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

# Write basic network optimizations
cat > /etc/sysctl.d/99-cloud-init.conf <<EOF
# Basic network optimizations
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
EOF

# Load modules
modprobe overlay || warn "Failed to load overlay module"
modprobe br_netfilter || warn "Failed to load br_netfilter module"
sysctl --system > /dev/null

# ============================================================================
# Disable Swap
# ============================================================================

log "Disabling swap..."
sed -i '/ swap / s/^/#/' /etc/fstab
swapoff -a || warn "Failed to disable swap"

# ============================================================================
# Containerd Installation
# ============================================================================

log "Installing and configuring containerd..."
apt-get install -y -qq containerd

# Generate default config and enable systemd cgroups
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd
log "Containerd installed and configured"

# ============================================================================
# Kubernetes Installation
# ============================================================================

log "Installing Kubernetes components..."

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
    gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" > \
    /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

# Install Kubernetes components
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

log "Kubernetes components installed"

# ============================================================================
# Kubernetes Configuration Files
# ============================================================================

log "Creating Kubernetes configuration files..."

mkdir -p /etc/kubernetes/manifests

# kubeadm config
cat > /etc/kubernetes/kubeadm-config.yaml <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "v1.34.0"
networking:
  podSubnet: "192.168.0.0/16"  # matches Calico default IPv4 pool below
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs: {}
EOF

# Calico WireGuard config
cat > /etc/kubernetes/manifests/calico-felix-wireguard.yaml <<'EOF'
apiVersion: crd.projectcalico.org/v1
kind: FelixConfiguration
metadata:
  name: default
spec:
  wireguardEnabled: true
  # Optional: choose the WireGuard interface name
  wireguardInterfaceName: wg-calico
  # Optional: enable routing on wg interface for cross-DC scenarios
  wireguardRoutingEnabled: true
EOF

# Calico IP pool config
cat > /etc/kubernetes/manifests/calico-ip-pool.yaml <<'EOF'
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 192.168.0.0/16
  encapsulation: VXLAN
  natOutgoing: true
  nodeSelector: all()
  # MTU tuning: account for WireGuard overhead (lower than NIC MTU)
  mtu: 1380
EOF

# kubectl completion
cat > /etc/profile.d/kubectl-completion.sh <<'EOF'
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion bash)
fi
EOF
chmod +x /etc/profile.d/kubectl-completion.sh

# ============================================================================
# Detect Node IP and Update kubeadm Config
# ============================================================================

log "Detecting node IP..."
NODE_IP=""

# Try cloud-init query first (works with Proxmox)
if command -v cloud-init &>/dev/null; then
    NODE_IP=$(cloud-init query local-ipv4 2>/dev/null || echo '')
fi

# Fallback to detecting primary interface IP
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++){if($i=="src"){print $(i+1);exit}}}' || echo '')
fi

if [ -n "$NODE_IP" ]; then
    sed -i "/kubeletExtraArgs:/a\          node-ip: \"$NODE_IP\"" /etc/kubernetes/kubeadm-config.yaml
    log "Configured node-ip: $NODE_IP"
else
    warn "Could not detect node IP, kubeadm will auto-detect"
fi

# ============================================================================
# Initialize Kubernetes Cluster
# ============================================================================

log "Initializing Kubernetes cluster (this may take a few minutes)..."
kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --ignore-preflight-errors=Swap

# Configure kubectl for root and matt
log "Configuring kubectl..."
mkdir -p /root/.kube /home/matt/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
cp /etc/kubernetes/admin.conf /home/matt/.kube/config
chown matt:matt /home/matt/.kube/config
chmod 600 /root/.kube/config /home/matt/.kube/config

# ============================================================================
# Wait for API Server
# ============================================================================

log "Waiting for Kubernetes API server to be ready..."
for i in {1..30}; do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; then
        log "API server is ready"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 10
done

# ============================================================================
# Install Calico
# ============================================================================

log "Installing Calico CNI..."
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

log "Waiting for Calico operator to be ready..."
sleep 10

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

log "Waiting for Calico to be ready..."
for i in {1..60}; do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get felixconfiguration default &>/dev/null; then
        log "Calico is ready"
        break
    fi
    echo "Waiting for Calico... ($i/60)"
    sleep 5
done

# Apply WireGuard and IP pool configs
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    /etc/kubernetes/manifests/calico-felix-wireguard.yaml
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    /etc/kubernetes/manifests/calico-ip-pool.yaml

# Allow workloads on control-plane
kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- || true

log "Calico installed and configured"

# ============================================================================
# Save Join Command
# ============================================================================

log "Saving join command..."
kubeadm token create --print-join-command > /root/join.sh
chmod +x /root/join.sh
log "Join command saved to /root/join.sh"

# ============================================================================
# Monitoring Configuration
# ============================================================================

log "Configuring monitoring services..."

# Create monitoring config directory
mkdir -p /etc/monitoring

# Monitoring config file
cat > /etc/monitoring/config.env <<'EOF'
# Prometheus server endpoint (for remote_write or scrape)
# Format: http://prometheus-server:9090/api/v1/write
# Or leave empty to use Prometheus scrape mode (default port 9100)
PROMETHEUS_REMOTE_WRITE_URL=""

# SigNoz endpoint for logs and traces
# Format: http://signoz-server:4318 (OTLP HTTP) or http://signoz-server:4317 (OTLP gRPC)
SIGNOZ_ENDPOINT="http://signoz-server:4318"

# Optional: SigNoz API key for authentication
SIGNOZ_API_KEY=""
EOF

# Prometheus Node Exporter service
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=0.0.0.0:9100 \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($$|/)"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# OpenTelemetry Collector config template
mkdir -p /etc/otelcol
cat > /etc/otelcol/config.yaml.template <<'EOF'
receivers:
  # Collect logs from systemd journal (journald receiver available in contrib)
  journald:
    directory: /var/log/journal
    units: []
    priority: info
  
  # Collect host metrics
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      disk:
      load:
      filesystem:
      memory:
      network:
      paging:
      process:
  
  # Collect node exporter metrics (scraping from local node_exporter)
  prometheus:
    config:
      scrape_configs:
        - job_name: 'node-exporter'
          static_configs:
            - targets: ['localhost:9100']
        - job_name: 'kubelet'
          static_configs:
            - targets: ['localhost:10255']
          metric_relabel_configs:
            - source_labels: [__name__]
              regex: 'container_.*'
              action: keep

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024
  resource:
    attributes:
      - key: host.name
        from_attribute: host.name
        action: upsert
      - key: service.name
        value: k8s-node
        action: upsert

exporters:
  # Send to SigNoz via OTLP HTTP
  otlphttp:
    endpoint: SIGNOZ_ENDPOINT_PLACEHOLDER
    tls:
      insecure: true
    headers:
      SIGNOZ_HEADERS_PLACEHOLDER

service:
  pipelines:
    logs:
      receivers: [journald]
      processors: [batch, resource]
      exporters: [otlphttp]
    metrics:
      receivers: [hostmetrics, prometheus]
      processors: [batch, resource]
      exporters: [otlphttp]
    traces:
      receivers: []
      processors: [batch, resource]
      exporters: [otlphttp]
EOF

# OpenTelemetry Collector service
cat > /etc/systemd/system/otelcol.service <<'EOF'
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
Type=simple
User=otelcol
Group=otelcol
EnvironmentFile=/etc/monitoring/config.env
ExecStart=/usr/local/bin/otelcol \
  --config=/etc/otelcol/config.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# Install Prometheus Node Exporter
# ============================================================================

log "Installing Prometheus Node Exporter..."
NODE_EXPORTER_VERSION="1.7.0"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

cd /tmp
curl -L -o node_exporter.tar.gz "${NODE_EXPORTER_URL}"
tar xzf node_exporter.tar.gz
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/node_exporter
chmod +x /usr/local/bin/node_exporter
rm -rf node_exporter.tar.gz node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

log "Prometheus Node Exporter installed and started on port 9100"

# ============================================================================
# Install OpenTelemetry Collector
# ============================================================================

log "Installing OpenTelemetry Collector (Contrib)..."
OTELCOL_VERSION="0.102.0"
OTELCOL_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz"

cd /tmp
curl -L -o otelcol.tar.gz "${OTELCOL_URL}"
tar xzf otelcol.tar.gz
cp otelcol-contrib /usr/local/bin/otelcol
chmod +x /usr/local/bin/otelcol
rm -f otelcol.tar.gz LICENSE README.md

# Create otelcol user
useradd -r -s /bin/false otelcol || true

# Source config and generate final config file
source /etc/monitoring/config.env
SIGNOZ_ENDPOINT=${SIGNOZ_ENDPOINT:-"http://signoz-server:4318"}

# Generate config file from template
cp /etc/otelcol/config.yaml.template /etc/otelcol/config.yaml

# Replace endpoint placeholder
sed -i "s|SIGNOZ_ENDPOINT_PLACEHOLDER|${SIGNOZ_ENDPOINT}|g" /etc/otelcol/config.yaml

# Handle API key header
if [ -n "$SIGNOZ_API_KEY" ]; then
    sed -i "s|SIGNOZ_HEADERS_PLACEHOLDER|signoz-api-key: \"${SIGNOZ_API_KEY}\"|g" /etc/otelcol/config.yaml
else
    sed -i "s|SIGNOZ_HEADERS_PLACEHOLDER||g" /etc/otelcol/config.yaml
fi

chown -R otelcol:otelcol /etc/otelcol
chmod 644 /etc/otelcol/config.yaml

systemctl daemon-reload
systemctl enable otelcol
systemctl start otelcol

log "OpenTelemetry Collector installed and started"
log "SigNoz endpoint configured: ${SIGNOZ_ENDPOINT}"

# ============================================================================
# Cleanup
# ============================================================================

log "Cleaning up..."
apt-get clean -qq
apt-get autoremove -y -qq

# ============================================================================
# Display Status
# ============================================================================

log "Setup complete! Displaying cluster status..."
echo ""
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes
echo ""
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n calico-system
echo ""

log "Checking monitoring services..."
systemctl status node_exporter --no-pager -l || true
echo ""
systemctl status otelcol --no-pager -l || true
echo ""

NODE_IP_ADDR=$(hostname -I | awk '{print $1}')
log "Node Exporter metrics available at: http://${NODE_IP_ADDR}:9100/metrics"

echo ""
log "==================================================================="
log "Single-node Kubernetes with Calico + WireGuard is ready!"
log "==================================================================="
echo ""
log "Cluster Status:"
echo "  - Use 'kubectl get nodes' to check node status"
echo "  - Use 'kubectl get pods -n calico-system' to check Calico pods"
echo "  - Join command saved to /root/join.sh for worker nodes"
echo ""
log "Monitoring Services:"
echo "  - Prometheus Node Exporter: Running on port 9100"
echo "    Metrics available at: http://${NODE_IP_ADDR}:9100/metrics"
echo "    Configure your Prometheus server to scrape this endpoint"
echo ""
echo "  - OpenTelemetry Collector: Running and collecting logs/metrics"
echo "    Configure SigNoz endpoint in: /etc/monitoring/config.env"
echo "    Current endpoint: Check /etc/monitoring/config.env"
echo "    Restart service after changes: systemctl restart otelcol"
echo ""
log "Next steps:"
echo "  1. Update /etc/monitoring/config.env with your SigNoz server URL"
echo "  2. Restart otelcol: systemctl restart otelcol"
echo "  3. Configure Prometheus to scrape node_exporter on port 9100"
echo "  4. Copy /root/join.sh to worker nodes"
echo "  5. Run the join command on worker nodes to add them to the cluster"
echo ""

