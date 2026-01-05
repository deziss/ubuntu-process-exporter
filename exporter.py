#!/usr/bin/env python3
"""
UPM Exporter — Unified Process Metrics Exporter

• Consumes collector.collect_data()
• Exposes Prometheus metrics
• Safe for Kubernetes / Docker / bare metal
• Cardinality-aware
"""

import os
import sys
import time
import socket
import signal
import logging
import threading
from typing import Dict, List

from http.server import BaseHTTPRequestHandler, HTTPServer
from prometheus_client import (
    Gauge,
    Counter,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

try:
    from collector import collect_data, aggregate_top, ProcessMetric
except ImportError as e:
    print(f"[FATAL] Failed to import collector: {e}", file=sys.stderr)
    sys.exit(1)

# Configuration
METRICS_PORT = int(os.getenv("METRICS_PORT", "9105"))
SCRAPE_TIMEOUT = int(os.getenv("SCRAPE_TIMEOUT", "30"))

HOSTNAME = (
    os.getenv("HOSTNAME")
    or (open("/host/etc/hostname").read().strip()
        if os.path.exists("/host/etc/hostname")
        else socket.gethostname())
)

INCLUDE_LABELS = [
    l.strip()
    for l in os.getenv(
        "INCLUDE_LABELS",
        "pid,uid,user,command,runtime,rank,container_id,container_name,pod_name,namespace,port,hostname",
    ).split(",")
    if l.strip()
]

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] Exporter: %(message)s",
)
log = logging.getLogger("Exporter")


# Port availability guard (REQUIRED)
def port_available(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) != 0

if not port_available(METRICS_PORT):
    log.error(f"Port {METRICS_PORT} already in use, exiting")
    sys.exit(1)

# Prometheus Metrics
SCRAPE_DURATION = Histogram(
    "upm_scrape_duration_seconds",
    "Time spent collecting process metrics",
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)


SCRAPE_ERRORS = Counter(
    "upm_scrape_errors_total",
    "Total scrape errors",
)

PROCESSES_TOTAL = Gauge(
    "upm_processes_scraped_total",
    "Processes scraped by runtime",
    ["runtime"],
)

PROCESS_CPU = Gauge(
    "upm_process_top_cpu_percent",
    "Top processes by CPU usage (%)",
    INCLUDE_LABELS,
)

PROCESS_MEM_BYTES = Gauge(
    "upm_process_top_memory_bytes",
    "Top processes by RSS memory (bytes)",
    INCLUDE_LABELS,
)

PROCESS_MEM_PERCENT = Gauge(
    "upm_process_top_memory_percent",
    "Top processes by memory (%)",
    INCLUDE_LABELS,
)

PROCESS_DISK_READ = Gauge(
    "upm_process_top_disk_read_bytes",
    "Top processes by disk read bytes",
    INCLUDE_LABELS,
)

PROCESS_DISK_WRITE = Gauge(
    "upm_process_top_disk_write_bytes",
    "Top processes by disk write bytes",
    INCLUDE_LABELS,
)

PROCESS_UPTIME = Gauge(
    "upm_process_uptime_seconds",
    "Process uptime in seconds",
    INCLUDE_LABELS,
)


ALL_METRICS = [
    PROCESS_CPU,
    PROCESS_MEM_BYTES,
    PROCESS_MEM_PERCENT,
    PROCESS_DISK_READ,
    PROCESS_DISK_WRITE,
    PROCESS_UPTIME,
]

# Helpers
def labels_for(p: ProcessMetric) -> Dict[str, str]:
    """Build label dict with strict cardinality control"""
    labels = {
        "pid": str(p.pid),
        "uid": str(p.uid),
        "user": p.user or "",
        "command": p.command[:64],
        "runtime": p.runtime,
        "rank": str(p.rank),
        "container_id": p.container_id[:12],
        "container_name": p.container_name[:64],
        "pod_name": p.pod_name[:64],
        "namespace": p.namespace[:64],
        "port": str(p.port) if p.port else "",
        "hostname": HOSTNAME,
    }
    return {k: v for k, v in labels.items() if k in INCLUDE_LABELS}

def clear_metrics():
    for m in ALL_METRICS:
        m.clear()

# HTTP Handler
class MetricsHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/metrics":
            self._handle_metrics()
        elif self.path in ("/health", "/ready"):
            self._handle_ok()
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_ok(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OK\n")

    def _handle_metrics(self):
        with SCRAPE_DURATION.time():
            try:
                processes = collect_data()
                if not processes:
                    log.warning("No processes collected")
                    self._write_metrics()
                    return

                # Runtime counters
                runtime_counts: Dict[str, int] = {}
                for p in processes:
                    runtime_counts[p.runtime] = runtime_counts.get(p.runtime, 0) + 1

                for rt, count in runtime_counts.items():
                    PROCESSES_TOTAL.labels(runtime=rt).set(count)

                clear_metrics()
                tops = aggregate_top(processes)

                for p in tops.get("cpu", []):
                    PROCESS_CPU.labels(**labels_for(p)).set(p.cpu_pct)
                    PROCESS_UPTIME.labels(**labels_for(p)).set(p.uptime_sec)

                for p in tops.get("memory", []):
                    PROCESS_MEM_BYTES.labels(**labels_for(p)).set(p.mem_rss_kb * 1024)
                    PROCESS_MEM_PERCENT.labels(**labels_for(p)).set(p.mem_pct)
                    PROCESS_UPTIME.labels(**labels_for(p)).set(p.uptime_sec)

                for p in tops.get("disk_read", []):
                    PROCESS_DISK_READ.labels(**labels_for(p)).set(p.disk_read_bytes)
                    PROCESS_UPTIME.labels(**labels_for(p)).set(p.uptime_sec)

                for p in tops.get("disk_write", []):
                    PROCESS_DISK_WRITE.labels(**labels_for(p)).set(p.disk_write_bytes)
                    PROCESS_UPTIME.labels(**labels_for(p)).set(p.uptime_sec)

                self._write_metrics()

            except Exception as e:
                SCRAPE_ERRORS.inc()
                log.exception("Metrics scrape failed")
                self.send_error(500, str(e))

    def _write_metrics(self):
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE_LATEST)
        self.end_headers()
        self.wfile.write(generate_latest())

# Server
shutdown_flag = threading.Event()

def shutdown_handler(signum, frame):
    log.info("Shutdown signal received")
    shutdown_flag.set()

signal.signal(signal.SIGTERM, shutdown_handler)
signal.signal(signal.SIGINT, shutdown_handler)

def run():
    server = HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler)
    server.timeout = 1

    log.info("UPM Exporter started")
    log.info("Port: %d", METRICS_PORT)
    log.info("Hostname: %s", HOSTNAME)
    log.info("Labels: %s", INCLUDE_LABELS)

    while not shutdown_flag.is_set():
        server.handle_request()

    log.info("Exporter stopped")

# -------------------------------------------------------------------

if __name__ == "__main__":
    run()
