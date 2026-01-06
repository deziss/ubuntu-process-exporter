# UPM Exporter — Unified Process Metrics Exporter

A production-ready Prometheus exporter that collects process metrics from Linux systems with full awareness of cgroups and containers (Docker, containerd, Kubernetes, Podman, LXC, etc.).

## Features

- **Top-N Process Tracking**: Configurable top processes by memory, CPU, disk read/write
- **Multi-Runtime Container Detection**: Automatic detection and metadata extraction for Docker, Kubernetes, containerd, Podman, LXC
- **Cgroup v2 Support**: Full support for modern cgroup v2 unified hierarchy
- **Robust Label Handling**: Intelligent label normalization with typo correction (e.g., `port` → `ports`)
- **Dynamic Label Control**: Fine-grained control over which labels are included in metrics
- **Network Information**: IP/port information from active network connections
- **Production Ready**: Read-only filesystem support, health checks, graceful shutdown

## Architecture

- `collector.sh`: Shell script that gathers raw process data from `/proc`, `ps`, `ss`, and cgroup filesystems.
- `collector.py`: Python script that normalizes the data, detects container runtimes from cgroup paths, extracts container IDs, and resolves metadata.
- `exporter.py`: HTTP server that exposes Prometheus metrics for the top 20 processes by memory, CPU, disk read, and disk write.

Data flow:
1. `collector.sh` collects raw data.
2. `collector.py` processes and enriches with container info.
3. `exporter.py` aggregates top-N and serves metrics.

## Metrics

All metrics use the `upm_` prefix (Unified Process Metrics):

- `upm_process_top_memory_bytes`: Top processes by RSS memory usage (bytes)
- `upm_process_top_memory_percent`: Top processes by memory percentage
- `upm_process_top_cpu_percent`: Top processes by CPU usage (%)
- `upm_process_top_disk_read_bytes`: Top processes by disk read (bytes)
- `upm_process_top_disk_write_bytes`: Top processes by disk write (bytes)
- `upm_process_uptime_seconds`: Process uptime in seconds
- `upm_processes_scraped_total`: Total processes scraped by runtime
- `upm_scrape_duration_seconds`: Time spent collecting metrics (histogram)
- `upm_scrape_errors_total`: Total scrape errors (counter)

## Labels

Available labels (all optional via `INCLUDE_LABELS`):

- `pid`: Process ID
- `user`: Username
- `command`: Short command name (truncated to 64 chars)
- `runtime`: Runtime (host, docker, containerd, kubernetes, podman, lxc, systemd)
- `rank`: Rank in top-N list (1-based)
- `ports`: Network ports (if listening)
- `container_id`: Container ID (first 12 chars)
- `container_name`: Container name (truncated to 64 chars)
- `pod_name`: Kubernetes pod name (truncated to 64 chars)
- `namespace`: Kubernetes namespace (truncated to 64 chars)
- `hostname`: Hostname of the system

**Label Normalization**: The exporter automatically normalizes common variations:
- `port` → `ports`
- `host` → `hostname`
- `container` → `container_name`
- `pod` → `pod_name`
- `ns` → `namespace`

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `METRICS_PORT` | `9105` | Port for metrics endpoint |
| `SCRAPE_TIMEOUT` | `30` | Timeout for metrics collection (seconds) |
| `TOP_N` | `50` | Number of top processes to track (⚠️ higher values slow scraping) |
| `ENABLE_DISK_IO` | `true` | Enable disk I/O metrics collection |
| `INCLUDE_LABELS` | All labels | Comma-separated list of labels to include |
| `PROC_DIR` | `/proc` | Path to proc filesystem |

### Dynamic Labels

Control which labels are included in metrics using the `INCLUDE_LABELS` environment variable.

**Default (all labels)**:
```bash
INCLUDE_LABELS=pid,user,command,runtime,rank,container_id,container_name,pod_name,namespace,ports,hostname
```

**Minimal (reduced cardinality)**:
```bash
INCLUDE_LABELS=pid,command,container_name,runtime,hostname
```

**Label Normalization**: Common typos are automatically corrected:
- Using `port` instead of `ports`? ✅ Auto-corrected
- Using `host` instead of `hostname`? ✅ Auto-corrected
- Invalid labels? ⚠️ Logged as warnings and ignored

#### Adding/Removing Labels with Docker

To include only specific labels, add the `-e INCLUDE_LABELS=...` flag to your `docker run` command:

```bash
# Include only pid and command
docker run -d --name process-exporter \
  --privileged \
  --pid=host \
  -p 9105:9105 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v /proc:/host/proc:ro \
  -e PROC_DIR=/host/proc \
  -e CGROUP_DIR=/sys/fs/cgroup \
  -e INCLUDE_LABELS=pid,command \
  process-exporter
```

To include all labels (default), omit the `INCLUDE_LABELS` environment variable.

Available labels: `pid`, `user`, `command`, `runtime`, `rank`, `container_id`, `container_name`, `pod_name`, `namespace`, `ports`, `hostname`

## Docker Deployment

Build the image:
```bash
docker build -t process-exporter .
```

Run with docker-compose:
```bash
docker-compose up -d
```

Or run manually:
```bash
docker run -d --name process-exporter \
  --privileged \
  --pid=host \
  -p 9105:9105 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v /proc:/host/proc:ro \
  -e PROC_DIR=/host/proc \
  -e CGROUP_DIR=/sys/fs/cgroup \
  process-exporter
```

## Installation (Native)

1. Ensure Ubuntu 22.04+ or Debian with cgroup v2.
2. Install dependencies: `pip install -r requirements.txt`
3. Make scripts executable: `chmod +x collector.sh validate.sh`
4. Run validation: `./validate.sh`

## Usage

- Run collector: `python3 collector.py`
- Run exporter: `python3 exporter.py [port]`

## Systemd Integration

Copy `process-exporter.service` to `/etc/systemd/system/`, adjust paths, create user, enable and start.

## Production Deployment

For production use, see `docker-compose.prod.yml`:

```yaml
services:
  ubuntu-process-exporter:
    image: deziss/ubuntu-process-exporter:v0.2.1
    privileged: true
    pid: host
    network_mode: host
    read_only: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
      - /proc:/host/proc:ro
      - /etc/hostname:/host/etc/hostname:ro
      - /disk1/docker/containers:/var/lib/docker/containers:ro
      - upm-cache:/tmp/upm
    environment:
      METRICS_PORT: "9105"
      TOP_N: "25"
      INCLUDE_LABELS: "pid,user,command,runtime,container_id,container_name,ports,hostname"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:9105/health"]
      interval: 30s
      timeout: 5s
      retries: 3
```

## Prometheus Configuration

Add to your Prometheus `scrape_configs`:

```yaml
scrape_configs:
  - job_name: 'process-exporter'
    static_configs:
      - targets: ['localhost:9105']
    scrape_interval: 30s
    scrape_timeout: 10s
```

## Troubleshooting

### "Incorrect label names" Error

**Symptom**: HTTP 500 error with `ValueError: Incorrect label names`

**Cause**: Mismatch between configured labels and actual label names

**Solution**: The exporter now automatically normalizes common variations. Check startup logs:
```bash
docker logs <container-name> | grep "Labels (normalized)"
```

If you see warnings about invalid labels, update your `INCLUDE_LABELS` to use correct names.

### High Cardinality

**Symptom**: Prometheus performance issues, high memory usage

**Solution**: Reduce label cardinality by limiting `INCLUDE_LABELS`:
```bash
INCLUDE_LABELS=pid,command,runtime,hostname  # Minimal set
```

Also reduce `TOP_N` to track fewer processes:
```bash
TOP_N=10  # Track only top 10 processes
```

### Slow Scraping

**Symptom**: Scrapes timing out or taking too long

**Causes**:
- `TOP_N` too high (each additional process adds overhead)
- `ENABLE_DISK_IO=true` on systems with many processes

**Solutions**:
```bash
TOP_N=15                    # Reduce tracked processes
SCRAPE_TIMEOUT=60          # Increase timeout
ENABLE_DISK_IO=false       # Disable disk I/O if not needed
```

## Health Endpoints

- `/metrics` - Prometheus metrics
- `/health` - Health check (returns `OK`)
- `/ready` - Readiness check (returns `OK`)