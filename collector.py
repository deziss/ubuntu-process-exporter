#!/usr/bin/env python3

import json
import subprocess
import socket
import sys
import os
import re
from dataclasses import dataclass, asdict
from typing import Optional, Dict, List
from functools import lru_cache
import time
import signal
from contextlib import contextmanager

# Config
TOP_N = int(os.getenv('TOP_N', '50'))
TIMEOUT_SEC = int(os.getenv('COLLECTOR_TIMEOUT', '30'))
ENABLE_DISK_IO = os.getenv('ENABLE_DISK_IO', 'true').lower() == 'true'

@dataclass
class ProcessMetric:
    pid: int
    uid: int
    user: str
    command: str
    cpu_pct: float
    mem_pct: float  # NEW: % memory
    mem_rss_kb: int
    disk_read_bytes: int
    disk_write_bytes: int
    ip: Optional[str]
    port: Optional[str]
    cgroup_path: str
    uptime_sec: int  # Renamed for Prometheus
    # Container/Orchestration
    runtime: str = "host"
    container_id: str = ""
    container_name: str = ""
    pod_name: str = ""
    namespace: str = ""
    # Ranking & Metadata
    rank: int = 0
    node_name: str = ""

# Timeout context for subprocess
@contextmanager
def timeout(seconds):
    def timeout_handler(signum, frame):
        raise TimeoutError("Collection timeout")
    old_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

def collect_data() -> List[ProcessMetric]:
    """Enhanced data collection with timeout, validation, TOP-N"""
    try:
        with timeout(TIMEOUT_SEC):
            result = subprocess.run(
                ['./collector.sh'], 
                capture_output=True, 
                text=True, 
                check=True,
                env={**os.environ, 'TOP_N': str(TOP_N), 'FORMAT': 'tsv'}
            )
        lines = result.stdout.strip().split('\n')
    except (subprocess.CalledProcessError, TimeoutError, FileNotFoundError) as e:
        print(f"Collector error: {e}", file=sys.stderr)
        return []

    processes = []
    for line_num, line in enumerate(lines, 1):
        line = line.strip()
        if not line:
            continue
        
        parts = line.split('\t')
        if len(parts) < 12:
            print(f"Line {line_num} invalid ({len(parts)} fields): {line}", file=sys.stderr)
            continue
            
        try:
            pid, uid, user, pcpu, pmem, rss, etimes, comm, disk_read, disk_write, ip, port, cgroup_path = parts[:13]
            pm = ProcessMetric(
                pid=int(pid),
                uid=int(uid),
                user=user.strip(),
                command=comm.strip(),
                cpu_pct=float(pcpu) or 0.0,
                mem_pct=float(pmem) or 0.0,  # NEW
                mem_rss_kb=int(rss),
                disk_read_bytes=int(disk_read),
                disk_write_bytes=int(disk_write),
                ip=ip.strip() or None,
                port=port.strip() or None,  # Empty → conditional label skip
                cgroup_path=cgroup_path.strip()[:500],  # Truncate
                uptime_sec=int(etimes),
                node_name=socket.gethostname()
            )
        except (ValueError, IndexError) as e:
            print(f"Line {line_num} parse error: {e}", file=sys.stderr)
            continue

        # Enhanced container detection
        pm.runtime = detect_runtime(pm.cgroup_path)
        pm.container_id = extract_container_id(pm.cgroup_path, pm.runtime)
        
        # Resolve metadata (cached)
        metadata = resolve_container_metadata(pm.container_id, pm.runtime)
        for k, v in metadata.items():
            setattr(pm, k, v)

        # Filter kernel threads, zombies
        if pm.command.startswith('[') or pm.pid == 0:
            continue
            
        processes.append(pm)

    return sorted(processes, key=lambda p: p.cpu_pct + p.mem_pct, reverse=True)[:TOP_N]

# ENHANCED: Multi-runtime container detection
def detect_runtime(cgroup_path: str) -> str:
    patterns = {
        'kubernetes': 'kubepods',
        'docker': 'docker',
        'containerd': 'cri-containerd|containerd',
        'podman': 'libpod',
        'lxc': 'lxc',
        'systemd': r'/user\.slice|/system\.slice'
    }
    for runtime, pattern in patterns.items():
        if re.search(pattern, cgroup_path):
            return runtime
    return 'host'

# ENHANCED: Robust ID extraction
def extract_container_id(cgroup_path: str, runtime: str) -> str:
    patterns = {
        'docker': [r'docker/([a-f0-9]{12,64})', r'docker-([a-f0-9]{12,})'],
        'containerd': [r'cri-containerd-([a-f0-9]{12,})'],
        'kubernetes': [r'cri-containerd-([a-f0-9]{12,})', r'docker-([a-f0-9]{12,})', r'kubepods/[^\s]+/pod[^\s]+/([a-f0-9]{12,})'],
        'podman': [r'libpod-([a-f0-9]{12,})'],
        'lxc': [r'lxc/([^/]+)']
    }
    
    if runtime in patterns:
        for pat in patterns[runtime]:
            match = re.search(pat, cgroup_path)
            if match:
                return match.group(1)[:12]
    return ''

# ENHANCED: Multi-runtime metadata (async-friendly)
@lru_cache(maxsize=1024)
def resolve_container_metadata(container_id: str, runtime: str) -> Dict[str, str]:
    if not container_id or runtime == 'host':
        return {'container_name': '', 'pod_name': '', 'namespace': ''}
    
    handlers = {
        'docker': lambda: _docker_metadata(container_id),
        'podman': lambda: _podman_metadata(container_id),
        'lxc': lambda: {'container_name': container_id, 'pod_name': '', 'namespace': ''}
    }
    
    return handlers.get(runtime, lambda: {})()

def _docker_metadata(cid: str) -> Dict[str, str]:
    for containers_dir in ['/var/lib/docker/containers', '/var/lib/docker/containers']:
        if os.path.exists(containers_dir):
            for d in os.listdir(containers_dir):
                if d.startswith(cid):
                    try:
                        with open(os.path.join(containers_dir, d, 'config.v2.json')) as f:
                            config = json.load(f)
                            return {'container_name': config.get('Name', '').lstrip('/')}
                    except:
                        pass
    return {}

def _podman_metadata(cid: str) -> Dict[str, str]:
    try:
        result = subprocess.run(['podman', 'inspect', cid, '--format=json'], 
                              capture_output=True, text=True, timeout=3)
        if result.returncode == 0:
            data = json.loads(result.stdout)[0]
            return {'container_name': data['Name']}
    except:
        pass
    return {}

# ENHANCED: Smart TOP-N aggregation
def get_top_n(processes: List[ProcessMetric], key_func, n: int = TOP_N) -> List[ProcessMetric]:
    """Composite ranking with deduplication"""
    top = sorted(processes, key=key_func, reverse=True)[:n]
    for rank, p in enumerate(top, 1):
        p.rank = rank
    return top

def aggregate_top(processes: List[ProcessMetric]) -> Dict[str, List[ProcessMetric]]:
    """Multi-metric TOP-N"""
    return {
        'memory': get_top_n(processes, lambda p: p.mem_rss_kb * (1 + p.mem_pct)),
        'cpu': get_top_n(processes, lambda p: p.cpu_pct),
        'disk_read': get_top_n(processes, lambda p: p.disk_read_bytes),
        'disk_write': get_top_n(processes, lambda p: p.disk_write_bytes),
        'combined': get_top_n(processes, lambda p: p.cpu_pct + p.mem_pct * 10)
    }

if __name__ == "__main__":
    processes = collect_data()
    print(json.dumps([asdict(p) for p in processes], default=str, indent=2))
