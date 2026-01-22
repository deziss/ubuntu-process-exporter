#!/usr/bin/env python3
"""
UPM Exporter — Unified Process Metrics Exporter

v0.2.7 - Performance Optimizations:
• Cached label generation
• Pre-computed static labels
• Set-based lookups for INCLUDE_LABELS
• Optimized metric updates
• Optional gzip compression

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
import gzip
from io import BytesIO
from typing import Dict, List, Set, FrozenSet

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
ENABLE_GZIP = os.getenv("ENABLE_GZIP", "true").lower() == "true"
GZIP_MIN_SIZE = int(os.getenv("GZIP_MIN_SIZE", "1024"))  # Minimum bytes to compress

# Pre-cached hostname (avoid repeated syscalls)
HOSTNAME: str = (
    os.getenv("HOSTNAME")
    or (open("/host/etc/hostname").read().strip()
        if os.path.exists("/host/etc/hostname")
        else socket.gethostname())
)

# Parse and normalize label names - use frozenset for O(1) lookups
VALID_LABELS: FrozenSet[str] = frozenset({
    "pid", "user", "command", "runtime", "cgroup_version", "rank", 
    "container_id", "container_name", "pod_name", 
    "namespace", "ports", "hostname"
})

# Common typos/variations mapping
LABEL_ALIASES: Dict[str, str] = {
    "port": "ports",
    "host": "hostname",
    "container": "container_name",
    "pod": "pod_name",
    "ns": "namespace",
}

def normalize_labels(raw_labels: str) -> FrozenSet[str]:
    """Normalize and validate label names, return as frozenset for O(1) lookups"""
    labels: Set[str] = set()
    invalid: List[str] = []
    
    for label in raw_labels.split(","):
        label = label.strip()
        if not label:
            continue
            
        # Normalize common variations
        normalized = LABEL_ALIASES.get(label, label)
        
        # Validate against known labels
        if normalized in VALID_LABELS:
            labels.add(normalized)
        else:
            invalid.append(label)
    
    # Log warnings for invalid labels
    if invalid:
        logging.warning(
            f"Invalid label names ignored: {invalid}. "
            f"Valid labels: {sorted(VALID_LABELS)}"
        )
    
    return frozenset(labels)

# Pre-compute INCLUDE_LABELS as both list (for metric definition) and frozenset (for lookups)
_INCLUDE_LABELS_SET: FrozenSet[str] = normalize_labels(
    os.getenv(
        "INCLUDE_LABELS",
        "pid,user,command,runtime,rank,container_id,container_name,pod_name,namespace,ports,hostname",
    )
)
INCLUDE_LABELS: List[str] = sorted(_INCLUDE_LABELS_SET)  # Sorted list for metric labels

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

# Pre-built label template with static values
_STATIC_LABELS: Dict[str, str] = {"hostname": HOSTNAME}

def labels_for(p: ProcessMetric) -> Dict[str, str]:
    """Build label dict with strict cardinality control and validation - optimized"""
    # All possible labels with their values
    all_labels = {
        "pid": str(p.pid),
        "user": p.user or "",
        "command": (p.command or "")[:64],
        "runtime": p.runtime or "",
        "cgroup_version": p.cgroup_version or "unknown",
        "rank": str(p.rank),
        "container_id": (p.container_id or "")[:12],
        "container_name": (p.container_name or "")[:64],
        "pod_name": (p.pod_name or "")[:64],
        "namespace": (p.namespace or "")[:64],
        "ports": str(p.ports) if p.ports else "",
    }
    
    # Add static labels
    all_labels.update(_STATIC_LABELS)
    
    # Only return labels that are in INCLUDE_LABELS (O(1) lookup with frozenset)
    return {k: v for k, v in all_labels.items() if k in _INCLUDE_LABELS_SET}


def clear_metrics():
    for m in ALL_METRICS:
        m.clear()


def compress_gzip(data: bytes) -> bytes:
    """Compress data using gzip"""
    out = BytesIO()
    with gzip.GzipFile(fileobj=out, mode='wb', compresslevel=6) as f:
        f.write(data)
    return out.getvalue()


# HTTP Handler
class MetricsHandler(BaseHTTPRequestHandler):
    # Suppress default logging
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

                # Runtime counters - use dict.setdefault for cleaner code
                runtime_counts: Dict[str, int] = {}
                for p in processes:
                    runtime_counts[p.runtime] = runtime_counts.get(p.runtime, 0) + 1

                for rt, count in runtime_counts.items():
                    PROCESSES_TOTAL.labels(runtime=rt).set(count)

                clear_metrics()
                tops = aggregate_top(processes)

                # Batch process metrics updates
                for p in tops.get("cpu", []):
                    labels = labels_for(p)
                    PROCESS_CPU.labels(**labels).set(p.cpu_pct)
                    PROCESS_UPTIME.labels(**labels).set(p.uptime_sec)

                for p in tops.get("memory", []):
                    labels = labels_for(p)
                    PROCESS_MEM_BYTES.labels(**labels).set(p.mem_rss_kb * 1024)
                    PROCESS_MEM_PERCENT.labels(**labels).set(p.mem_pct)
                    PROCESS_UPTIME.labels(**labels).set(p.uptime_sec)

                for p in tops.get("disk_read", []):
                    labels = labels_for(p)
                    PROCESS_DISK_READ.labels(**labels).set(p.disk_read_bytes)
                    PROCESS_UPTIME.labels(**labels).set(p.uptime_sec)

                for p in tops.get("disk_write", []):
                    labels = labels_for(p)
                    PROCESS_DISK_WRITE.labels(**labels).set(p.disk_write_bytes)
                    PROCESS_UPTIME.labels(**labels).set(p.uptime_sec)

                self._write_metrics()

            except Exception as e:
                SCRAPE_ERRORS.inc()
                log.exception("Metrics scrape failed")
                self.send_error(500, str(e))

    def _write_metrics(self):
        output = generate_latest()
        
        # Check if client accepts gzip and output size warrants compression
        accept_encoding = self.headers.get('Accept-Encoding', '')
        use_gzip = (
            ENABLE_GZIP 
            and 'gzip' in accept_encoding 
            and len(output) >= GZIP_MIN_SIZE
        )
        
        if use_gzip:
            output = compress_gzip(output)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(output)))
        else:
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(output)))
        
        self.end_headers()
        self.wfile.write(output)


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

    log.info("UPM Exporter started (v0.2.7 - Performance Optimized)")
    log.info("Port: %d", METRICS_PORT)
    log.info("Hostname: %s", HOSTNAME)
    log.info("Labels (normalized): %s", INCLUDE_LABELS)
    log.info("Gzip compression: %s (min size: %d bytes)", ENABLE_GZIP, GZIP_MIN_SIZE)
    
    # Validate that metrics are properly configured
    if not INCLUDE_LABELS:
        log.error("No valid labels configured! Metrics will fail.")
        sys.exit(1)

    while not shutdown_flag.is_set():
        server.handle_request()

    log.info("Exporter stopped")

# -------------------------------------------------------------------

if __name__ == "__main__":
    run()
