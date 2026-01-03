#!/usr/bin/env python3

import time
import sys
import os
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from prometheus_client import Gauge, generate_latest, CONTENT_TYPE_LATEST
from collector import collect_data, aggregate_top

# Get host hostname
try:
    with open('/host/etc/hostname', 'r') as f:
        hostname = f.read().strip()
except:
    hostname = socket.gethostname()

# Dynamic labels configuration
ALL_LABELS = ['pid', 'uid', 'user', 'command', 'runtime', 'rank', 'port', 'container_id', 'container_name', 'hostname', 'uptime']
include_labels_env = os.getenv('INCLUDE_LABELS', '')
if include_labels_env:
    include_labels = [l.strip() for l in include_labels_env.split(',') if l.strip()]
    labelnames = [l for l in ALL_LABELS if l in include_labels]
else:
    labelnames = ALL_LABELS

# Task 5.1: Metric Definitions
process_top_memory_bytes = Gauge('process_top_memory_bytes', 'Top processes by memory usage', labelnames)
process_top_cpu_percent = Gauge('process_top_cpu_percent', 'Top processes by CPU usage', labelnames)
process_top_disk_read_bytes = Gauge('process_top_disk_read_bytes', 'Top processes by disk read', labelnames)
process_top_disk_write_bytes = Gauge('process_top_disk_write_bytes', 'Top processes by disk write', labelnames)

def get_labels_dict(p, labelnames):
    all_labels = {
        'pid': str(p.pid),
        'uid': str(p.uid),
        'user': p.user,
        'command': p.command,
        'runtime': p.runtime,
        'rank': str(p.rank),
        'port': p.port,
        'container_id': p.container_id,
        'container_name': p.container_name,
        'hostname': hostname,
        'uptime': str(p.uptime)
    }
    return {k: v for k, v in all_labels.items() if k in labelnames}

# Task 5.2: HTTP Server
class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', CONTENT_TYPE_LATEST)
            self.end_headers()
            # Collect and aggregate data
            processes = collect_data()
            tops = aggregate_top(processes)
            # Clear previous metrics
            process_top_memory_bytes.clear()
            process_top_cpu_percent.clear()
            process_top_disk_read_bytes.clear()
            process_top_disk_write_bytes.clear()
            # Set new metrics
            for p in tops['memory']:
                labels = get_labels_dict(p, labelnames)
                process_top_memory_bytes.labels(**labels).set(p.mem_rss_kb * 1024)  # Convert KB to bytes
            for p in tops['cpu']:
                labels = get_labels_dict(p, labelnames)
                process_top_cpu_percent.labels(**labels).set(p.cpu_pct)
            for p in tops['disk_read']:
                labels = get_labels_dict(p, labelnames)
                process_top_disk_read_bytes.labels(**labels).set(p.disk_read_bytes)
            for p in tops['disk_write']:
                labels = get_labels_dict(p, labelnames)
                process_top_disk_write_bytes.labels(**labels).set(p.disk_write_bytes)
            # Generate output
            self.wfile.write(generate_latest())
        else:
            self.send_response(404)
            self.end_headers()

def run_server(port=9105):
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f"Starting server on port {port}")
    server.serve_forever()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9105
    run_server(port)