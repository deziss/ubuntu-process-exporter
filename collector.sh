#!/usr/bin/env bash
#
# collector.sh — Ultra-Optimized Process Collector (v0.4.1)
#
# v0.4.1 - High-Performance Architecture:
# 1. Snapshot CPU ticks
# 2. Sleep (delta CPU)
# 3. Scan all PIDs (FAST): cpu, mem, disk → filter inactive → store ACTIVE_PIDS
# 4. Build inode → port map ONCE
# 5. Scan ports ONLY for ACTIVE_PIDS
# 6. Output / sort / export
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

# --- UID cache ---
declare -A UID_MAP

# ============================================================
# STEP 1: Snapshot CPU Ticks (T1)
# ============================================================
declare -A PREV_TICKS
declare -A PREV_PIDS

read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T1=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))

for statfile in "$PROC_DIR"/[0-9]*/stat; do
    [[ -r "$statfile" ]] || continue
    read -r line < "$statfile" || continue
    
    pid=${line%% *}
    rest="${line##*)}"
    read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime _ <<< "$rest"
    
    PREV_TICKS[$pid]=$((utime + stime))
    PREV_PIDS[$pid]=1
done

# ============================================================
# STEP 2: Sleep (Delta CPU)
# ============================================================
sleep "$SAMPLE_INTERVAL"

# ============================================================
# STEP 3: Scan All PIDs (FAST) → Filter Inactive → Store ACTIVE_PIDS
# ============================================================
declare -A ACTIVE_DATA
ACTIVE_PIDS=()
count=0
max_pids=500

# Get System Total Ticks (T2)
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T2=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
DIFF_TOTAL=$((TOTAL_T2 - TOTAL_T1))
(( DIFF_TOTAL < 1 )) && DIFF_TOTAL=1

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
    
    # Skip new processes (not in snapshot 1)
    [[ -z "${PREV_PIDS[$pid]:-}" ]] && continue

    # Basic file checks
    [[ -r "$piddir/stat" && -r "$piddir/status" && -r "$piddir/statm" && -r "$piddir/comm" ]] || continue

    # UID and username
    uid=$(awk '/^Uid:/ {print $2; exit}' "$piddir/status" 2>/dev/null) || continue
    [[ -z "$uid" ]] && continue

    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user"
    fi

    # Comm
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" ]] && continue

    # RSS in KB
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))

    # CPU Delta
    read -r line < "$piddir/stat" || continue
    rest="${line##*)}"
    read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime starttime _ <<< "$rest"
    
    curr_ticks=$((utime + stime))
    prev_tick=${PREV_TICKS[$pid]:-0}
    diff_proc=$((curr_ticks - prev_tick))
    
    (( diff_proc < 0 )) && continue
    
    pct_int=$(( diff_proc * 10000 * NUM_CORES / DIFF_TOTAL ))
    cpu_pct=$(printf "%d.%02d" $((pct_int/100)) $((pct_int%100)))

    # Uptime
    start_sec=$((BOOT_TIME + starttime / CLK_TCK))
    uptime_sec=$((NOW - start_sec))
    (( uptime_sec < 0 )) && uptime_sec=0

    mem_pct=$(mem_percent "$rss_kb")

    # Disk I/O
    rd=0 wr=0
    if [[ "$ENABLE_DISK_IO" == "true" && -r "$piddir/io" ]]; then
        while IFS=': ' read -r key val; do
            case "$key" in
                read_bytes) rd="${val:-0}" ;;
                write_bytes) wr="${val:-0}" ;;
            esac
        done < "$piddir/io" 2>/dev/null
    fi

    # --- FILTER INACTIVE ---
    [[ "$cpu_pct" == "0.00" && "$rss_kb" -eq 0 && "$rd" -eq 0 && "$wr" -eq 0 ]] && continue

    # Cgroup parsing
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

    # Store active PID data
    ACTIVE_PIDS+=("$pid")
    ACTIVE_DATA[$pid]="$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t$cgroup_path\t$runtime"
done

[[ ${#ACTIVE_PIDS[@]} -eq 0 ]] && exit 0

# ============================================================
# STEP 4: Build Inode → Port Map ONCE
# ============================================================
declare -A INODE_PORT

if [[ "$ENABLE_PORTS" == "true" ]]; then
    # Parse /proc/net/tcp (LISTEN = state 0A)
    while read -r sl local rem st _ _ _ _ _ inode _; do
        [[ "$st" == "0A" ]] || continue
        port=$((16#${local##*:}))
        INODE_PORT[$inode]=$port
    done < <(tail -n +2 "$SYS_PROC/net/tcp" 2>/dev/null)

    # Parse /proc/net/tcp6
    while read -r sl local rem st _ _ _ _ _ inode _; do
        [[ "$st" == "0A" ]] || continue
        port=$((16#${local##*:}))
        INODE_PORT[$inode]=$port
    done < <(tail -n +2 "$SYS_PROC/net/tcp6" 2>/dev/null)

    # Parse /proc/net/udp
    while read -r sl local rem st _ _ _ _ _ inode _; do
        port=$((16#${local##*:}))
        INODE_PORT[$inode]=$port
    done < <(tail -n +2 "$SYS_PROC/net/udp" 2>/dev/null)

    # Parse /proc/net/udp6
    while read -r sl local rem st _ _ _ _ _ inode _; do
        port=$((16#${local##*:}))
        INODE_PORT[$inode]=$port
    done < <(tail -n +2 "$SYS_PROC/net/udp6" 2>/dev/null)
fi

# ============================================================
# STEP 5: Scan Ports ONLY for ACTIVE_PIDS
# ============================================================
get_ports_for_pid() {
    local pid=$1
    local ports=()
    local fd_dir="$PROC_DIR/$pid/fd"
    
    [[ -d "$fd_dir" ]] || return
    
    for fd in "$fd_dir"/*; do
        link=$(readlink "$fd" 2>/dev/null) || continue
        [[ $link =~ socket:\[([0-9]+)\] ]] || continue
        local inode=${BASH_REMATCH[1]}
        [[ -n "${INODE_PORT[$inode]:-}" ]] && ports+=("${INODE_PORT[$inode]}")
    done
    
    ((${#ports[@]})) && printf "%s" "$(IFS=,; echo "${ports[*]}")"
}

rows=()
for pid in "${ACTIVE_PIDS[@]}"; do
    data="${ACTIVE_DATA[$pid]}"
    
    # Get ports for this PID
    if [[ "$ENABLE_PORTS" == "true" ]]; then
        ports=$(get_ports_for_pid "$pid")
    else
        ports=""
    fi
    
    IFS=$'\t' read -r user cpu_pct mem_pct rss_kb uptime_sec comm rd wr cgroup_path runtime <<< "$data"
    
    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t$ports\t$cgroup_path\t$runtime")
done

# ============================================================
# STEP 6: Output / Sort / Export
# ============================================================
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