# Data Collection Updates - Cgroup v1 & v2 Dual Support

## Summary of Changes

### 1. **collector.sh** - Enhanced Cgroup Detection & Collection

**New Features:**

- Automatic cgroup v1 and v2 detection
- Separate cgroup version reporting
- Improved container runtime detection (docker, containerd, kubernetes, podman, lxc, systemd)
- TSV output now includes 3 new fields

**New Output Format (TSV):**

```
pid    user    cpu_pct    mem_pct    rss_kb    uptime_sec    command    disk_read    disk_write    ports    cgroup_path    cgroup_version    container_runtime
1234   root    5.23       2.14       102400    3600          bash       1024         512          8080     /docker/abc    v2                 docker
```

**Key Changes:**

- `parse_cgroup_path()` function now handles both v1 and v2 formats
  - v2: Single line format `0::/path/to/cgroup`
  - v1: Multiple lines, intelligently picks container-related paths
- Auto-detects cgroup version with `detect_cgroup_version()`
- Extracts `cgroup_version` and `container_runtime` from cgroup paths

---

### 2. **collector.py** - Updated Data Parsing

**Updated ProcessMetric Dataclass:**

```python
@dataclass
class ProcessMetric:
    # ... existing fields ...
    cgroup_version: str = "unknown"  # NEW: v1, v2, or unknown
```

**Updated Data Collection Logic:**

- Now expects 13 fields instead of 11 (backwards incompatible)
- Directly uses `cgroup_version` and `runtime` from collector.sh
- Reduced redundant detection code - shifts logic to shell script
- Still maintains backup `extract_container_id()` for metadata resolution

**TSV Parsing:**

```python
# Old: 11 fields
pid, user, pcpu, pmem, rss, etimes, comm, disk_read, disk_write, ports, cgroup_path = parts[:11]

# New: 13 fields
pid, user, pcpu, pmem, rss, etimes, comm, disk_read, disk_write, ports, cgroup_path, cgroup_version, runtime = parts[:13]
```

---

### 3. **exporter.py** - Enhanced Metrics & Labels

**Updated VALID_LABELS:**

- Added `cgroup_version` to available labels
- Can be included in INCLUDE_LABELS environment variable

**Updated labels_for() Function:**

- Now maps `cgroup_version` field from ProcessMetric
- Values: `"v1"`, `"v2"`, or `"unknown"`

**Usage Example:**

```bash
# Include cgroup_version in metrics labels
export INCLUDE_LABELS="pid,user,command,runtime,cgroup_version,container_id"

# Prometheus metric output:
upm_process_top_memory_bytes{pid="1234",user="root",command="bash",runtime="docker",cgroup_version="v2",container_id="abc123"} 102400
```

---

## Data Flow

```
collector.sh (detect cgroup version & runtime)
    ↓
    └─ parse_cgroup_path() → cgroup_path, cgroup_version, runtime
    ↓
collector.py (consume TSV output)
    ↓
    └─ ProcessMetric(cgroup_version="v1|v2", runtime="docker|host|...")
    ↓
exporter.py (expose Prometheus metrics)
    ↓
    └─ Labels include: cgroup_version, runtime, container_id, etc.
```

---

## Cgroup Version Detection

### In collector.sh:

```bash
detect_cgroup_version() {
    if [[ -f "$CGROUP_DIR/cgroup.controllers" ]]; then
        echo "v2"
    elif [[ -d "$CGROUP_DIR/cpu" ]] || [[ -d "$CGROUP_DIR/cpuacct" ]] || [[ -d "$CGROUP_DIR/memory" ]]; then
        echo "v1"
    else
        echo "unknown"
    fi
}
```

### Cgroup Path Parsing:

**Cgroup v2** (unified hierarchy):

```
Single line format: 0::/path/to/cgroup
Example: 0::/docker/abc123...
```

**Cgroup v1** (multiple hierarchies):

```
Format: hier:subsystems:path
Example:
7:devices:/docker/abc123
5:memory:/docker/abc123
5:cpu,cpuacct:/docker/abc123
```

---

## Backward Compatibility

⚠️ **Breaking Change**: collector.sh now outputs 13 fields instead of 11

**Migration Path:**

1. Update collector.sh to latest version
2. Update collector.py (parse 13 fields instead of 11)
3. Update exporter.py (add `cgroup_version` to labels)
4. Restart exporter container

If using standalone collector.sh:

- Ensure scripts expecting TSV output are updated to handle 3 new fields
- Add new fields to any parsing logic

---

## Testing

### Test collector.sh output:

```bash
bash collector.sh | head -2
# Output should have 13 tab-separated fields
```

### Test JSON format:

```bash
FORMAT=json bash collector.sh | jq '.[] | keys'
# Should include: cgroup_path, cgroup_version, container_runtime
```

### Test exporter metrics:

```bash
curl http://localhost:9106/metrics | grep upm_process
# Labels should include cgroup_version if configured
```

---

## Configuration

### Environment Variables:

| Variable         | Default          | Notes                                     |
| ---------------- | ---------------- | ----------------------------------------- |
| `CGROUP_DIR`     | `/sys/fs/cgroup` | Override if cgroups mounted elsewhere     |
| `PROC_DIR`       | `/proc`          | Process filesystem path                   |
| `TOP_N`          | `50`             | Number of top processes to collect        |
| `FORMAT`         | `tsv`            | Output format: `tsv` or `json`            |
| `INCLUDE_LABELS` | (all labels)     | Comma-separated list of labels to include |

### Example with cgroup_version label:

```bash
export INCLUDE_LABELS="pid,user,command,runtime,cgroup_version,container_id,ports"
export CGROUP_DIR=/sys/fs/cgroup
docker-compose up --build
```

---

## Metrics with Cgroup Version

Example Prometheus metrics:

```
# HELP upm_process_top_memory_bytes Top processes by RSS memory (bytes)
# TYPE upm_process_top_memory_bytes gauge
upm_process_top_memory_bytes{cgroup_version="v2",command="java",container_id="abc123",hostname="node1",pid="2345",ports="8080",runtime="docker",user="appuser"} 1.024e+09

upm_process_top_memory_bytes{cgroup_version="v1",command="nginx",hostname="node2",pid="1234",ports="80",runtime="host",user="www-data"} 1.048576e+08
```

---

## Troubleshooting

### "13 fields expected, got 11"

- Update collector.sh to latest version
- Ensure collector.py is updated
- Check: `bash collector.sh | head -1 | awk -F'\t' '{print NF}'` should output `13`

### cgroup_version shows "unknown"

- Check if /sys/fs/cgroup is accessible
- Verify cgroup mount: `mount | grep cgroup`
- May happen in restricted containers (use privileged: true in docker-compose)

### Runtime always shows "host"

- Ensure /proc/PID/cgroup is readable
- In Docker, mount /proc from host: `-v /proc:/host/proc:ro`
- Update PROC_DIR if /proc is mounted differently

---

## Files Modified

1. `/collector.sh` - Dual cgroup detection + runtime extraction
2. `/collector.py` - Handle 13 TSV fields, new ProcessMetric.cgroup_version
3. `/exporter.py` - Add cgroup_version to VALID_LABELS and labels_for()
4. `/validate.sh` - Already supports both cgroup v1 and v2 ✓

---

## Next Steps

- Monitor exporter output with: `curl http://localhost:9106/metrics`
- Verify cgroup version detection in logs
- Test with both cgroup v1 and v2 systems
- Update Prometheus scrape configs if adding new labels
