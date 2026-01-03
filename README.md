# Cgroup- & Container-Aware Prometheus Process Exporter

This exporter collects process metrics from a Linux system, with awareness of cgroups and containers (Docker, containerd, Kubernetes, Podman, LXC, etc.).

## Features

- Top processes by memory, CPU, disk read/write
- Container detection and metadata extraction for multiple runtimes
- Cgroup v2 support
- UID and username inclusion
- Short command names (not full paths)
- IP/port information from network connections
- Dynamic label control via environment variables

## Architecture

- `collector.sh`: Shell script that gathers raw process data from `/proc`, `ps`, `ss`, and cgroup filesystems.
- `collector.py`: Python script that normalizes the data, detects container runtimes from cgroup paths, extracts container IDs, and resolves metadata.
- `exporter.py`: HTTP server that exposes Prometheus metrics for the top 20 processes by memory, CPU, disk read, and disk write.

Data flow:
1. `collector.sh` collects raw data.
2. `collector.py` processes and enriches with container info.
3. `exporter.py` aggregates top-N and serves metrics.

## Metrics

- `process_top_memory_bytes`: Top processes by memory usage
- `process_top_cpu_percent`: Top processes by CPU usage
- `process_top_disk_read_bytes`: Top processes by disk read
- `process_top_disk_write_bytes`: Top processes by disk write

## Labels

- `pid`: Process ID
- `uid`: User ID
- `user`: Username
- `command`: Short command name
- `runtime`: Runtime (host, docker, containerd, kubernetes, podman, lxc, etc.)
- `rank`: Rank in top list
- `port`: Port (if listening)
- `container_id`: Container ID
- `container_name`: Container name
- `hostname`: Hostname of the system
- `uptime`: Process uptime in seconds

## Configuration

### Dynamic Labels

Control which labels are included in metrics using the `INCLUDE_LABELS` environment variable.

- Set `INCLUDE_LABELS` to a comma-separated list of labels to include only those.
- If not set, all labels are included.

Example:
```bash
INCLUDE_LABELS=pid,command,container_name
```

This will only include pid, command, and container_name labels in the metrics, useful for selective scraping.

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

Available labels: pid, uid, user, command, runtime, rank, container_id, container_name, hostname, uptime

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

## Prometheus Configuration

Add the scrape config from `prometheus.yml` to your Prometheus config.