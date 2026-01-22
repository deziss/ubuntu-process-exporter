#!/usr/bin/env bash
#
# collector.sh — Process Collector (Dual Cgroup v1/v2 Support)
#
# v0.2.9 - Simplified for cgroup v1 compatibility:
# - Removed lsof dependency (optional, non-blocking)
# - Simplified cgroup parsing
# - Faster iteration with fewer subshells
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

# Use /proc directly for system-wide stats (even if PROC_DIR is /host/proc)
SYS_PROC="/proc"
[[ -f "$PROC_DIR/stat" ]] && SYS_PROC="$PROC_DIR"

# Pre-cache system values
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
BOOT_TIME=$(awk '/btime/ {print $2}' "$SYS_PROC/stat" 2>/dev/null || echo 0)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' "$SYS_PROC/meminfo" 2>/dev/null || echo 1)
NOW=$(date +%s)
TOTAL_JIFFIES=$(awk '/^cpu / {for(i=2;i<=8;i++) s+=$i} END{print s+0}' "$SYS_PROC/stat" 2>/dev/null || echo 1)

# --------- Detect Cgroup Version ---------
if [[ -f "$CGROUP_DIR/cgroup.controllers" ]]; then
    CGROUP_VERSION="v2"
elif [[ -d "$CGROUP_DIR/cpu" ]] || [[ -d "$CGROUP_DIR/cpuacct" ]] || [[ -d "$CGROUP_DIR/memory" ]]; then
    CGROUP_VERSION="v1"
else
    CGROUP_VERSION="unknown"
fi

# --------- UID CACHE ----------
declare -A UID_MAP 2>/dev/null || true

# --------- Simple cgroup parser ---------
get_cgroup_info() {
    local cgfile="$1"
    local cgroup_path="" runtime="host"
    
    if [[ ! -r "$cgfile" ]]; then
        echo "/ $CGROUP_VERSION host"
        return
    fi
    
    # Just read first line for v2, first few for v1
    local content
    content=$(head -5 "$cgfile" 2>/dev/null) || content=""
    
    if [[ "$CGROUP_VERSION" == "v2" ]]; then
        cgroup_path=$(echo "$content" | head -1 | cut -d: -f3)
    else
        # v1: find container path
        cgroup_path=$(echo "$content" | grep -m1 -oE '/(docker|containerd|kubepods|libpod|lxc)/[^[:space:]]*' || echo "/")
        if [[ -z "$cgroup_path" ]]; then
            cgroup_path=$(echo "$content" | head -1 | cut -d: -f3)
        fi
    fi
    
    # Detect runtime from path
    case "$cgroup_path" in
        *docker*) runtime="docker" ;;
        *containerd*) runtime="containerd" ;;
        *kubepods*) runtime="kubernetes" ;;
        *libpod*) runtime="podman" ;;
        *lxc*) runtime="lxc" ;;
        */user.slice*|*/system.slice*) runtime="systemd" ;;
    esac
    
    echo "${cgroup_path:0:300} $CGROUP_VERSION $runtime"
}

# ----------------------------
# Collect processes
# ----------------------------
rows=()
count=0
max_pids=500  # Limit to avoid timeouts

for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    (( count++ > max_pids )) && break
    
    pid="${piddir##*/}"
    
    # Quick existence check
    [[ -r "$piddir/stat" ]] || continue
    [[ -r "$piddir/status" ]] || continue
    [[ -r "$piddir/statm" ]] || continue
    
    # Read comm
    comm=""
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" || "$comm" == \[* ]] && continue
    
    # Get UID
    uid=$(awk '/^Uid:/ {print $2; exit}' "$piddir/status" 2>/dev/null)
    [[ -z "$uid" ]] && continue
    
    # Username (cached or fallback to UID)
    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || user="$uid"
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user" 2>/dev/null || true
    fi
    
    # RSS from statm
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))
    
    # Parse stat file for jiffies and starttime
    stat_content=$(<"$piddir/stat" 2>/dev/null) || continue
    # Extract fields after command (which may contain spaces/parens)
    stat_fields="${stat_content#*(*)}"
    
    # Get starttime (field 22 after the command) and jiffies (14+15)
    set -- $stat_fields
    utime=${12:-0}
    stime=${13:-0}
    starttime=${20:-0}
    
    proc_jiffies=$((utime + stime))
    uptime_sec=$((NOW - (BOOT_TIME + starttime / CLK_TCK)))
    (( uptime_sec < 0 )) && uptime_sec=0
    
    # CPU and memory percentages
    if (( TOTAL_JIFFIES > 0 )); then
        cpu_pct=$(awk "BEGIN {printf \"%.2f\", ($proc_jiffies/$TOTAL_JIFFIES)*100}")
    else
        cpu_pct="0.00"
    fi
    
    if (( MEM_TOTAL_KB > 0 )); then
        mem_pct=$(awk "BEGIN {printf \"%.2f\", ($rss_kb/$MEM_TOTAL_KB)*100}")
    else
        mem_pct="0.00"
    fi
    
    # Disk I/O (optional)
    rd=0 wr=0
    if [[ "$ENABLE_DISK_IO" == "true" ]] && [[ -r "$piddir/io" ]]; then
        eval $(awk '/read_bytes:/ {print "rd="$2} /write_bytes:/ {print "wr="$2}' "$piddir/io" 2>/dev/null)
    fi
    
    # Filter zero-everything processes
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue
    
    # Cgroup info
    read -r cgroup_path cgroup_version runtime <<< "$(get_cgroup_info "$piddir/cgroup")"
    
    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t\t${cgroup_path:-/}\t${cgroup_version:-unknown}\t${runtime:-host}")
done

# Exit if no data
[[ ${#rows[@]} -eq 0 ]] && exit 0

# Output
set +o pipefail
if [[ $FORMAT == json ]]; then
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N" \
    | jq -R 'split("\t") | {pid:.[0]|tonumber,user:.[1],cpu_pct:.[2]|tonumber?,mem_pct:.[3]|tonumber?,rss_kb:.[4]|tonumber?,uptime_sec:.[5]|tonumber?,command:.[6],disk_read_bytes:.[7]|tonumber?,disk_write_bytes:.[8]|tonumber?,ports:.[9],cgroup_path:.[10],cgroup_version:.[11],container_runtime:.[12]}'
else
    printf "%b\n" "${rows[@]}" \
    | sort -t$'\t' -k4,4nr -k5,5nr \
    | head -n "$TOP_N"
fi