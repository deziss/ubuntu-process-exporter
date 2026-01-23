#!/usr/bin/env python3
"""
Ultra-Optimized Process Collector

v0.4.2 - Field Fixes:
- Empty string for missing ports
- Empty string for missing cgroup_path (not "/")
- Proper field ordering
"""

import subprocess
import sys
import os
import signal
import re
from dataclasses import dataclass
from typing import List, Dict
from contextlib import contextmanager

# Config
TOP_N = int(os.getenv('TOP_N', '50'))
TIMEOUT_SEC = int(os.getenv('COLLECTOR_TIMEOUT', '30'))

# Pre-compiled regex for container extraction
# Capture ID from common patterns
RE_CONTAINER_ID = re.compile(r'([0-9a-fA-F]{64}|[0-9a-fA-F]{12})')

@dataclass(slots=True)
class ProcessMetric:
    """Minimal process metrics with __slots__"""
    pid: int
    user: str
    command: str
    cpu_pct: float
    mem_pct: float
    mem_rss_kb: int
    disk_read_bytes: int
    disk_write_bytes: int
    ports: str
    cgroup_path: str
    uptime_sec: int
    runtime: str
    container_id: str = ""
    container_name: str = ""

@contextmanager
def timeout(seconds: int):
    """Timeout context for subprocess"""
    def handler(signum, frame):
        raise TimeoutError("Collection timeout")
    old = signal.signal(signal.SIGALRM, handler)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)

def extract_metadata(cgroup_path: str, runtime: str) -> tuple[str, str]:
    """Efficiently extract container ID and Name from cgroup path"""
    if runtime == "host" or not cgroup_path or cgroup_path == "/":
        return "", ""
    
    # Fast extraction logic
    cid = ""
    name = ""
    
    # 1. Try to find container ID using common patterns (fastest)
    match = RE_CONTAINER_ID.search(cgroup_path)
    if match:
        cid = match.group(1)[:12]  # Short ID
    
    # 2. Heuristic for name
    # Systemd/Crio often put name in .scope or directory names
    # e.g. /system.slice/docker-CONTAINERNAME.scope
    # or /.../kubepods/.../podID/containerID
    
    # If we have a CID, check if there's a readable name elsewhere
    # For now, we will fallback name to CID unless we see distinct scope
    name = cid
    
    # K8s Special Case: Try to find pod name or container name logic if needed
    # But for "Option B" speed, just getting the ID is 90% of value
    
    return cid, name

def collect_data() -> List[ProcessMetric]:
    """Fast data collection with minimal overhead"""
    try:
        with timeout(TIMEOUT_SEC):
            result = subprocess.run(
                ['./collector.sh'],
                capture_output=True,
                text=True,
                check=True,
                env={**os.environ, 'TOP_N': str(TOP_N), 'FORMAT': 'tsv'}
            )
    except (subprocess.CalledProcessError, TimeoutError, FileNotFoundError) as e:
        print(f"Collector error: {e}", file=sys.stderr)
        return []

    processes: List[ProcessMetric] = []
    
    for line in result.stdout.splitlines():
        if not line:
            continue
        
        parts = line.split('\t')
        if len(parts) < 12:
            continue
        
        try:
            # Parse basic fields
            # Output: pid, user, cpu_pct, mem_pct, rss_kb, uptime_sec, comm, rd, wr, ports, cgroup_path, runtime
            pm = ProcessMetric(
                pid=int(parts[0]),
                user=parts[1] or "",
                command=parts[6] or "",
                cpu_pct=float(parts[2]) if parts[2] else 0.0,
                mem_pct=float(parts[3]) if parts[3] else 0.0,
                mem_rss_kb=int(parts[4]) if parts[4] else 0,
                disk_read_bytes=int(parts[7]) if parts[7] else 0,
                disk_write_bytes=int(parts[8]) if parts[8] else 0,
                ports=parts[9] if parts[9] and parts[9] != "/" else "",
                cgroup_path=parts[10][:300] if parts[10] and parts[10] != "/" else "",
                uptime_sec=int(parts[5]) if parts[5] else 0,
                runtime=parts[11] if parts[11] else "host",
            )
            
            # Enrich with Metadata (Option B)
            if pm.runtime != "host":
                pm.container_id, pm.container_name = extract_metadata(pm.cgroup_path, pm.runtime)
                
            processes.append(pm)
            
        except (ValueError, IndexError):
            continue

    return processes

def aggregate_top(processes: List[ProcessMetric]) -> Dict[str, List[ProcessMetric]]:
    """Multi-metric TOP-N aggregation"""
    n = TOP_N
    
    return {
        'cpu': sorted(processes, key=lambda p: p.cpu_pct, reverse=True)[:n],
        'memory': sorted(processes, key=lambda p: p.mem_rss_kb, reverse=True)[:n],
        'disk_read': sorted(processes, key=lambda p: p.disk_read_bytes, reverse=True)[:n],
        'disk_write': sorted(processes, key=lambda p: p.disk_write_bytes, reverse=True)[:n],
    }

if __name__ == "__main__":
    import json
    from dataclasses import asdict
    procs = collect_data()
    print(json.dumps([asdict(p) for p in procs], indent=2))
