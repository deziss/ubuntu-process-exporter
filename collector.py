#!/usr/bin/env python3
"""
Ultra-Optimized Process Collector

v0.3.2 - Maximum Performance:
- Minimal parsing overhead
- No container metadata resolution (shell handles it)
- Direct attribute assignment
- Simplified data structures
"""

import subprocess
import sys
import os
import signal
from dataclasses import dataclass
from typing import List, Dict
from contextlib import contextmanager

# Config
TOP_N = int(os.getenv('TOP_N', '50'))
TIMEOUT_SEC = int(os.getenv('COLLECTOR_TIMEOUT', '30'))

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
    pod_name: str = ""

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
            processes.append(ProcessMetric(
                pid=int(parts[0]),
                user=parts[1],
                command=parts[6],
                cpu_pct=float(parts[2]) if parts[2] else 0.0,
                mem_pct=float(parts[3]) if parts[3] else 0.0,
                mem_rss_kb=int(parts[4]) if parts[4] else 0,
                disk_read_bytes=int(parts[7]) if parts[7] else 0,
                disk_write_bytes=int(parts[8]) if parts[8] else 0,
                ports=parts[9] or "",
                cgroup_path=parts[10][:300] if parts[10] else "/",
                uptime_sec=int(parts[5]) if parts[5] else 0,
                runtime=parts[11] or "host",
            ))
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
