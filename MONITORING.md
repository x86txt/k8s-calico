# Monitoring Configuration Guide

This guide explains how to configure monitoring and logging for your Kubernetes cluster nodes.

## Overview

Each node is pre-configured with:
- **Prometheus Node Exporter**: Exposes node metrics on port 9100
- **OpenTelemetry Collector**: Collects logs and metrics, sends to SigNoz

## Configuration

### Prometheus Node Exporter

The Node Exporter is automatically installed and running. It exposes metrics on port **9100**.

**To configure Prometheus to scrape these metrics:**

Add this job to your Prometheus `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'kubernetes-nodes'
    static_configs:
      - targets:
        - 'node1-ip:9100'
        - 'node2-ip:9100'
        - 'node3-ip:9100'
    # Or use service discovery if you have DNS
    # - job_name: 'kubernetes-nodes'
    #   kubernetes_sd_configs:
    #     - role: node
    #   relabel_configs:
    #     - source_labels: [__address__]
    #       regex: '(.*):10250'
    #       replacement: '${1}:9100'
    #       target_label: __address__
```

**Verify Node Exporter is working:**
```bash
curl http://localhost:9100/metrics
```

### SigNoz OpenTelemetry Collector

The OpenTelemetry Collector collects:
- **Logs**: From systemd journal (journald)
- **Metrics**: Host metrics (CPU, memory, disk, network) and Prometheus metrics
- **Traces**: Ready for application traces (currently empty pipeline)

**Configuration file:** `/etc/monitoring/config.env`

**To configure SigNoz endpoint:**

1. Edit the configuration file:
   ```bash
   sudo nano /etc/monitoring/config.env
   ```

2. Update the `SIGNOZ_ENDPOINT` variable:
   ```bash
   SIGNOZ_ENDPOINT="http://your-signoz-server:4318"
   ```
   
   Or for gRPC:
   ```bash
   SIGNOZ_ENDPOINT="http://your-signoz-server:4317"
   ```

3. (Optional) Add API key if your SigNoz instance requires authentication:
   ```bash
   SIGNOZ_API_KEY="your-api-key-here"
   ```

4. Restart the collector:
   ```bash
   sudo systemctl restart otelcol
   ```

5. Check status:
   ```bash
   sudo systemctl status otelcol
   sudo journalctl -u otelcol -f
   ```

**SigNoz Endpoint Formats:**
- OTLP HTTP: `http://signoz-server:4318` (default)
- OTLP gRPC: `http://signoz-server:4317`
- With authentication: Add `SIGNOZ_API_KEY` to the config file

**What gets collected:**
- System logs from journald (all systemd services)
- Host metrics: CPU, memory, disk, network, load, processes
- Node Exporter metrics (scraped from localhost:9100)
- Kubelet metrics (if available on port 10255)

## Customization

### Adding Custom Log Sources

Edit `/etc/otelcol/config.yaml` and add filelog receivers:

```yaml
receivers:
  filelog:
    include:
      - /var/log/myapp/*.log
```

Then add to the logs pipeline in the `service` section.

### Adding Application Metrics

The collector already scrapes Prometheus metrics from:
- Node Exporter (localhost:9100)
- Kubelet (localhost:10255)

To add more Prometheus endpoints, edit `/etc/otelcol/config.yaml` and add to the prometheus receiver's scrape_configs.

## Troubleshooting

### Node Exporter not accessible
```bash
# Check if service is running
sudo systemctl status node_exporter

# Check if port is listening
sudo netstat -tlnp | grep 9100
# or
sudo ss -tlnp | grep 9100

# Check firewall rules
sudo ufw status
```

### OpenTelemetry Collector not sending data
```bash
# Check service status
sudo systemctl status otelcol

# View logs
sudo journalctl -u otelcol -n 100

# Verify configuration
sudo /usr/local/bin/otelcol --config=/etc/otelcol/config.yaml --dry-run

# Test connectivity to SigNoz
curl -v http://your-signoz-server:4318
```

### Logs not appearing in SigNoz
1. Verify journald is working: `sudo journalctl -n 50`
2. Check collector logs: `sudo journalctl -u otelcol -f`
3. Verify SigNoz endpoint is correct in `/etc/monitoring/config.env`
4. Ensure SigNoz is accessible from the node

## Service Management

**Prometheus Node Exporter:**
```bash
sudo systemctl start node_exporter
sudo systemctl stop node_exporter
sudo systemctl restart node_exporter
sudo systemctl status node_exporter
```

**OpenTelemetry Collector:**
```bash
sudo systemctl start otelcol
sudo systemctl stop otelcol
sudo systemctl restart otelcol
sudo systemctl status otelcol
```

## Updating Configuration

After modifying `/etc/monitoring/config.env` or `/etc/otelcol/config.yaml`:
1. Restart the affected service
2. Check logs for errors
3. Verify data is flowing to your monitoring stack

## Security Notes

- Node Exporter runs as `nobody` user (non-privileged)
- OpenTelemetry Collector runs as `otelcol` user (non-privileged)
- Both services bind to all interfaces (0.0.0.0) - consider firewall rules
- SigNoz communication uses insecure TLS by default - configure proper TLS for production

