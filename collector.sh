#!/usr/bin/env bash
#
# collector.sh — Ultra-Optimized Process Collector (v0.5.0)
#
# v0.5.0 - Single-Pass Architecture:
# - Pre-build INODE map
# - Snapshot CPU (Phase 1)
# - Single efficient pass (Phase 2):
#   - Collects CPU/Mem/Disk
#   - Filters inactive
#   - Resolves ports/metadata immediately
# - No intermediate arrays or second loops
#

set -uo pipefail

PROC_DIR=${PROC_DIR:-/proc}
TOP_N=${TOP_N:-50}
FORMAT=${FORMAT:-tsv}
ENABLE_DISK_IO=${ENABLE_DISK_IO:-true}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-0.5}
ENABLE_PORTS=${ENABLE_PORTS:-true}

SYS_PROC="/proc"
[[ -f "$PROC_DIR/stat" ]] && SYS_PROC="$PROC_DIR"

# --- System-wide pre-cached values ---
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
BOOT_TIME=$(awk '/btime/ {print $2}' "$SYS_PROC/stat" 2>/dev/null || echo 0)
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' "$SYS_PROC/meminfo" 2>/dev/null || echo 1)
NOW=$(date +%s)
NUM_CORES=$(grep -c ^processor "$SYS_PROC/cpuinfo" 2>/dev/null || echo 1)
TAB=$'\t'

# --- UID and PORT Maps ---
declare -A UID_MAP
declare -A INODE_PORT

# ============================================================
# STEP 0: Build INODE → PORT Map (ONCE)
# ============================================================
if [[ "$ENABLE_PORTS" == "true" ]]; then
    for proto in tcp tcp6 udp udp6; do
        file="$SYS_PROC/net/$proto"
        [[ -r "$file" ]] || continue

        # Fast parsing using block read
        # Filter LISTEN (0A) for TCP/TCP6
        tail -n +2 "$file" 2>/dev/null | while read -r sl local rem st _ _ _ _ _ inode _; do
            [[ -n "$inode" ]] || continue
            if [[ "$proto" == tcp || "$proto" == tcp6 ]]; then
                [[ "$st" == "0A" ]] || continue
            fi
            # Hex to Dec conversion logic
            # local is usually IP:PORT in hex
            port_hex="${local##*:}"
            port=$((16#$port_hex))
            INODE_PORT[$inode]=$port
        done
    done
fi

# ============================================================
# STEP 1: Snapshot CPU Ticks (T1)
# ============================================================
declare -A PREV_TICKS
declare -A PREV_PIDS

# System Total T1
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T1=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))

# Process Ticks T1
for statfile in "$PROC_DIR"/[0-9]*/stat; do
    [[ -r "$statfile" ]] || continue
    read -r line < "$statfile" || continue
    
    pid=${line%% *}
    # Fast parse ticks
    rest="${line##*)}"
    # state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime
    read -r _ _ _ _ _ _ _ _ _ _ _ utime stime _ <<< "$rest"
    
    PREV_TICKS[$pid]=$((utime + stime))
    PREV_PIDS[$pid]=1
done

# ============================================================
# STEP 2: Sleep (Delta)
# ============================================================
sleep "$SAMPLE_INTERVAL"

# ============================================================
# STEP 3: Single Pass (Collect + Filter + Resolve)
# ============================================================
rows=()
count=0
max_pids=500

# System Total T2
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T2=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
DIFF_TOTAL=$((TOTAL_T2 - TOTAL_T1))
(( DIFF_TOTAL < 1 )) && DIFF_TOTAL=1

# Memory percentage helper
mem_percent() {
    local rss_kb=$1
    if (( MEM_TOTAL_KB > 0 )); then
        local pct=$(( rss_kb * 10000 / MEM_TOTAL_KB ))
        printf "%d.%02d" $((pct/100)) $((pct%100))
    else
        echo "0.00"
    fi
}

for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    (( ++count > max_pids )) && break

    pid="${piddir##*/}"
    
    # 1. Skip new processes (must exist in snapshot 1 for delta CPU)
    [[ -z "${PREV_PIDS[$pid]:-}" ]] && continue

    # 2. Check files exist
    [[ -r "$piddir/stat" && -r "$piddir/status" && -r "$piddir/statm" && -r "$piddir/comm" ]] || continue

    # 3. UID / User
    uid=$(awk '/^Uid:/ {print $2; exit}' "$piddir/status" 2>/dev/null) || continue
    [[ -z "$uid" ]] && continue

    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user"
    fi

    # 4. Command
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" ]] && continue

    # 5. Memory using read
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))

    # 6. CPU Delta
    if read -r line < "$piddir/stat"; then
        rest="${line##*)}"
        read -r _ _ _ _ _ _ _ _ _ _ _ utime stime starttime _ <<< "$rest"
        
        curr_ticks=$((utime + stime))
        prev_tick=${PREV_TICKS[$pid]:-0}
        diff_proc=$((curr_ticks - prev_tick))
        
        (( diff_proc < 0 )) && continue # Process restarted or PID reused
        
        pct_int=$(( diff_proc * 10000 * NUM_CORES / DIFF_TOTAL ))
        cpu_pct=$(printf "%d.%02d" $((pct_int/100)) $((pct_int%100)))

        # Uptime
        start_sec=$((BOOT_TIME + starttime / CLK_TCK))
        uptime_sec=$((NOW - start_sec))
        (( uptime_sec < 0 )) && uptime_sec=0
    else
        continue
    fi

    # 7. Disk I/O
    rd=0 wr=0
    if [[ "$ENABLE_DISK_IO" == "true" && -r "$piddir/io" ]]; then
        while IFS=': ' read -r key val; do
            case "$key" in
                read_bytes) rd="${val:-0}" ;;
                write_bytes) wr="${val:-0}" ;;
            esac
        done < "$piddir/io" 2>/dev/null
    fi

    mem_pct=$(mem_percent "$rss_kb")

    # 8. EARLY FILTER - Skip inactive
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue

    # 9. Cgroup (Fast)
    cgroup_path="" runtime="host"
    if [[ -r "$piddir/cgroup" ]]; then
        while IFS=: read -r _ _ path; do
            if [[ -n "$path" && "$path" != "/" ]]; then
                 cgroup_path="$path"
                 # Break on known container patterns
                 [[ "$path" == *docker* || "$path" == *containerd* || "$path" == *kubepods* || "$path" == *libpod* ]] && break
            fi
        done < "$piddir/cgroup" 2>/dev/null
    fi
    # Trim logic
    cgroup_path="${cgroup_path##*:}"
    cgroup_path="${cgroup_path:0:300}"
    
    case "$cgroup_path" in
        *docker*) runtime="docker" ;;
        *containerd*) runtime="containerd" ;;
        *kubepods*) runtime="kubernetes" ;;
        *libpod*) runtime="podman" ;;
        *lxc*) runtime="lxc" ;;
        */user.slice*|*/system.slice*) runtime="systemd" ;;
    esac

    # 10. Resolve Ports (Deferred)
    ports_str=""
    if [[ "$ENABLE_PORTS" == "true" && -d "$piddir/fd" ]]; then
        ports_array=()
        for fd in "$piddir/fd"/*; do
            link=$(readlink "$fd" 2>/dev/null) || continue
            [[ "$link" =~ socket:\[([0-9]+)\] ]] || continue
            inode="${BASH_REMATCH[1]}"
            [[ -n "${INODE_PORT[$inode]:-}" ]] && ports_array+=("${INODE_PORT[$inode]}")
        done
        ((${#ports_array[@]})) && printf -v ports_str "%s," "${ports_array[@]}"
        ports_str="${ports_str%,}"
    fi

    # 11. Add Row
    rows+=("$pid$TAB$user$TAB$cpu_pct$TAB$mem_pct$TAB$rss_kb$TAB$uptime_sec$TAB$comm$TAB$rd$TAB$wr$TAB$ports_str$TAB$cgroup_path$TAB$runtime")
done

[[ ${#rows[@]} -eq 0 ]] && exit 0

# ============================================================
# OUTPUT
# ============================================================
set +o pipefail
if [[ $FORMAT == json ]]; then
    printf "%b\n" "${rows[@]}" \
    | sort -t"$TAB" -k3,3nr -k4,4nr \
    | head -n "$TOP_N" \
    | jq -R 'split("\t") | {pid:.[0]|tonumber,user:.[1],cpu_pct:.[2]|tonumber?,mem_pct:.[3]|tonumber?,rss_kb:.[4]|tonumber?,uptime_sec:.[5]|tonumber?,command:.[6],disk_read_bytes:.[7]|tonumber?,disk_write_bytes:.[8]|tonumber?,ports:.[9],cgroup_path:.[10],container_runtime:.[11]}'
else
    printf "%b\n" "${rows[@]}" \
    | sort -t"$TAB" -k3,3nr -k4,4nr \
    | head -n "$TOP_N"
fi