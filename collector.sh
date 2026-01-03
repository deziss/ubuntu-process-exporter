#!/bin/bash

# collector.sh: Raw Data Collection
# Output: tab-separated lines: pid user pcpu rss comm disk_read disk_write ip port cgroup

set -e

PROC_DIR=${PROC_DIR:-/proc}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}

# Collect network data
declare -A pid_networks
while read -r line; do
    pid=$(echo "$line" | grep -o 'pid=[0-9]*' | cut -d= -f2)
    if [ -n "$pid" ]; then
        local_addr=$(echo "$line" | awk '{print $5}')
        ip=$(echo "$local_addr" | cut -d: -f1 | sed 's/\[//;s/\]//')
        port=$(echo "$local_addr" | cut -d: -f2- | cut -d: -f1)
        if [ -z "${pid_networks[$pid]}" ]; then
            pid_networks[$pid]="$ip:$port"
        else
            pid_networks[$pid]="${pid_networks[$pid]},$ip:$port"
        fi
    fi
done < <(ss -tunp 2>/dev/null | grep 'pid=')

# Get process info
ps -eo pid,uid,user,pcpu,rss,comm --no-headers | while read -r pid uid user pcpu rss comm; do
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
    echo "$pid	$uid	$user	$pcpu	$rss	$comm	$disk_read_bytes	$disk_write_bytes	$ip	$port	$cgroup_path"
done