# k8s-calico 🚀

Cloud-init configurations for spinning up Kubernetes clusters with Calico networking on Proxmox. Because manually configuring k8s nodes gets old fast.

## What's This?

Pre-configured cloud-init YAML files that turn a fresh Ubuntu VM into a fully-configured Kubernetes node in minutes. Perfect for lab environments where you need to deploy/destroy clusters frequently without the headache.

## What You Get

- ✅ **Kubernetes** (v1.34.0) with kubeadm
- ✅ **Calico CNI** with WireGuard encryption enabled
- ✅ **Prometheus Node Exporter** (port 9100) - ready for your Prometheus server
- ✅ **SigNoz OpenTelemetry Collector** - ships logs and metrics automatically
- ✅ **System optimizations** - swap disabled, kernel modules loaded, sysctls tuned
- ✅ **Zero-to-hero** - from VM creation to running cluster in ~5 minutes

## Quick Start

### Prerequisites

- Proxmox (or any cloud-init compatible hypervisor)
- Ubuntu 22.04+ VM template
- Your SSH public key (already configured in the files)

### Option 1: Full K8s Control Plane

Use `cloud-init/k8s-full-calico.yaml` for your first node (control plane):

1. Create a new VM in Proxmox
2. In the cloud-init tab, paste the contents of `k8s-full-calico.yaml`
3. Update the `SIGNOZ_ENDPOINT` in the monitoring config section (or edit `/etc/monitoring/config.env` after boot)
4. Boot the VM and grab a coffee ☕
5. SSH in and check status: `kubectl get nodes`

The join command is saved to `/root/join.sh` for adding worker nodes.

### Option 2: Bash Script (Alternative to Cloud-init)

If cloud-init isn't working or you prefer a script-based approach, use `setup-k8s.sh`:

**One-liner to download and execute:**

```bash
curl -fsSL https://your-server.com/setup-k8s.sh | sudo bash
```

Or download first, review, then execute:

```bash
curl -fsSL https://your-server.com/setup-k8s.sh -o setup-k8s.sh
sudo bash setup-k8s.sh
```

⚠️ **Security Note:** Always review scripts before executing, especially from remote sources.

### Option 3: Base Ubuntu Image

Use `cloud-init/base-ubuntu.yaml` to create a base template with common packages and your SSH key. Then clone and customize from there.

## Configuration

### Monitoring Endpoints

Both monitoring services are pre-configured but need your server URLs:

**SigNoz** (logs & metrics):

```bash
# Edit on the VM after creation
sudo nano /etc/monitoring/config.env
# Set SIGNOZ_ENDPOINT="http://your-signoz-server:4318"
sudo systemctl restart otelcol
```

**Prometheus** (metrics):
Just add a scrape job pointing to `node-ip:9100` in your Prometheus config. The Node Exporter is already running and waiting.

See [MONITORING.md](MONITORING.md) for detailed setup instructions.

## Files

- `cloud-init/k8s-full-calico.yaml` - Full Kubernetes + Calico + monitoring setup (cloud-init)
- `setup-k8s.sh` - Bash script alternative (same functionality as cloud-init)
- `cloud-init/base-ubuntu.yaml` - Base Ubuntu configuration for templates
- `MONITORING.md` - Monitoring configuration guide

## Customization

The configs are designed to be modified. Common tweaks:

- **Kubernetes version**: Change `kubernetesVersion` in the kubeadm config
- **Pod CIDR**: Update `podSubnet` (currently `192.168.0.0/16`)
- **Calico MTU**: Adjust in `calico-ip-pool.yaml` if needed
- **User/SSH keys**: Update the `users` section

## Notes

- This is optimized for **lab environments** - not production-hardened
- Control plane taint is removed (workloads can run on master)
- Swap is disabled (Kubernetes requirement)
- WireGuard is enabled for encrypted pod-to-pod communication
- All services auto-start on boot

## Troubleshooting

**Cluster not initializing?**

- Check `journalctl -u kubelet` for errors
- Verify containerd is running: `systemctl status containerd`
- Ensure swap is off: `swapoff -a`

**Monitoring not working?**

- Verify services: `systemctl status node_exporter otelcol`
- Check SigNoz endpoint in `/etc/monitoring/config.env`
- See [MONITORING.md](MONITORING.md) for detailed troubleshooting

## License

See [LICENSE](LICENSE) file.

---

**Pro tip:** Create a VM template from the base config, then clone it for faster node provisioning. Your future self will thank you. 🙏
