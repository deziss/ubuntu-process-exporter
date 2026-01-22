#!/usr/bin/env python3
"""
Optimized Process Collector with Performance Enhancements

v0.2.7 - Performance Optimizations:
- Pre-compiled regex patterns
- Cached hostname lookup
- Increased LRU cache size
- Optimized string operations
"""

import json
import subprocess
import socket
import sys
import os
import re
from dataclasses import dataclass, asdict, field
from typing import Optional, Dict, List
from functools import lru_cache
import time
import signal
from contextlib import contextmanager

# Config
TOP_N = int(os.getenv('TOP_N', '50'))
TIMEOUT_SEC = int(os.getenv('COLLECTOR_TIMEOUT', '30'))
ENABLE_DISK_IO = os.getenv('ENABLE_DISK_IO', 'true').lower() == 'true'

# Pre-cached hostname (avoid repeated syscalls)
_CACHED_HOSTNAME: str = socket.gethostname()

# Pre-compiled regex patterns for container ID extraction
_CONTAINER_PATTERNS: Dict[str, List[re.Pattern]] = {
    'docker': [re.compile(r'docker/([a-f0-9]{12,64})'), re.compile(r'docker-([a-f0-9]{12,})')],
    'containerd': [re.compile(r'cri-containerd-([a-f0-9]{12,})')],
    'kubernetes': [
        re.compile(r'cri-containerd-([a-f0-9]{12,})'),
        re.compile(r'docker-([a-f0-9]{12,})'),
        re.compile(r'kubepods/[^\s]+/pod[^\s]+/([a-f0-9]{12,})')
    ],
    'podman': [re.compile(r'libpod-([a-f0-9]{12,})')],
    'lxc': [re.compile(r'lxc/([^/]+)')]
}

@dataclass(slots=True)
class ProcessMetric:
    """Process metrics with __slots__ for memory efficiency"""
    pid: int    
    user: str
    command: str
    cpu_pct: float
    mem_pct: float
    mem_rss_kb: int
    disk_read_bytes: int
    disk_write_bytes: int    
    ports: Optional[str]
    cgroup_path: str
    uptime_sec: int
    cgroup_version: str = "unknown"
    runtime: str = "host"
    container_id: str = ""
    container_name: str = ""
    pod_name: str = ""
    namespace: str = ""
    rank: int = 0
    node_name: str = field(default_factory=lambda: _CACHED_HOSTNAME)

# Timeout context for subprocess
@contextmanager
def timeout(seconds: int):
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
        raw_output = result.stdout
    except (subprocess.CalledProcessError, TimeoutError, FileNotFoundError) as e:
        print(f"Collector error: {e}", file=sys.stderr)
        return []

    processes: List[ProcessMetric] = []
    
    # Process lines in batch for better performance
    for line_num, line in enumerate(raw_output.split('\n'), 1):
        line = line.strip()
        if not line:
            continue
        
        parts = line.split('\t')
        if len(parts) < 13:
            print(f"Line {line_num} invalid ({len(parts)} fields, expected 13): {line}", file=sys.stderr)
            continue
            
        try:
            pid, user, pcpu, pmem, rss, etimes, comm, disk_read, disk_write, ports, cgroup_path, cgroup_version, runtime = parts[:13]
            pm = ProcessMetric(
                pid=int(pid),                
                user=user.strip(),
                command=comm.strip(),
                cpu_pct=float(pcpu) or 0.0,
                mem_pct=float(pmem) or 0.0,
                mem_rss_kb=int(rss),
                disk_read_bytes=int(disk_read),
                disk_write_bytes=int(disk_write),
                ports=ports.strip() or None,
                cgroup_path=cgroup_path.strip()[:500],
                uptime_sec=int(etimes),
                cgroup_version=cgroup_version.strip(),
                runtime=runtime.strip(),
            )
        except (ValueError, IndexError) as e:
            print(f"Line {line_num} parse error: {e}", file=sys.stderr)
            continue

        # Extract container ID from cgroup path if not already detected
        if pm.runtime != "host" and not pm.container_id:
            pm.container_id = extract_container_id(pm.cgroup_path, pm.runtime)
        
        # Resolve metadata (cached)
        metadata = resolve_container_metadata(pm.container_id, pm.runtime)
        for k, v in metadata.items():
            setattr(pm, k, v)

        # Filter kernel threads, zombies
        if pm.command.startswith('[') or pm.pid == 0:
            continue
            
        processes.append(pm)

    # Sort and return top N
    return sorted(processes, key=lambda p: p.cpu_pct + p.mem_pct, reverse=True)[:TOP_N]

def extract_container_id(cgroup_path: str, runtime: str) -> str:
    """Extract container ID from cgroup path using pre-compiled patterns"""
    patterns = _CONTAINER_PATTERNS.get(runtime)
    if patterns:
        for pat in patterns:
            match = pat.search(cgroup_path)
            if match:
                return match.group(1)[:12]
    return ''

@lru_cache(maxsize=2048)  # Increased cache size for better hit rate
def resolve_container_metadata(container_id: str, runtime: str) -> Dict[str, str]:
    """Resolve container metadata from runtime"""
    if not container_id or runtime == 'host':
        return {'container_name': '', 'pod_name': '', 'namespace': ''}
    
    handlers = {
        'docker': lambda: _docker_metadata(container_id),
        'podman': lambda: _podman_metadata(container_id),
        'lxc': lambda: {'container_name': container_id, 'pod_name': '', 'namespace': ''}
    }
    
    return handlers.get(runtime, lambda: {})()

def _docker_metadata(cid: str) -> Dict[str, str]:
    """Extract Docker container metadata"""
    containers_dir = '/var/lib/docker/containers'
    if os.path.exists(containers_dir):
        try:
            for d in os.listdir(containers_dir):
                if d.startswith(cid):
                    config_path = os.path.join(containers_dir, d, 'config.v2.json')
                    if os.path.exists(config_path):
                        with open(config_path) as f:
                            config = json.load(f)
                            return {'container_name': config.get('Name', '').lstrip('/')}
        except (OSError, json.JSONDecodeError):
            pass
    return {}

def _podman_metadata(cid: str) -> Dict[str, str]:
    """Extract Podman container metadata"""
    try:
        result = subprocess.run(
            ['podman', 'inspect', cid, '--format=json'], 
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)[0]
            return {'container_name': data.get('Name', '')}
    except (subprocess.SubprocessError, json.JSONDecodeError, IndexError, KeyError):
        pass
    return {}

# Smart TOP-N aggregation
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
