#!/usr/bin/env python3

import json
import subprocess
import sys
import os
import re
from dataclasses import dataclass, asdict
from typing import Optional, Dict
from functools import lru_cache
import time

# Task 2.1: Unified Data Model
@dataclass
class ProcessMetric:
    pid: int
    uid: int
    user: str
    command: str
    cpu_pct: float
    mem_rss_kb: int
    disk_read_bytes: int
    disk_write_bytes: int
    ip: Optional[str]
    port: Optional[str]
    cgroup_path: str
    # Additional fields for later
    runtime: str = "host"
    container_id: str = ""
    container_name: str = ""
    pod_name: str = ""
    namespace: str = ""
    rank: int = 0

# Task 3.1: Container Runtime Detection
def detect_runtime(cgroup_path: str) -> str:
    if 'docker' in cgroup_path:
        return 'docker'
    elif 'cri-containerd' in cgroup_path or 'containerd' in cgroup_path:
        return 'containerd'
    elif 'kubepods' in cgroup_path:
        return 'kubernetes'
    elif cgroup_path.startswith('/user.slice') or cgroup_path.startswith('/system.slice'):
        return 'systemd'
    else:
        return 'host'

# Task 3.2: Container ID Extraction
def extract_container_id(cgroup_path: str, runtime: str) -> str:
    if runtime == 'docker':
        match = re.search(r'docker/([a-f0-9]{64})', cgroup_path)
        if match:
            return match.group(1)[:12]  # Short ID
    elif runtime == 'containerd':
        match = re.search(r'cri-containerd-([a-f0-9]+)', cgroup_path)
        if match:
            return match.group(1)[:12]
    elif runtime == 'kubernetes':
        # For k8s, container ID might be in different places, but for simplicity
        return 'unknown'
    return ''

# Task 3.3: Container Metadata Resolution
@lru_cache(maxsize=128)
def resolve_container_metadata(container_id: str, runtime: str) -> Dict[str, str]:
    if not container_id or runtime not in ['docker', 'containerd']:
        return {'container_name': '', 'pod_name': '', 'namespace': ''}

    if runtime == 'docker':
        config_path = f'/var/lib/docker/containers/{container_id}/config.v2.json'
        if os.path.exists(config_path):
            try:
                with open(config_path, 'r') as f:
                    config = json.load(f)
                    name = config.get('Name', '').lstrip('/')
                    return {'container_name': name, 'pod_name': '', 'namespace': ''}
            except:
                pass
    # For containerd and k8s, more complex, placeholder
    return {'container_name': '', 'pod_name': '', 'namespace': ''}

# Task 4.1 & 4.2: Top-N Aggregation
def get_top_n(processes, key_func, n=20):
    sorted_processes = sorted(processes, key=key_func, reverse=True)
    top = sorted_processes[:n]
    for rank, p in enumerate(top, 1):
        p.rank = rank
    return top

def aggregate_top(processes):
    top_memory = get_top_n(processes, lambda p: p.mem_rss_kb)
    top_cpu = get_top_n(processes, lambda p: p.cpu_pct)
    top_disk_read = get_top_n(processes, lambda p: p.disk_read_bytes)
    top_disk_write = get_top_n(processes, lambda p: p.disk_write_bytes)
    return {
        'memory': top_memory,
        'cpu': top_cpu,
        'disk_read': top_disk_read,
        'disk_write': top_disk_write
    }

# Task 2.2: Join Raw Datasets
def collect_data():
    # Run collector.sh
    try:
        result = subprocess.run(['./collector.sh'], capture_output=True, text=True, check=True)
        lines = result.stdout.strip().split('\n')
    except subprocess.CalledProcessError as e:
        print(f"Error running collector.sh: {e}", file=sys.stderr)
        sys.exit(1)

    processes = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split('\t')
        if len(parts) != 11:
            print(f"Invalid line: {line}", file=sys.stderr)
            continue
        pid, uid, user, pcpu, rss, comm, disk_read, disk_write, ip, port, cgroup_path = parts
        pm = ProcessMetric(
            pid=int(pid),
            uid=int(uid),
            user=user,
            command=comm,
            cpu_pct=float(pcpu),
            mem_rss_kb=int(rss),
            disk_read_bytes=int(disk_read),
            disk_write_bytes=int(disk_write),
            ip=ip,
            port=port,
            cgroup_path=cgroup_path
        )
        # Detect runtime
        pm.runtime = detect_runtime(pm.cgroup_path)
        pm.container_id = extract_container_id(pm.cgroup_path, pm.runtime)
        metadata = resolve_container_metadata(pm.container_id, pm.runtime)
        pm.container_name = metadata['container_name']
        pm.pod_name = metadata['pod_name']
        pm.namespace = metadata['namespace']
        processes.append(pm)

    return processes

if __name__ == "__main__":
    processes = collect_data()
    # For now, just print JSON
    print(json.dumps([asdict(p) for p in processes], indent=2))