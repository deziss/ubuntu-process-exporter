#!/usr/bin/env bash
#
# collector.sh — Enhanced Raw Process Collector (PROC-ONLY, FIXED)
#
# Output (TSV):
# pid uid user cpu_pct mem_pct rss_kb uptime_sec comm
# disk_read_bytes disk_write_bytes ip port cgroup
#
# Supports: TSV / JSON
# Safe for: cron, exporters, Loki, Prometheus
#

set -euo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-100}
FORMAT=${FORMAT:-tsv}
SUDO_LSOF=${SUDO_LSOF:-sudo}

CLK_TCK=$(getconf CLK_TCK)
BOOT_TIME=$(awk '/btime/ {print $2}' /proc/stat)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)

# -------------------------------------
# Network collection (PID → port map)
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
    if [[ -r "$io" ]]; then
        awk '
          /read_bytes:/  {r=$2}
          /write_bytes:/ {w=$2}
          END {print r+0, w+0}
        ' "$io" 2>/dev/null
    else
        echo "0 0"
    fi
}

# ----------------------------
# Collect processes (PROC-ONLY)
# ----------------------------
rows=()

for pid in $(ls -1 "$PROC_DIR" | grep -E '^[0-9]+$'); do
    stat="$PROC_DIR/$pid/stat"
    status="$PROC_DIR/$pid/status"

    [[ -r "$stat" && -r "$status" ]] || continue

    comm=$(tr -d '()' < "$PROC_DIR/$pid/comm" 2>/dev/null || echo "")
    [[ -z "$comm" || "$comm" == \[* ]] && continue

    uid=$(awk '/^Uid:/ {print $2}' "$status")
    user=$(getent passwd "$uid" | cut -d: -f1 || echo "$uid")

    rss_kb=$(awk '{print $2 * 4}' "$PROC_DIR/$pid/statm" 2>/dev/null || echo 0)

    starttime=$(awk '{print $22}' "$stat")
    uptime_sec=$(( $(date +%s) - (BOOT_TIME + starttime / CLK_TCK) ))
    (( uptime_sec < 0 )) && uptime_sec=0

    proc_jiffies=$(awk '{print $14+$15}' "$stat" 2>/dev/null || echo 0)
    total_jiffies=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s}' /proc/stat)
    cpu_pct=$(awk -v p="$proc_jiffies" -v t="$total_jiffies" \
        'BEGIN { if (t>0) printf "%.2f", (p/t)*100; else print 0 }')

    mem_pct=$(awk -v r="$rss_kb" -v t="$MEM_TOTAL_KB" \
        'BEGIN { if (t>0) printf "%.2f", (r/t)*100; else print 0 }')

    read rd wr <<< "$(get_disk_io "$pid")"

    # cgroup (v2 preferred)
    cgroup=""
    if [[ -r "$PROC_DIR/$pid/cgroup" ]]; then
        cgroup="$(
            awk -F: '
              $1=="0" {print $3; exit}
              /kubepods/ {print $3; exit}
              /docker|containerd|libpod/ {print $3; exit}
              {fallback=$3}
              END {print fallback}
            ' "$PROC_DIR/$pid/cgroup"
        )"
    fi
    cgroup="${cgroup:0:500}"

    net="${pid_networks[$pid]:-}"
    ip=""
    port=""
    if [[ -n "$net" ]]; then
        first="${net%%,*}"
        ip="${first%:*}"
        port="${first#*:}"
    fi

    rows+=("$pid	$uid	$user	$cpu_pct	$mem_pct	$rss_kb	$uptime_sec	$comm	$rd	$wr	$ip	$port	$cgroup")
done

set +o pipefail

if [[ $FORMAT == json ]]; then
    printf "%s\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N" \
    | jq -R '
        split("\t") |
        {
          pid: .[0]|tonumber,
          uid: .[1]|tonumber,
          user: .[2],
          cpu_pct: .[3]|tonumber,
          mem_pct: .[4]|tonumber,
          rss_kb: .[5]|tonumber,
          uptime_sec: .[6]|tonumber,
          command: .[7],
          disk_read_bytes: .[8]|tonumber,
          disk_write_bytes: .[9]|tonumber,
          ip: .[10],
          port: .[11],
          cgroup: .[12]
        }'
else
    printf "%s\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N"
fi

set -o pipefail