#!/usr/bin/env bash
#
# collector.sh — Enhanced Raw Process Collector (Dual Cgroup v1/v2 Support)
#
# v0.2.8 - Fixed cgroup v1 compatibility:
# - Added timeout to cgroup file reads
# - Optimized lsof handling
# - Better error handling
#
# Output (TSV):
# pid user cpu_pct mem_pct rss_kb uptime_sec comm
# disk_read_bytes disk_write_bytes ports cgroup_path cgroup_version container_runtime
#
# Supports: cgroup v1 and v2, TSV / JSON
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

# Pre-cache frequently used values
CLK_TCK=$(getconf CLK_TCK)
BOOT_TIME=$(awk '/btime/ {print $2}' /proc/stat)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
NOW=$(date +%s)

# --------- Detect Cgroup Version (cached) ---------
detect_cgroup_version() {
    if [[ -f "$CGROUP_DIR/cgroup.controllers" ]]; then
        echo "v2"
    elif [[ -d "$CGROUP_DIR/cpu" ]] || [[ -d "$CGROUP_DIR/cpuacct" ]] || [[ -d "$CGROUP_DIR/memory" ]]; then
        echo "v1"
    else
        echo "unknown"
    fi
}

CGROUP_VERSION=$(detect_cgroup_version)


#--------- PREPARE CACHE DIR ----------
if [[ -d "$CACHE_DIR" ]] && [[ -w "$CACHE_DIR" ]]; then
    : # Cache dir exists and is writable
elif command -v sudo >/dev/null 2>&1 && [[ -n "${SUDO_LSOF:-}" ]]; then
    sudo mkdir -p "$CACHE_DIR" 2>/dev/null || mkdir -p "$CACHE_DIR" 2>/dev/null || true
else
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
fi

# --------- PRECOMPUTE ----------
TOTAL_JIFFIES=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s}' /proc/stat)

# --------- UID CACHE (associative array) ----------
declare -A UID_MAP

# --------- Parse Cgroup Path (v1 & v2) - Fixed for v1 ---------
parse_cgroup_path() {
    local pid=$1
    local cgfile="$PROC_DIR/$pid/cgroup"
    local cgroup_path=""
    local cgroup_version="unknown"
    local runtime="host"

    [[ ! -r "$cgfile" ]] && { echo -e "\t\t"; return; }

    if [[ "$CGROUP_VERSION" == "v2" ]]; then
        # Cgroup v2: single line, format: 0::/path/to/cgroup
        cgroup_path=$(head -1 "$cgfile" 2>/dev/null | cut -d: -f3) || cgroup_path=""
        cgroup_version="v2"
    else
        # Cgroup v1: read first few lines only to avoid hanging
        local line_count=0
        while IFS=: read -r hier _ path && (( line_count++ < 15 )); do
            case "$path" in
                *docker*)
                    cgroup_path="$path"; runtime="docker"; break ;;
                *containerd*)
                    cgroup_path="$path"; runtime="containerd"; break ;;
                *kubepods*)
                    cgroup_path="$path"; runtime="kubernetes"; break ;;
                *libpod*)
                    cgroup_path="$path"; runtime="podman"; break ;;
                *lxc*)
                    cgroup_path="$path"; runtime="lxc"; break ;;
                */user.slice*|*/system.slice*)
                    cgroup_path="$path"; runtime="systemd"; break ;;
                *)
                    [[ -z "$cgroup_path" ]] && cgroup_path="$path" ;;
            esac
        done < "$cgfile"
        cgroup_version="v1"
    fi

    # Detect runtime from v2 paths
    if [[ "$CGROUP_VERSION" == "v2" ]] && [[ "$runtime" == "host" ]]; then
        case "$cgroup_path" in
            *docker*) runtime="docker" ;;
            *containerd*) runtime="containerd" ;;
            *kubepods*) runtime="kubernetes" ;;
            *libpod*) runtime="podman" ;;
            *lxc*) runtime="lxc" ;;
            */user.slice*|*/system.slice*) runtime="systemd" ;;
        esac
    fi

    # Truncate for output
    echo -e "${cgroup_path:0:300}\t$cgroup_version\t$runtime"
}

# -------------------------------------
# Network collection (PID → port map) - Fixed timeout
# -------------------------------------
declare -A pid_networks

# Only run lsof if SUDO_LSOF is set and lsof exists
if [[ -n "${SUDO_LSOF:-}" ]] && command -v lsof >/dev/null 2>&1; then
    # Use timeout to prevent hanging on sudo password prompt
    if timeout 5 $SUDO_LSOF lsof -i -P -n >/dev/null 2>&1; then
        while read -r _ pid _ _ _ _ _ _ name; do
            [[ $name == *:* ]] || continue
            port="${name##*:}"
            [[ $port =~ ^[0-9]+$ ]] || continue
            pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
        done < <(timeout 10 $SUDO_LSOF lsof -i -P -n 2>/dev/null | grep -E 'LISTEN|UDP' || true)
    fi
elif command -v lsof >/dev/null 2>&1; then
    # Try without sudo
    while read -r _ pid _ _ _ _ _ _ name; do
        [[ $name == *:* ]] || continue
        port="${name##*:}"
        [[ $port =~ ^[0-9]+$ ]] || continue
        pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
    done < <(timeout 10 lsof -i -P -n 2>/dev/null | grep -E 'LISTEN|UDP' || true)
fi

# ----------------
# Disk I/O helper - Optimized
# ----------------
get_disk_io() {
    [[ "$ENABLE_DISK_IO" != "true" ]] && { echo "0 0"; return; }
    local io="$PROC_DIR/$1/io"
    if [[ -r "$io" ]]; then
        awk '
          /read_bytes:/  {r=$2}
          /write_bytes:/ {w=$2}
          END {print r+0, w+0}
        ' "$io" 2>/dev/null || echo "0 0"
    else
        echo "0 0"
    fi
}

# ----------------------------
# Collect processes (PROC-ONLY) - Optimized
# ----------------------------
rows=()

for pid in "$PROC_DIR"/[0-9]*; do
    pid="${pid##*/}"

    stat="$PROC_DIR/$pid/stat"
    status="$PROC_DIR/$pid/status"
    statm="$PROC_DIR/$pid/statm"

    [[ -r "$stat" && -r "$status" && -r "$statm" ]] || continue

    # Read comm directly (optimized)
    read -r comm < "$PROC_DIR/$pid/comm" 2>/dev/null || continue
    [[ -z "$comm" || "$comm" == \[* ]] && continue

    # Extract UID with optimized awk
    uid=$(awk '/^Uid:/ {print $2; exit}' "$status" 2>/dev/null) || continue
    [[ -z "$uid" ]] && continue

    # Cache UID → username lookup
    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || echo "$uid")
        UID_MAP[$uid]="$user"
    fi

    # Read statm for RSS (optimized - single read)
    read -r _ rss_pages _ < "$statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))

    # Read stat for starttime and jiffies (optimized - single awk)
    read -r starttime proc_jiffies <<< $(awk '{print $22, $14+$15}' "$stat" 2>/dev/null) || continue
    [[ -z "$starttime" ]] && continue
    uptime_sec=$(( NOW - (BOOT_TIME + starttime / CLK_TCK) ))
    (( uptime_sec < 0 )) && uptime_sec=0

    # Calculate CPU and memory percentages
    cpu_pct=$(awk -v p="$proc_jiffies" -v t="$TOTAL_JIFFIES" \
        'BEGIN { printf "%.2f", (t>0 ? (p/t)*100 : 0) }')

    mem_pct=$(awk -v r="$rss_kb" -v t="$MEM_TOTAL_KB" \
        'BEGIN { printf "%.2f", (t>0 ? (r/t)*100 : 0) }')

    read rd wr <<< "$(get_disk_io "$pid")"

    # Safe aggressive filter
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue

    # -------- Parse cgroup (v1 & v2) --------
    read cgroup_path cgroup_version runtime <<< "$(parse_cgroup_path "$pid")" || continue

    # Extract ports (optimized)
    net="${pid_networks[$pid]:-}"
    ports=""
    if [[ -n "$net" ]]; then
        ports=$(printf "%s" "$net" | tr ':,' '\n' | grep -E '^[0-9]+$' | sort -u | paste -sd ',' - 2>/dev/null) || ports=""
    fi

    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t$ports\t$cgroup_path\t$cgroup_version\t$runtime")
done


set +o pipefail

if [[ ${#rows[@]} -eq 0 ]]; then
    # No processes collected, exit cleanly
    exit 0
fi

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