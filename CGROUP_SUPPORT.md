# Cgroup Support Guide

## Cgroup v2 (Recommended)
**Status**: ✅ Full support with enhanced container detection

### Features:
- Unified hierarchy across all subsystems
- Full container detection (Docker, containerd, Kubernetes, Podman, LXC)
- Modern and recommended by Linux community
- Required for Ubuntu 22.04+ best practices

### Mount Configuration:
```bash
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:ro
```

### Check if cgroup v2 is enabled:
```bash
ls -la /sys/fs/cgroup/cgroup.controllers
```

---

## Cgroup v1 (Legacy)
**Status**: ⚠️ Partial support - container detection limited

### Features:
- Multiple hierarchies (one per subsystem)
- Basic process metrics collection
- Reduced container runtime detection accuracy
- Still functional for basic monitoring

### Mount Configuration:
For cgroup v1-only systems, mount individual subsystems:

```yaml
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:ro
  # OR separately:
  - /sys/fs/cgroup/cpu:/sys/fs/cgroup/cpu:ro
  - /sys/fs/cgroup/memory:/sys/fs/cgroup/memory:ro
  - /sys/fs/cgroup/cpuacct:/sys/fs/cgroup/cpuacct:ro
```

### Check if cgroup v1 is enabled:
```bash
ls /sys/fs/cgroup/
# Should show: cpu, memory, cpuacct, cpuset, pids, etc.

# Verify docker detection in v1:
cat /proc/1/cgroup | grep docker
```

---

## How to Check Your System

### Method 1: Check mounted cgroup version
```bash
mount | grep cgroup
```

**Cgroup v2 output:**
```
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate)
```

**Cgroup v1 output:**
```
cgroup on /sys/fs/cgroup/systemd type cgroup (rw,nosuid,nodev,noexec,relatime,name=systemd)
cgroup on /sys/fs/cgroup/memory type cgroup (rw,nosuid,nodev,noexec,relatime,memory)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpu,cpuacct)
...
```

### Method 2: Check kernel parameter
```bash
cat /proc/cmdline | grep cgroup
```

Look for `cgroup2_only=1` or `systemd.unified_cgroup_hierarchy=1`

### Method 3: Kernel version check
```bash
uname -r
```
- **Ubuntu 22.04+**: Likely cgroup v2
- **Ubuntu 20.04**: Cgroup v1 (default)
- **Debian 11+**: Check boot parameters

---

## Performance Differences

| Feature | Cgroup v2 | Cgroup v1 |
|---------|-----------|-----------|
| Container Detection | ✅ Excellent | ⚠️ Good |
| Memory Metrics | ✅ Accurate | ✅ Accurate |
| CPU Metrics | ✅ Accurate | ✅ Accurate |
| Disk I/O | ✅ Full support | ✅ Full support |
| Latency | ✅ Lower | ⚠️ Slightly higher |

---

## Upgrading from Cgroup v1 to Cgroup v2

### Option 1: Kernel Parameter (Ubuntu 22.04+)
Edit `/etc/default/grub`:
```bash
GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1"
```

Then:
```bash
sudo update-grub
sudo reboot
```

### Option 2: Container/Kubernetes
Docker automatically detects the host's cgroup version. For Kubernetes, ensure kubelet is configured with:
```bash
--cgroup-driver=systemd
```

---

## Validation Script Behavior

The `validate.sh` script now supports both versions:

### Cgroup v2 System
```
Validating platform...
OS: debian 13
/proc is accessible.
cgroup v2 unified hierarchy detected.
Platform validation successful.
```

### Cgroup v1 System
```
Validating platform...
OS: debian 13
/proc is accessible.
cgroup v1 hierarchy detected. (Limited container detection, recommend upgrading to cgroup v2)
Platform validation successful.
```

---

## Troubleshooting

### Error: "cgroup not found"
```bash
# Ensure cgroup is mounted
mount | grep cgroup

# If not mounted (rare):
sudo mount -t cgroup2 cgroup2 /sys/fs/cgroup
```

### Container detection not working in cgroup v1
1. Verify `/proc/PID/cgroup` shows docker/container references
2. Ensure docker socket is mounted: `-v /var/run/docker.sock:/var/run/docker.sock`
3. Runtime detection may show `host` instead of `docker` - this is expected

### Docker can't see host metrics
Ensure all required volumes are mounted:
```yaml
volumes:
  - /proc:/host/proc:ro
  - /sys/fs/cgroup:/sys/fs/cgroup:ro  # Both v1 and v2
  - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

---

## Best Practices

1. **Prefer cgroup v2** on Ubuntu 22.04+ and Debian 12+
2. **Upgrade gradually** - cgroup v1 is still supported
3. **Mount both** - Single `/sys/fs/cgroup` works for both
4. **Monitor metrics** - Use `TOP_N` wisely to balance accuracy vs performance
5. **Enable health checks** - Docker health checks catch startup failures early
