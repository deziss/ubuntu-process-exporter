#!/bin/bash

# Task 0.1: Validate Platform
# Detect Ubuntu version, verify /proc accessible, cgroup v2 mounted

set -e

echo "Validating platform..."

# Detect Ubuntu version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
        echo "Error: This script is designed for Ubuntu or Debian only."
        exit 1
    fi
    VERSION_ID_NUM=$(echo $VERSION_ID | cut -d. -f1)
    if [ "$ID" = "ubuntu" ] && [ $VERSION_ID_NUM -lt 22 ]; then
        echo "Error: Ubuntu version $VERSION_ID is not supported. Minimum required: 22.04"
        exit 1
    fi
    echo "OS: $ID $VERSION_ID"
else
    echo "Error: Cannot detect OS version."
    exit 1
fi

# Verify /proc is accessible
if [ ! -d /proc ]; then
    echo "Error: /proc is not accessible."
    exit 1
fi
echo "/proc is accessible."

# Verify cgroup v2 mounted at /sys/fs/cgroup
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}
if [ ! -d $CGROUP_DIR ]; then
    echo "Error: $CGROUP_DIR not found."
    exit 1
fi

# Check if cgroup v2 is unified hierarchy
if [ -f $CGROUP_DIR/cgroup.controllers ]; then
    echo "cgroup v2 unified hierarchy detected."
else
    echo "Error: cgroup v2 unified hierarchy not detected."
    exit 1
fi

echo "Platform validation successful."