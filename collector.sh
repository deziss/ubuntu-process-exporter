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
TOP_N=${TOP_N:-50}
FORMAT=${FORMAT:-tsv}
SUDO_LSOF=${SUDO_LSOF:-sudo}
ENABLE_DISK_IO=${ENABLE_DISK_IO:-true}

CACHE_DIR=${CACHE_DIR:-/var/run/upm}
CACHE_FILE="$CACHE_DIR/collector.cache"
TMP_FILE="$CACHE_FILE.tmp"

CLK_TCK=$(getconf CLK_TCK)
BOOT_TIME=$(awk '/btime/ {print $2}' /proc/stat)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
NOW=$(date +%s)


#--------- PREPARE CACHE DIR ----------
[[ -d "$CACHE_DIR" ]] || sudo mkdir -p "$CACHE_DIR"

# --------- PRECOMPUTE ----------
TOTAL_JIFFIES=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s}' /proc/stat)

# --------- UID CACHE ----------
declare -A UID_MAP

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

    # -------- Optimized cgroup --------
    cgroup=""
    if [[ -r "$cgfile" ]]; then
        while IFS=: read -r hier _ path; do
            if [[ "$hier" == "0" ]]; then
                cgroup="$path"
                break
            fi
            if [[ "$path" == *kubepods* || "$path" == *docker* || "$path" == *containerd* || "$path" == *libpod* ]]; then
                cgroup="$path"
                break
            fi
            cgroup="$path"
        done < "$cgfile"
    fi
    cgroup="${cgroup:0:500}"

    rows+=("$pid	$uid	$user	$cpu_pct	$mem_pct	$rss_kb	$uptime_sec	$comm	$rd	$wr		$cgroup")
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


# ---------------- Persist (atomic) ----------------
printf "%s\n" "${rows[@]}" \
| sort -t$'\t' -k4,4nr -k5,5nr \
| head -n "$TOP_N" > "$TMP_FILE"

mv "$TMP_FILE" "$CACHE_FILE"