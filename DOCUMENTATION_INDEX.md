# Process Exporter - Documentation Index

## 📚 Complete Documentation Guide

Welcome to the process-exporter dual cgroup v1 & v2 support implementation! This file serves as a master index to help you navigate all documentation.

---

## 🚀 Quick Start

**New to this project?** Start here:
1. [README.md](README.md) - Project overview
2. [QUICK_REFERENCE.md](QUICK_REFERENCE.md) - 5-minute quick start
3. Run: `bash validate.sh`
4. Build: `docker-compose up --build`

---

## 📖 Documentation Files

### 1. [QUICK_REFERENCE.md](QUICK_REFERENCE.md) ⚡ **START HERE**
**5-minute quick lookup guide**
- What changed?
- TSV output format comparison
- Cgroup version detection table
- Container runtime detection table
- Testing commands
- Common issues & solutions
- Environment variables

**Best for:** Quick answers, troubleshooting, testing

---

### 2. [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) 📋 **OVERVIEW**
**High-level overview of all changes**
- Objective and completion status
- Files modified (5 files)
- Files created (4 files + 1 alternative docker-compose)
- Data flow diagram
- New features summary
- Testing checklist
- Breaking changes assessment
- Configuration examples

**Best for:** Understanding what was changed and why

---

### 3. [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md) 🔧 **TECHNICAL DETAILS**
**Comprehensive technical documentation**
- Summary of changes (file by file)
- Data flow explanation
- TSV output format (old vs new)
- Cgroup version detection logic
- Cgroup path parsing details
- Backward compatibility notes
- Configuration reference
- Troubleshooting guide
- File modification references

**Best for:** Developers, deep understanding, integration

---

### 4. [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md) 📊 **CGROUP GUIDE**
**Comprehensive cgroup v1 vs v2 guide**
- Cgroup v1 features & limitations
- Cgroup v2 features & benefits
- How to check which version your system uses
- Mount configurations (v1 & v2)
- Performance comparison table
- Upgrading from v1 to v2
- Container/Kubernetes specifics
- Troubleshooting cgroup issues
- Best practices

**Best for:** System administrators, cgroup comparison, upgrade planning

---

### 5. [CHANGELOG.md](CHANGELOG.md) 📝 **DETAILED CHANGELOG**
**Line-by-line change documentation**
- Version info
- Files changed and created
- Detailed modifications (by file)
- Feature additions
- Output format changes
- Prometheus metric examples
- Compatibility assessment
- Testing procedures
- Deployment checklist
- Rollback plan
- Future enhancements

**Best for:** Review before deployment, version history, rollback planning

---

### 6. [README.md](README.md) 📄 **PROJECT OVERVIEW**
**Original project documentation**
- Project description
- Features
- Architecture overview
- Available metrics
- Labels
- Usage instructions

**Best for:** Project background, features, architecture

---

## 🎯 Choose Your Path

### I want to...

#### ✅ **Deploy immediately**
1. Read [QUICK_REFERENCE.md](QUICK_REFERENCE.md) (5 min)
2. Run: `bash validate.sh`
3. Build: `docker-compose up --build`
4. Test: `curl http://localhost:9106/metrics`

#### ✅ **Understand what changed**
1. Read [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) (10 min)
2. Review [CHANGELOG.md](CHANGELOG.md) (10 min)
3. Check specific changes: [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md)

#### ✅ **Troubleshoot issues**
1. See "Common Issues" in [QUICK_REFERENCE.md](QUICK_REFERENCE.md)
2. Check "Troubleshooting" in [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md)
3. Review cgroup setup in [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md)

#### ✅ **Migrate from cgroup v1 to v2**
1. Read [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md) - Upgrade section
2. Plan migration in your environment
3. Test with test systems first
4. Monitor with Prometheus queries in [CHANGELOG.md](CHANGELOG.md)

#### ✅ **Integrate with other systems**
1. Read [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md) - Data Flow section
2. Check TSV/JSON format in [QUICK_REFERENCE.md](QUICK_REFERENCE.md)
3. Review field definitions in [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md)

#### ✅ **Understand cgroups**
1. Read [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md) - full guide
2. Learn detection methods
3. Understand performance differences
4. See troubleshooting examples

---

## 🔑 Key Concepts

### Cgroup Version
- **v2 (Unified)**: Modern, single hierarchy (Ubuntu 22.04+, Debian 12+)
- **v1 (Legacy)**: Multiple hierarchies, still supported (Ubuntu 20.04, Debian 11)
- **Detection**: Automatic via `/sys/fs/cgroup/cgroup.controllers`

### Container Runtime
- **docker**: Traditional Docker containers
- **containerd**: CRI container runtime (K8s)
- **kubernetes**: Orchestrated containers (kubepods)
- **podman**: Rootless containers (libpod)
- **lxc**: LXC system containers
- **systemd**: Systemd slices (user/system)
- **host**: No container (direct process)

### TSV Output Format
**Old (11 fields):**
```
pid user cpu_pct mem_pct rss_kb uptime_sec command disk_read disk_write ports cgroup
```

**New (13 fields):**
```
pid user cpu_pct mem_pct rss_kb uptime_sec command disk_read disk_write ports cgroup_path cgroup_version container_runtime
```

---

## 🛠️ Configuration

### Default Settings
```bash
CGROUP_DIR=/sys/fs/cgroup           # Cgroup mount point
PROC_DIR=/host/proc                  # Process filesystem
TOP_N=50                              # Top processes to collect
FORMAT=tsv                            # tsv or json
METRICS_PORT=9106                    # Exporter port
```

### Optional Labels for Prometheus
```bash
INCLUDE_LABELS="pid,user,command,runtime,cgroup_version,container_id,container_name,ports,hostname"
```

---

## 🧪 Testing & Validation

### Quick Tests
```bash
# Validate platform
bash validate.sh

# Collect data (TSV)
bash collector.sh | head -5

# Collect data (JSON)
FORMAT=json bash collector.sh | jq '.[0]'

# Verify field count
bash collector.sh | awk -F'\t' '{print NF}'  # Should output: 13

# Check cgroup detection
bash collector.sh | cut -f12 | sort | uniq  # Should show: v1, v2, unknown
```

---

## 📊 Prometheus Queries

### Monitor Cgroup Adoption
```promql
# View by cgroup version
sum by (cgroup_version) (upm_process_top_memory_bytes)

# View by runtime
sum by (runtime) (upm_processes_scraped_total)

# Track v1 vs v2 percentage
sum(upm_processes_scraped_total{cgroup_version="v2"}) / 
sum(upm_processes_scraped_total) * 100
```

---

## 🔄 Files Modified

| File | Status | Type | Impact |
|------|--------|------|--------|
| [collector.sh](collector.sh) | Enhanced | Bash | +60 lines, 2 new functions |
| [collector.py](collector.py) | Updated | Python | +1 field, 13-field parsing |
| [exporter.py](exporter.py) | Updated | Python | +1 label |
| [validate.sh](validate.sh) | ✓ OK | Bash | No changes |
| [docker-compose.yml](docker-compose.yml) | Fixed | YAML | Uncommented cgroup mount |
| [docker-compose.cgroup-v1.yml](docker-compose.cgroup-v1.yml) | New | YAML | Alternative for v1 systems |

---

## ⚠️ Breaking Changes

**TSV Output Format:** 11 → 13 fields
- Scripts parsing `collector.sh` output must be updated
- JSON format remains backward compatible

**No other breaking changes:**
- Prometheus labels are optional
- Metrics format unchanged
- Environment variables have defaults

---

## 🚀 Deployment Steps

1. **Update code**
   ```bash
   cd /home/anshukushwaha/Desktop/learn/process-exporter
   git pull  # or update manually
   ```

2. **Validate**
   ```bash
   bash validate.sh
   bash -n collector.sh
   bash -n validate.sh
   python3 -m py_compile collector.py exporter.py
   ```

3. **Build Docker**
   ```bash
   docker-compose up --build
   ```

4. **Verify**
   ```bash
   sleep 10
   curl http://localhost:9106/metrics | head -20
   ```

5. **Monitor**
   ```bash
   # Watch logs
   docker-compose logs -f ubuntu-process-exporter
   
   # Check metrics
   curl http://localhost:9106/metrics | grep upm_process
   ```

---

## 📞 Support

### If you encounter issues:

1. **Check [QUICK_REFERENCE.md](QUICK_REFERENCE.md)**
   - "Common Issues" section
   - Troubleshooting table

2. **Check [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md)**
   - "Troubleshooting" section
   - Technical details

3. **Check [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md)**
   - Cgroup-related issues
   - System configuration

4. **Run diagnostic commands:**
   ```bash
   # Show cgroup version
   bash validate.sh
   
   # Show collector output
   bash collector.sh | head -3
   
   # Check Docker logs
   docker-compose logs
   ```

---

## 📈 Performance

- **Startup:** < 1 second overhead
- **Collection:** Same as before (no regression)
- **Memory:** Negligible increase
- **CPU:** Negligible increase
- **Disk:** Only in cgroup path strings (truncated to 300 chars)

---

## 🎓 Learning Resources

- **For Bash:** collector.sh functions
  - `detect_cgroup_version()` - Cgroup detection
  - `parse_cgroup_path()` - Cgroup path parsing

- **For Python:** collector.py
  - `ProcessMetric` dataclass - Data structure
  - `collect_data()` - Data collection pipeline

- **For Cgroups:** CGROUP_SUPPORT.md
  - Detailed cgroup v1 vs v2 comparison
  - System upgrade guide
  - Performance impact analysis

---

## 🔄 Version History

- **Current:** Dual cgroup v1 & v2 support
- **Previous:** Cgroup v2 only
- **Breaking:** TSV field count (11 → 13)

---

## 📅 Last Updated

**January 22, 2026**

---

## 📋 Quick Links

- [README.md](README.md) - Project overview
- [QUICK_REFERENCE.md](QUICK_REFERENCE.md) - Quick answers
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - What changed
- [COLLECTOR_UPDATES.md](COLLECTOR_UPDATES.md) - Technical details
- [CGROUP_SUPPORT.md](CGROUP_SUPPORT.md) - Cgroup guide
- [CHANGELOG.md](CHANGELOG.md) - Detailed changelog

---

## 🎯 Next Steps

Choose one:
1. **Deploy**: Follow Quick Start above
2. **Learn**: Read IMPLEMENTATION_SUMMARY.md
3. **Troubleshoot**: Check QUICK_REFERENCE.md issues section
4. **Understand Cgroups**: Read CGROUP_SUPPORT.md
5. **Deep Dive**: Read COLLECTOR_UPDATES.md

---

**Happy monitoring! 🎉**
