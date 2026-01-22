#!/usr/bin/env bash
#
# collector.sh — Enhanced Raw Process Collector (Based on v0.2.4)
#
# v0.3.0 - Restored fast v0.2.4 logic with cgroup v1/v2 compatibility
#
# Output (TSV):
# pid user cpu_pct mem_pct rss_kb uptime_sec comm
# disk_read_bytes disk_write_bytes ports cgroup_path cgroup_version container_runtime
#
# Supports: TSV / JSON, cgroup v1 and v2
# Safe for: cron, exporters, Loki, Prometheus
#

set -euo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-50}
FORMAT=${FORMAT:-tsv}
SUDO_LSOF=${SUDO_LSOF:-sudo}
ENABLE_DISK_IO=${ENABLE_DISK_IO:-true}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}

CACHE_DIR=${CACHE_DIR:-/tmp/upm}
CACHE_FILE="$CACHE_DIR/collector.cache"
TMP_FILE="$CACHE_FILE.tmp"

CLK_TCK=$(getconf CLK_TCK)
BOOT_TIME=$(awk '/btime/ {print $2}' /proc/stat)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
NOW=$(date +%s)

# Detect cgroup version once at start
if [[ -f "$CGROUP_DIR/cgroup.controllers" ]]; then
    CGROUP_VERSION="v2"
else
    CGROUP_VERSION="v1"
fi

#--------- PREPARE CACHE DIR ----------
if command -v sudo >/dev/null 2>&1 && [[ -n "${SUDO_LSOF:-}" ]]; then
    [[ -d "$CACHE_DIR" ]] || sudo mkdir -p "$CACHE_DIR" 2>/dev/null || mkdir -p "$CACHE_DIR" 2>/dev/null || true
else
    [[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR" 2>/dev/null || true
fi

# --------- PRECOMPUTE ----------
TOTAL_JIFFIES=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s}' /proc/stat)

# --------- UID CACHE ----------
declare -A UID_MAP

# -------------------------------------
# Network collection (PID → port map)
# Skip if SUDO_LSOF is empty
# -------------------------------------
declare -A pid_networks

if [[ -n "${SUDO_LSOF:-}" ]] && $SUDO_LSOF lsof -i -P -n >/dev/null 2>&1; then
    while read -r _ pid _ _ _ _ _ _ name; do
        [[ $name == *:* ]] || continue
        port="${name##*:}"
        [[ $port =~ ^[0-9]+$ ]] || continue
        pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
    done < <($SUDO_LSOF lsof -i -P -n 2>/dev/null | grep -E 'LISTEN|UDP')
fi

# ----------------
# Disk I/O helper
# ----------------
get_disk_io() {
    [[ "$ENABLE_DISK_IO" != "true" ]] && { echo "0 0"; return; }
    local io="$PROC_DIR/$1/io"
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

for pid in "$PROC_DIR"/[0-9]*; do
    pid="${pid##*/}"

    stat="$PROC_DIR/$pid/stat"
    status="$PROC_DIR/$pid/status"
    statm="$PROC_DIR/$pid/statm"
    cgfile="$PROC_DIR/$pid/cgroup"

    [[ -r "$stat" && -r "$status" && -r "$statm" ]] || continue

    comm=$(<"$PROC_DIR/$pid/comm")
    [[ -z "$comm" || "$comm" == \[* ]] && continue

    uid=$(awk '/^Uid:/ {print $2}' "$status")

    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" | cut -d: -f1 || echo "$uid")
        UID_MAP[$uid]="$user"
    fi

    rss_kb=$(awk '{print $2 * 4}' "$statm")

    starttime=$(awk '{print $22}' "$stat")
    uptime_sec=$(( NOW - (BOOT_TIME + starttime / CLK_TCK) ))
    (( uptime_sec < 0 )) && uptime_sec=0

    proc_jiffies=$(awk '{print $14+$15}' "$stat")
    cpu_pct=$(awk -v p="$proc_jiffies" -v t="$TOTAL_JIFFIES" \
        'BEGIN { printf "%.2f", (t>0 ? (p/t)*100 : 0) }')

    mem_pct=$(awk -v r="$rss_kb" -v t="$MEM_TOTAL_KB" \
        'BEGIN { printf "%.2f", (t>0 ? (r/t)*100 : 0) }')

    read rd wr <<< "$(get_disk_io "$pid")"

    # Safe aggressive filter
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue

    # -------- Optimized cgroup with runtime detection --------
    cgroup=""
    runtime="host"
    if [[ -r "$cgfile" ]]; then
        while IFS=: read -r hier _ path; do
            # cgroup v2 uses hier=0
            if [[ "$hier" == "0" ]]; then
                cgroup="$path"
                break
            fi
            # cgroup v1 - look for container paths
            if [[ "$path" == *kubepods* || "$path" == *docker* || "$path" == *containerd* || "$path" == *libpod* ]]; then
                cgroup="$path"
                break
            fi
            cgroup="$path"
        done < "$cgfile"
    fi
    cgroup="${cgroup:0:500}"
    
    # Detect runtime from cgroup path
    case "$cgroup" in
        *docker*) runtime="docker" ;;
        *containerd*) runtime="containerd" ;;
        *kubepods*) runtime="kubernetes" ;;
        *libpod*) runtime="podman" ;;
        *lxc*) runtime="lxc" ;;
        */user.slice*|*/system.slice*) runtime="systemd" ;;
    esac

    net="${pid_networks[$pid]:-}"
    ports=""
    if [[ -n "$net" ]]; then
        ports="$(printf "%s\n" "$net" | tr ',' '\n' | awk -F: '{print $NF}' | paste -sd ',' -)"
    fi

    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t$ports\t$cgroup\t$CGROUP_VERSION\t$runtime")
done


set +o pipefail

if [[ $FORMAT == json ]]; then
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N" \
    | jq -R '
        split("\t") |
        {
            pid: .[0] | tonumber,
            user: .[1],
            cpu_pct: .[2] | tonumber?,
            mem_pct: .[3] | tonumber?,
            rss_kb: .[4] | tonumber?,
            uptime_sec: .[5] | tonumber?,
            command: .[6],
            disk_read_bytes: .[7] | tonumber?,
            disk_write_bytes: .[8] | tonumber?,
            ports: (.[9] | rtrimstr(",")),
            cgroup_path: .[10],
            cgroup_version: .[11],
            container_runtime: .[12]
        }'
else
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N"
fi

# ---------------- Persist (atomic, non-fatal) ----------------
{
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N" > "$TMP_FILE" \
    && mv "$TMP_FILE" "$CACHE_FILE"
} 2>/dev/null || true

set -o pipefail