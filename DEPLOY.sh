#!/bin/bash
# Quick Deployment Script for process-exporter
# Dual Cgroup v1 & v2 Support

set -e

echo "================================"
echo "Process Exporter Deployment"
echo "================================"
echo

# Step 1: Validate
echo "[1/5] Validating platform..."
if ! bash validate.sh; then
    echo "❌ Platform validation failed"
    exit 1
fi
echo "✅ Platform validation passed"
echo

# Step 2: Check syntax
echo "[2/5] Checking syntax..."
if ! bash -n collector.sh 2>/dev/null || ! bash -n validate.sh 2>/dev/null; then
    echo "❌ Bash syntax check failed"
    exit 1
fi
if ! python3 -m py_compile collector.py exporter.py 2>/dev/null; then
    echo "❌ Python syntax check failed"
    exit 1
fi
echo "✅ Syntax checks passed"
echo

# Step 3: Test collector
echo "[3/5] Testing collector output..."
FIELD_COUNT=$(bash collector.sh 2>/dev/null | head -1 | awk -F'\t' '{print NF}')
if [ "$FIELD_COUNT" != "12" ]; then
    echo "❌ Collector output has $FIELD_COUNT fields (expected 12)"
    exit 1
fi
echo "✅ Collector output valid ($FIELD_COUNT fields)"
echo

# Step 4: Build Docker image
echo "[4/5] Building Docker image..."
docker-compose up --build -d || {
    echo "❌ Docker build failed"
    exit 1
}
echo "✅ Docker image built and container started"
echo

# Step 5: Verify metrics
echo "[5/5] Verifying metrics..."
sleep 5
METRICS=$(curl -s http://localhost:9106/metrics 2>/dev/null | grep -c "upm_process" || true)
if [ "$METRICS" -lt 5 ]; then
    echo "⚠️  Low metric count ($METRICS), but container is running"
    echo "   Check logs: docker-compose logs -f ubuntu-process-exporter"
else
    echo "✅ Metrics available ($METRICS metrics found)"
fi
echo

echo "================================"
echo "✅ DEPLOYMENT COMPLETE"
echo "================================"
echo
echo "Next steps:"
echo "1. View logs: docker-compose logs -f ubuntu-process-exporter"
echo "2. Check metrics: curl http://localhost:9106/metrics | head -20"
echo "3. Read docs: cat DOCUMENTATION_INDEX.md"
echo "4. Quick ref: cat QUICK_REFERENCE.md"
echo
