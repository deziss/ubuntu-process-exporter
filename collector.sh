#!/usr/bin/env bash
#
# collector.sh — Ultra-Optimized Process Collector
#
# v0.3.2 - Optimized v0.2.9 for speed:
# - Pure bash math instead of awk for percentages
# - grep/sed instead of awk for field extraction
# - Inline cgroup parsing (no subshell)
# - Reduced external command calls
#
# Output (TSV):
# pid user cpu_pct mem_pct rss_kb uptime_sec comm
# disk_read_bytes disk_write_bytes ports cgroup_path cgroup_version container_runtime
#

set -uo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-50}
FORMAT=${FORMAT:-tsv}
ENABLE_DISK_IO=${ENABLE_DISK_IO:-true}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}

# Use /proc directly for system-wide stats
SYS_PROC="/proc"
[[ -f "$PROC_DIR/stat" ]] && SYS_PROC="$PROC_DIR"

# Pre-cache system values (one-time awk calls)
CLK_TCK=$(getconf CLK_TCK 2>/dev/null) || CLK_TCK=100
BOOT_TIME=$(awk '/btime/ {print $2}' "$SYS_PROC/stat" 2>/dev/null) || BOOT_TIME=0
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' "$SYS_PROC/meminfo" 2>/dev/null) || MEM_TOTAL_KB=1
NOW=$(date +%s)
TOTAL_JIFFIES=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s+0}' "$SYS_PROC/stat" 2>/dev/null) || TOTAL_JIFFIES=1

# UID CACHE
declare -A UID_MAP 2>/dev/null || true

# Pre-compute multipliers for percentage calculation (avoid awk in loop)
# cpu_pct = (proc_jiffies / TOTAL_JIFFIES) * 100
# We'll use: cpu_pct_x100 = proc_jiffies * 10000 / TOTAL_JIFFIES
# Then format later

# Collect processes
rows=()
count=0
max_pids=500

for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    (( ++count > max_pids )) && break
    
    pid="${piddir##*/}"
    
    # Quick file checks
    [[ -r "$piddir/stat" && -r "$piddir/status" && -r "$piddir/statm" ]] || continue
    
    # Read comm directly
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" || "${comm:0:1}" == "[" ]] && continue
    
    # Get UID using grep (faster than awk for single line)
    uid=$(grep -m1 '^Uid:' "$piddir/status" 2>/dev/null | cut -f2) || continue
    [[ -z "$uid" ]] && continue
    
    # Username lookup with cache
    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || user="$uid"
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user" 2>/dev/null || true
    fi
    
    # RSS from statm (second field)
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))
    
    # Parse stat file for jiffies and starttime
    stat_content=$(<"$piddir/stat" 2>/dev/null) || continue
    # Remove everything up to and including the command (in parens)
    stat_fields="${stat_content#*(*)}"
    
    # Split into array - fields are: state(1) ppid(2) ... utime(12) stime(13) ... starttime(20)
    set -- $stat_fields
    utime=${12:-0}
    stime=${13:-0}
    starttime=${20:-0}
    
    proc_jiffies=$((utime + stime))
    uptime_sec=$((NOW - BOOT_TIME - starttime / CLK_TCK))
    (( uptime_sec < 0 )) && uptime_sec=0
    
    # CPU percentage using bash integer math then format
    # cpu_pct = proc_jiffies * 10000 / TOTAL_JIFFIES, then divide by 100 for decimal
    if (( TOTAL_JIFFIES > 0 )); then
        cpu_int=$((proc_jiffies * 10000 / TOTAL_JIFFIES))
        cpu_pct="$((cpu_int / 100)).$((cpu_int % 100))"
        # Pad with leading zero if needed
        [[ ${#cpu_pct} -lt 4 ]] && cpu_pct="0.$((cpu_int % 100))"
    else
        cpu_pct="0.00"
    fi
    
    # Memory percentage
    if (( MEM_TOTAL_KB > 0 )); then
        mem_int=$((rss_kb * 10000 / MEM_TOTAL_KB))
        mem_pct="$((mem_int / 100)).$((mem_int % 100))"
        [[ ${#mem_pct} -lt 4 ]] && mem_pct="0.$((mem_int % 100))"
    else
        mem_pct="0.00"
    fi
    
    # Disk I/O (simplified - use grep instead of awk)
    rd=0 wr=0
    if [[ "$ENABLE_DISK_IO" == "true" && -r "$piddir/io" ]]; then
        while IFS=': ' read -r key val; do
            case "$key" in
                read_bytes) rd="${val:-0}" ;;
                write_bytes) wr="${val:-0}" ;;
            esac
        done < "$piddir/io" 2>/dev/null
    fi
    
    # Filter zero-everything processes
    [[ "$cpu_pct" == "0.0" || "$cpu_pct" == "0.00" ]] && [[ "$rss_kb" -eq 0 ]] && [[ "$rd" -eq 0 ]] && [[ "$wr" -eq 0 ]] && continue
    
    # Inline cgroup parsing (no subshell)
    cgroup_path="/" runtime="host"
    if [[ -r "$piddir/cgroup" ]]; then
        # Read first line
        read -r cgline < "$piddir/cgroup" 2>/dev/null
        if [[ -n "$cgline" ]]; then
            # Extract path (third field after :)
            cgroup_path="${cgline##*:}"
            cgroup_path="${cgroup_path:0:300}"
            
            # Detect runtime
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

# Exit if no data
[[ ${#rows[@]} -eq 0 ]] && exit 0

# Output (sort and head)
set +o pipefail
if [[ $FORMAT == json ]]; then
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N" \
    | jq -R 'split("\t") | {pid:.[0]|tonumber,user:.[1],cpu_pct:.[2]|tonumber?,mem_pct:.[3]|tonumber?,rss_kb:.[4]|tonumber?,uptime_sec:.[5]|tonumber?,command:.[6],disk_read_bytes:.[7]|tonumber?,disk_write_bytes:.[8]|tonumber?,ports:.[9],cgroup_path:.[10],container_runtime:.[11]}'
else
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N"
fi