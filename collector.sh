#!/usr/bin/env bash
#
# collector.sh — Ultra-Optimized Process Collector (v0.3.7)
#
# v0.3.7 - Accurate CPU via Double Sampling:
# - Samples process ticks twice with 0.5s interval
# - Calculates delta for real-time CPU usage
# - Robust for containerized environments
#

set -uo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-50}
FORMAT=${FORMAT:-tsv}
ENABLE_DISK_IO=${ENABLE_DISK_IO:-true}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-0.5}

SYS_PROC="/proc"
[[ -f "$PROC_DIR/stat" ]] && SYS_PROC="$PROC_DIR"

# --- System-wide pre-cached values ---
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
BOOT_TIME=$(awk '/btime/ {print $2}' "$SYS_PROC/stat" 2>/dev/null || echo 0)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' "$SYS_PROC/meminfo" 2>/dev/null || echo 1)
NOW=$(date +%s)
NUM_CORES=$(grep -c ^processor "$SYS_PROC/cpuinfo" 2>/dev/null || echo 1)

# --- UID cache ---
declare -A UID_MAP 2>/dev/null || true

# --- Phase 1: Collect initial snapshots ---
declare -A SNAP1_TICKS 2>/dev/null || true
declare -A SNAP1_DATA 2>/dev/null || true

get_cpu_total() {
    local line
    read -r line < "$SYS_PROC/stat"
    # line: cpu  user nice system idle iowait irq softirq steal guest guest_nice
    set -- $line
    shift  # remove "cpu"
    local total=0
    for v in "$@"; do total=$((total + v)); done
    echo $total
}

TOTAL1=$(get_cpu_total)
max_pids=500
count=0

for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    (( ++count > max_pids )) && break
    
    pid="${piddir##*/}"
    [[ -r "$piddir/stat" ]] || continue
    
    stat_content=$(<"$piddir/stat" 2>/dev/null) || continue
    stat_fields="${stat_content##*)}"
    set -- $stat_fields
    utime=${12:-0}
    stime=${13:-0}
    
    SNAP1_TICKS[$pid]=$((utime + stime))
    SNAP1_DATA[$pid]="$stat_fields"
done

# --- Sleep ---
sleep "$SAMPLE_INTERVAL"

# --- Phase 2: Collect and calculate ---
TOTAL2=$(get_cpu_total)
TOTAL_DIFF=$((TOTAL2 - TOTAL1))
(( TOTAL_DIFF < 1 )) && TOTAL_DIFF=1

rows=()

for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    
    pid="${piddir##*/}"
    
    # Skip if not in snapshot 1
    [[ -z "${SNAP1_TICKS[$pid]:-}" ]] && continue
    
    # --- Basic file checks ---
    [[ -r "$piddir/stat" && -r "$piddir/status" && -r "$piddir/statm" && -r "$piddir/comm" ]] || continue
    
    # --- Command ---
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" || "${comm:0:1}" == "[" ]] && continue
    
    # --- UID and username ---
    uid=$(awk '/^Uid:/ {print $2; exit}' "$piddir/status" 2>/dev/null) || continue
    [[ -z "$uid" ]] && continue
    
    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user" 2>/dev/null || true
    fi
    
    # --- RSS in KB ---
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))
    
    # --- Parse current stat ---
    stat_content=$(<"$piddir/stat" 2>/dev/null) || continue
    stat_fields="${stat_content##*)}"
    set -- $stat_fields
    utime=${12:-0}
    stime=${13:-0}
    starttime=${20:-0}
    
    curr_ticks=$((utime + stime))
    prev_ticks=${SNAP1_TICKS[$pid]:-0}
    diff_ticks=$((curr_ticks - prev_ticks))
    
    # Skip if process restarted (different starttime or negative diff)
    (( diff_ticks < 0 )) && continue
    
    # CPU% = (diff_ticks / TOTAL_DIFF) * 100 * NUM_CORES
    # Using integer math with 2 decimal precision
    cpu_x100=$(( diff_ticks * 10000 * NUM_CORES / TOTAL_DIFF ))
    cpu_pct=$(printf "%d.%02d" $((cpu_x100 / 100)) $((cpu_x100 % 100)))
    
    # Process uptime
    start_sec=$((BOOT_TIME + starttime / CLK_TCK))
    uptime_sec=$((NOW - start_sec))
    (( uptime_sec < 0 )) && uptime_sec=0
    
    # Memory percentage
    if (( MEM_TOTAL_KB > 0 )); then
        mem_x100=$((rss_kb * 10000 / MEM_TOTAL_KB))
        mem_pct=$(printf "%d.%02d" $((mem_x100 / 100)) $((mem_x100 % 100)))
    else
        mem_pct="0.00"
    fi
    
    # --- Disk I/O ---
    rd=0 wr=0
    if [[ "$ENABLE_DISK_IO" == "true" && -r "$piddir/io" ]]; then
        while IFS=': ' read -r key val; do
            case "$key" in
                read_bytes) rd="${val:-0}" ;;
                write_bytes) wr="${val:-0}" ;;
            esac
        done < "$piddir/io" 2>/dev/null
    fi
    
    # Skip zero processes
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue
    
    # --- Cgroup parsing ---
    cgroup_path="/" runtime="host"
    if [[ -r "$piddir/cgroup" ]]; then
        read -r cgline < "$piddir/cgroup" 2>/dev/null
        if [[ -n "$cgline" ]]; then
            cgroup_path="${cgline##*:}"
            cgroup_path="${cgroup_path:0:300}"
            
            case "$cgroup_path" in
                *docker*) runtime="docker" ;;
                *containerd*) runtime="containerd" ;;
                *kubepods*) runtime="kubernetes" ;;
                *libpod*) runtime="podman" ;;
                *lxc*) runtime="lxc" ;;
                */user.slice*|*/system.slice*) runtime="systemd" ;;
            esac
        fi
    fi
    
    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t\t${cgroup_path:-/}\t$runtime")
done

[[ ${#rows[@]} -eq 0 ]] && exit 0

# --- Output ---
set +o pipefail
if [[ $FORMAT == json ]]; then
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k3,3nr -k4,4nr \
    | head -n "$TOP_N" \
    | jq -R 'split("\t") | {pid:.[0]|tonumber,user:.[1],cpu_pct:.[2]|tonumber?,mem_pct:.[3]|tonumber?,rss_kb:.[4]|tonumber?,uptime_sec:.[5]|tonumber?,command:.[6],disk_read_bytes:.[7]|tonumber?,disk_write_bytes:.[8]|tonumber?,ports:.[9],cgroup_path:.[10],container_runtime:.[11]}'
else
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k3,3nr -k4,4nr \
    | head -n "$TOP_N"
fi