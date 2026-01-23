#!/usr/bin/env python3
"""
Ultra-Optimized Exporter

v0.4.2 - Field Fixes:
- Empty string for missing values
- Proper label handling
- Fast metric updates
"""

import os
import sys
import logging
import socket
import gzip
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Dict, List, Set, FrozenSet
from prometheus_client import Gauge, Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

try:
    from collector import collect_data, aggregate_top, ProcessMetric
except ImportError as e:
    print(f"[FATAL] Failed to import collector: {e}", file=sys.stderr)
    sys.exit(1)

# Config
METRICS_PORT = int(os.getenv("METRICS_PORT", "9105"))
ENABLE_GZIP = os.getenv("ENABLE_GZIP", "true").lower() == "true"
GZIP_MIN_SIZE = int(os.getenv("GZIP_MIN_SIZE", "1024"))

# Hostname caching
HOSTNAME = socket.gethostname()

# Label configuration
DEFAULT_LABELS = {
    "pid", "user", "command", "runtime", "rank", 
    "container_id", "container_name",
    "cgroup_path", "ports", "hostname"
}

# Logging
logging.basicConfig(format="%(asctime)s [%(levelname)s] Exporter: %(message)s", level=logging.INFO)
log = logging.getLogger("Exporter")

# Metrics
SCRAPE_DURATION = Histogram("upm_scrape_duration_seconds", "Scrape duration")
SCRAPE_ERRORS = Counter("upm_scrape_errors_total", "Scrape errors")
PROCESSES_TOTAL = Gauge("upm_processes_scraped_total", "Total processes", ["runtime"])

# Dynamic metrics
METRIC_Definitions = {
    'cpu': Gauge("upm_process_top_cpu_percent", "Top processes by CPU", list(DEFAULT_LABELS)),
    'memory': Gauge("upm_process_top_memory_bytes", "Top processes by Memory", list(DEFAULT_LABELS)),
    'disk_read': Gauge("upm_process_top_disk_read_bytes", "Top processes by Disk Read", list(DEFAULT_LABELS)),
    'disk_write': Gauge("upm_process_top_disk_write_bytes", "Top processes by Disk Write", list(DEFAULT_LABELS)),
}

def compress_gzip(data: bytes) -> bytes:
    """Gzip compression helper"""
    return gzip.compress(data)

class MetricsHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return  # Suppress default logging

    def do_GET(self):
        if self.path == "/metrics":
            self._handle_metrics()
        elif self.path in ("/health", "/ready"):
            self._handle_ok()
        else:
            self.send_error(404)

    def _handle_ok(self):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK\n")
        except BrokenPipeError:
            pass

    def _handle_metrics(self):
        with SCRAPE_DURATION.time():
            try:
                # 1. Collect
                processes = collect_data()
                if not processes:
                    self._write_metrics()
                    return

                # 2. Update Total Count
                runtimes = {}
                for p in processes:
                    runtimes[p.runtime] = runtimes.get(p.runtime, 0) + 1
                for rt, count in runtimes.items():
                    PROCESSES_TOTAL.labels(runtime=rt).set(count)

                # 3. Clear previous metrics (important for ephemeral processes)
                for g in METRIC_Definitions.values():
                    g.clear()

                # 4. Aggregate & Set
                tops = aggregate_top(processes)
                
                # Helper to create label dict once per process
                def p_labels(p, rank):
                    return {
                        "pid": str(p.pid),
                        "user": p.user,
                        "command": p.command,
                        "runtime": p.runtime,
                        "rank": str(rank),
                        "container_id": p.container_id,
                        "container_name": p.container_name,
                        "cgroup_path": p.cgroup_path,
                        "ports": p.ports,
                        "hostname": HOSTNAME
                    }

                # Set metrics
                for i, p in enumerate(tops.get('cpu', []), 1):
                    METRIC_Definitions['cpu'].labels(**p_labels(p, i)).set(p.cpu_pct)
                
                for i, p in enumerate(tops.get('memory', []), 1):
                    METRIC_Definitions['memory'].labels(**p_labels(p, i)).set(p.mem_rss_kb * 1024)

                for i, p in enumerate(tops.get('disk_read', []), 1):
                    METRIC_Definitions['disk_read'].labels(**p_labels(p, i)).set(p.disk_read_bytes)

                for i, p in enumerate(tops.get('disk_write', []), 1):
                    METRIC_Definitions['disk_write'].labels(**p_labels(p, i)).set(p.disk_write_bytes)

                self._write_metrics()

            except Exception as e:
                SCRAPE_ERRORS.inc()
                log.error(f"Scrape failed: {e}")
                self.send_error(500)

    def _write_metrics(self):
        try:
            output = generate_latest()
            
            # Gzip check
            accept_enc = self.headers.get('Accept-Encoding', '')
            if ENABLE_GZIP and 'gzip' in accept_enc and len(output) > GZIP_MIN_SIZE:
                content = compress_gzip(output)
                self.send_response(200)
                self.send_header("Content-Encoding", "gzip")
            else:
                content = output
                self.send_response(200)
            
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            
        except BrokenPipeError:
            pass

def run():
    server = HTTPServer(('0.0.0.0', METRICS_PORT), MetricsHandler)
    log.info(f"UPM Exporter v0.3.3 started on port {METRICS_PORT}")
    
    def stop(*args):
        server.server_close()
        sys.exit(0)
        
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    
    server.serve_forever()

if __name__ == "__main__":
    run()
