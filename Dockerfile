FROM python:3.12-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    procps \
    iproute2 \
    lsof \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
COPY requirements.txt /app/requirements.txt
RUN pip3 install -r /app/requirements.txt

# Copy application files
COPY . /app/

# Make scripts executable
RUN chmod +x /app/validate.sh /app/collector.sh

# Set working directory
WORKDIR /app

# Expose port
EXPOSE 9105

# Run validation and then exporter
CMD ["/bin/bash", "-c", "./validate.sh && python3 exporter.py"]