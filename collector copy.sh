#!/usr/bin/env bash
#
# collector.sh — Enhanced Raw Process Collector (FIXED)
#
# Output (TSV):
# timestamp pid uid user cpu_pct mem_pct etimes comm
# disk_read_bytes disk_write_bytes ip port cgroup
#
# Supports: TSV / JSON
# Safe for: cron, exporters, Loki, Prometheus textfile
#

set -euo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-100}
FORMAT=${FORMAT:-tsv}          # tsv | json
SUDO_LSOF=${SUDO_LSOF:-sudo}

TIMESTAMP=$(date -Is)

# -------------------------------------
# Network collection (FIXED: no subshell)
# -------------------------------------
declare -A pid_networks

if $SUDO_LSOF lsof -i -P -n >/dev/null 2>&1; then
    while read -r _ pid _ _ _ _ _ _ name; do
        [[ $name == *:* ]] || continue
        port="${name##*:}"
        [[ $port =~ ^[0-9]+$ ]] || continue
        pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
    done < <($SUDO_LSOF lsof -i -P -n 2>/dev/null | grep -E 'LISTEN|UDP')
else
    while read -r line; do
        [[ $line =~ pid=([0-9]+) ]] || continue
        pid="${BASH_REMATCH[1]}"
        port="$(echo "$line" | grep -oE ':[0-9]+' | head -1 | tr -d ':')"
        [[ -n $port ]] && pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
    done < <(ss -tlnup 2>/dev/null)
fi

# ----------------
# Disk I/O helper
# ----------------
get_disk_io() {
    local pid=$1
    local io="$PROC_DIR/$pid/io"
    if [[ -r $io ]]; then
        awk '
            /read_bytes:/  {r=$2}
            /write_bytes:/ {w=$2}
            END {print r+0, w+0}
        ' "$io"
    else
        echo "0 0"
    fi
}

# ----------------------------
# Process collection (Top N)
# ----------------------------
ps -eo pid,uid,user,pcpu,pmem,rss,etimes,comm \
   --sort=-pcpu,-pmem --no-headers | head -n "$TOP_N" |
while read -r pid uid user cpu mem etimes comm; do

    [[ $comm == \[* ]] && continue

    read rd wr <<< "$(get_disk_io "$pid")"

    cgroup=""
    [[ -r $PROC_DIR/$pid/cgroup ]] && \
        cgroup="$(cut -d: -f3 < "$PROC_DIR/$pid/cgroup" | head -1)"

    net="${pid_networks[$pid]:-}"
    ip=""
    port=""
    if [[ -n $net ]]; then
        first="${net%%,*}"
        ip="${first%:*}"
        port="${first#*:}"
    fi

    printf "%s\t%s\t%s\t%.2f\t%.2f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$pid" "$uid" "$user" "$cpu" "$mem" "$rss" "$etimes" "$comm" \
        "$rd" "$wr" "$ip" "$port" "$cgroup"
done | {
    if [[ $FORMAT == json ]]; then
        jq -R '
          split("\t") |
          {
            pid: .[0]|tonumber,
            uid: .[1]|tonumber,
            user: .[2],
            cpu_pct: .[3]|tonumber,
            mem_pct: .[4]|tonumber,
            etimes: .[5]|tonumber,
            command: .[6],
            disk_read_bytes: .[7]|tonumber,
            disk_write_bytes: .[8]|tonumber,
            ip: .[9],
            port: .[10],
            cgroup: .[11]
          }'
    else
        cat
    fi
}
