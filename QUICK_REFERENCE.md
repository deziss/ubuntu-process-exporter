# Quick Reference - Cgroup v1 & v2 Dual Support

## What Changed?

✅ **collector.sh**
- Now detects cgroup version automatically (v1 or v2)
- Detects container runtime (docker, containerd, kubernetes, podman, lxc, systemd, or host)
- Output: Added `cgroup_version` and `container_runtime` fields

✅ **collector.py**
- Updated to parse new 13-field TSV format (was 11 fields)
- ProcessMetric now includes `cgroup_version` field

✅ **exporter.py**
- Added `cgroup_version` to available Prometheus labels
- Can be included in INCLUDE_LABELS environment variable

✅ **validate.sh**
- Already supports both cgroup v1 and v2 (no changes needed)

---

## TSV Output Format (collector.sh)

**Old Format (11 fields):**
```
pid  user  cpu_pct  mem_pct  rss_kb  uptime_sec  command  disk_read  disk_write  ports  cgroup
```

**New Format (13 fields):**
```
pid  user  cpu_pct  mem_pct  rss_kb  uptime_sec  command  disk_read  disk_write  ports  cgroup_path  cgroup_version  container_runtime
```

**Example Output:**
```
1234  root  5.23   2.14   102400  3600  bash  1024  512  8080  /docker/abc123   v2  docker
5678  user  2.10   0.50   51200   7200  nginx  512   256  80    /libpod/def456   v1  podman
```

---

## Cgroup Version Detection

| System | Detection | Result |
|--------|-----------|--------|
| Ubuntu 24.04 | File: `/sys/fs/cgroup/cgroup.controllers` | **v2** ✅ |
| Ubuntu 20.04 | Dirs: `/sys/fs/cgroup/cpu`, `/sys/fs/cgroup/memory` | **v1** ⚠️ |
| Docker on v2 | Via cgroup path parsing | **v2** ✅ |
| Container on v1 | Via cgroup path parsing | **v1** ⚠️ |

---

## Container Runtime Detection

| Cgroup Path | Runtime Detected |
|-------------|-----------------|
| `/docker/abc123` | docker |
| `/cri-containerd-abc123` | containerd |
| `/kubepods/abc123` | kubernetes |
| `/libpod-abc123` | podman |
| `/lxc/container-name` | lxc |
| `/user.slice/session-1` | systemd |
| (none of above) | host |

---

## Using New Fields

### Option 1: Include in Prometheus Labels
```bash
docker-compose up -e INCLUDE_LABELS="pid,user,command,runtime,cgroup_version,container_id"
```

### Option 2: Query Raw Metrics
```bash
# See all fields
bash collector.sh | awk -F'\t' '{print $NF}' | head -5

# JSON format shows all fields
FORMAT=json bash collector.sh | jq '.[0]'
```

### Option 3: Filter by Cgroup Version
```bash
# Show only v2 processes
bash collector.sh | awk -F'\t' '$12=="v2"'

# Show only host processes
bash collector.sh | awk -F'\t' '$13=="host"'
```

---

## Backward Compatibility

⚠️ **BREAKING CHANGE**: TSV output now has 13 fields instead of 11

**Fix:**
- If your scripts parse collector.sh output, update field count from 11 to 13
- Or use JSON format: `FORMAT=json bash collector.sh`

**Example Fix:**
```bash
# Old (11 fields)
bash collector.sh | while IFS=$'\t' read pid user cpu mem rss time cmd dr dw ports cgroup; do
    echo "$pid $cmd $runtime"
done

# New (13 fields)
bash collector.sh | while IFS=$'\t' read pid user cpu mem rss time cmd dr dw ports cgroup_path cgroup_ver runtime; do
    echo "$pid $cmd $cgroup_ver $runtime"
done
```

---

## Testing

### Test 1: Validate cgroup detection
```bash
bash validate.sh
# Output should show cgroup version: v1, v2, or unknown
```

### Test 2: Collect data
```bash
bash collector.sh | head -1
# Count fields: should be 13 (separated by tabs)
bash collector.sh | awk -F'\t' '{print NF}' | sort | uniq
# Output: 13
```

### Test 3: Check cgroup version in output
```bash
bash collector.sh | cut -f12 | sort | uniq
# Output: v1, v2, or unknown
```

### Test 4: Check runtime detection
```bash
bash collector.sh | cut -f13 | sort | uniq
# Output: docker, containerd, host, etc.
```

### Test 5: Verify metrics labels
```bash
docker-compose up -d
sleep 5
curl http://localhost:9106/metrics | grep upm_process_top_memory | head -3
# Should show cgroup_version in labels if included in INCLUDE_LABELS
```

---

## Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Parse error: "expected 13 fields" | Old collector.sh | Update to latest collector.sh |
| cgroup_version="unknown" | /proc not mounted | Add `-v /proc:/host/proc:ro` |
| runtime="host" in container | /proc/PID/cgroup not readable | Ensure /proc is mounted as read-only |
| "Neither cgroup v2 nor v1" | Unusual cgroup setup | Check `mount \| grep cgroup` |

---

## Files Reference

| File | Changes | Lines |
|------|---------|-------|
| collector.sh | Dual cgroup detection + runtime extraction | 1-250 |
| collector.py | Parse 13 fields, add cgroup_version | 25-105 |
| exporter.py | Add cgroup_version label | 45-190 |
| validate.sh | Supports both v1 & v2 (no changes) | ✅ |
| COLLECTOR_UPDATES.md | Detailed changelog | Full guide |
| CGROUP_SUPPORT.md | Cgroup v1/v2 comparison | Migration guide |

---

## Environment Variables

```bash
# Cgroup
export CGROUP_DIR=/sys/fs/cgroup          # Default: /sys/fs/cgroup

# Process
export PROC_DIR=/proc                      # Default: /proc

# Collection
export TOP_N=50                            # Default: 50
export FORMAT=tsv                          # tsv or json
export ENABLE_DISK_IO=true                # Default: true

# Exporter
export METRICS_PORT=9106                   # Default: 9105
export INCLUDE_LABELS="pid,user,command,runtime,cgroup_version,container_id"
```

---

## Prometheus Query Examples

```promql
# Show memory usage by cgroup version
upm_process_top_memory_bytes{cgroup_version="v2"}

# Show processes by runtime
rate(upm_processes_scraped_total{runtime="docker"}[5m])

# Show where v1 processes still run
upm_process_top_cpu_percent{cgroup_version="v1"}

# Combined dashboard: v1 vs v2 breakdown
sum by (cgroup_version) (upm_process_top_memory_bytes)
```

---

## Next Steps

1. ✅ Update all three scripts (collector.sh, collector.py, exporter.py)
2. ✅ Test with `bash validate.sh` and `bash collector.sh`
3. ✅ Rebuild Docker image: `docker-compose up --build`
4. ✅ Verify metrics: `curl http://localhost:9106/metrics`
5. ⏳ Monitor both v1 and v2 processes if migrating systems
