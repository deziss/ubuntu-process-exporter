FROM python:3.12-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    iproute2 \
    lsof \
    ca-certificates \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application files
COPY . /app/

# Ensure executables
RUN chmod +x /app/collector.sh /app/validate.sh

# Runtime configuration
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    METRICS_PORT=9105

EXPOSE 9105

# Use tini as PID 1 (IMPORTANT)
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]

# Validate once, then start exporter
CMD ["/bin/bash", "-c", "./validate.sh && exec python3 exporter.py"]
