#!/bin/bash

# collector.sh: Raw Data Collection
# Output: tab-separated lines: pid uid user pcpu rss etimes comm disk_read disk_write ip port cgroup

set -e

PROC_DIR=${PROC_DIR:-/proc}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}

# Collect network data
declare -A pid_networks
lsof -i -P -n 2>/dev/null | grep LISTEN | while read -r command pid user fd type device size_off node name; do
    if [[ $name == *:* ]]; then
        port=$(echo "$name" | cut -d: -f2)
        if [ -z "${pid_networks[$pid]}" ]; then
            pid_networks[$pid]=":$port"
        else
            pid_networks[$pid]="${pid_networks[$pid]},:$port"
        fi
    fi
done

# Get process info
ps -eo pid,uid,user,pcpu,rss,etimes,comm --no-headers | while read -r pid uid user pcpu rss etimes comm; do
    # Disk I/O
    disk_read_bytes=0
    disk_write_bytes=0
    # if [ -r $PROC_DIR/$pid/io ]; then
    #     disk_read_bytes=$(awk '/read_bytes:/ {print $2}' $PROC_DIR/$pid/io 2>/dev/null || echo 0)
    #     disk_write_bytes=$(awk '/write_bytes:/ {print $2}' $PROC_DIR/$pid/io 2>/dev/null || echo 0)
    # fi

    # Cgroup path
    cgroup_path=""
    if [ -f $PROC_DIR/$pid/cgroup ]; then
        cgroup_path=$(head -1 $PROC_DIR/$pid/cgroup | cut -d: -f3 | tr '\n' ' ' | tr -s ' ')
    fi

    # Network
    network="${pid_networks[$pid]}"
    ip=""
    port=""
    if [ -n "$network" ]; then
        first_net=$(echo "$network" | cut -d, -f1)
        ip=$(echo "$first_net" | cut -d: -f1)
        port=$(echo "$first_net" | cut -d: -f2)
    fi

    # Output tab separated
    echo "$pid	$uid	$user	$pcpu	$rss	$etimes	$comm	$disk_read_bytes	$disk_write_bytes	$ip	$port	$cgroup_path"
done