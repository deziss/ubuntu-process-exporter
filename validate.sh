#!/bin/bash

# Task 0.1: Validate Platform
# Detect Ubuntu/Debian version, verify /proc accessible, support cgroup v1 and v2

set -e

echo "================================"
echo "Platform Validation"
echo "================================"

# Detect Ubuntu/Debian version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
        echo "❌ Error: This script is designed for Ubuntu or Debian only."
        echo "   Detected OS: $ID"
        exit 1
    fi
    VERSION_ID_NUM=$(echo $VERSION_ID | cut -d. -f1)
    # Ubuntu minimum 20.04, Debian minimum 11
    if [ "$ID" = "ubuntu" ] && [ $VERSION_ID_NUM -lt 20 ]; then
        echo "❌ Error: Ubuntu version $VERSION_ID is not supported. Minimum required: 20.04"
        exit 1
    fi
    if [ "$ID" = "debian" ] && [ $VERSION_ID_NUM -lt 11 ]; then
        echo "❌ Error: Debian version $VERSION_ID is not supported. Minimum required: 11"
        exit 1
    fi
    echo "✅ OS: $ID $VERSION_ID"
else
    echo "❌ Error: Cannot detect OS version."
    exit 1
fi

# Verify /proc is accessible
if [ ! -d /proc ]; then
    echo "❌ Error: /proc is not accessible."
    exit 1
fi
echo "✅ /proc filesystem: accessible"

# Verify cgroup mounted (v2 or v1)
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}
if [ ! -d $CGROUP_DIR ]; then
    echo "❌ Error: $CGROUP_DIR not found."
    exit 1
fi
echo "✅ Cgroup filesystem: found at $CGROUP_DIR"

# Detect cgroup version and subsystems
CGROUP_VERSION="unknown"
if [ -f "$CGROUP_DIR/cgroup.controllers" ]; then
    CGROUP_VERSION="v2"
    AVAILABLE_CONTROLLERS=$(cat "$CGROUP_DIR/cgroup.controllers" 2>/dev/null || echo "unknown")
    echo "✅ Cgroup Version: v2 (unified hierarchy)"
    echo "   Available controllers: $AVAILABLE_CONTROLLERS"
elif [ -f "$CGROUP_DIR/cgroup.procs" ]; then
    CGROUP_VERSION="v2"
    echo "✅ Cgroup Version: v2 (detected via cgroup.procs)"
elif [ -d "$CGROUP_DIR/cpu" ] || [ -d "$CGROUP_DIR/cpuacct" ] || [ -d "$CGROUP_DIR/memory" ]; then
    CGROUP_VERSION="v1"
    echo "✅ Cgroup Version: v1 (legacy hierarchy)"
    # List available v1 subsystems
    SUBSYSTEMS=$(ls -d "$CGROUP_DIR"/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ', ' | sed 's/,$//')
    echo "   Available subsystems: $SUBSYSTEMS"
    echo "⚠️  Note: cgroup v1 has limited container detection. Consider upgrading to cgroup v2."
else
    echo "⚠️  Warning: Cgroup detected but version unclear. Proceeding with limited functionality."
    CGROUP_VERSION="hybrid"
fi

# Summary
echo ""
echo "================================"
echo "Validation Summary"
echo "================================"
echo "Status: ✅ Platform validation successful"
echo "Cgroup Support: $CGROUP_VERSION"
echo "Ready to run: ./collector.sh && python3 exporter.py"
echo "================================"