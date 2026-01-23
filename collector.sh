#!/usr/bin/env bash
#
# collector.sh — Ultra-Optimized Process Collector (v0.3.6)
#
# v0.3.6 - Instant CPU Usage:
# - Implements "Double Sampling" technique for accurate CPU %
# - Calculates delta over 0.5s interval
# - Corrects "0.0%" issue for long-running processes
# - Maintains v0.3.5 optimizations (pure bash math, regex metadata)
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

# --- UID cache ---
declare -A UID_MAP

# --- Network collection (PID → port map) ---
declare -A pid_networks
# Use ${VAR-default} to allow SUDO_LSOF="" to disable sudo
SUDO_LSOF=${SUDO_LSOF-sudo}

# Only collect ports if SUDO_LSOF is not explicitly empty
if [[ -n "$SUDO_LSOF" ]] && $SUDO_LSOF lsof -i -P -n >/dev/null 2>&1; then
    while read -r _ pid _ _ _ _ _ _ name; do
        [[ $name == *:* ]] || continue
        port="${name##*:}"
        [[ $port =~ ^[0-9]+$ ]] || continue
        pid_networks[$pid]="${pid_networks[$pid]:-}:$port,"
    done < <($SUDO_LSOF lsof -i -P -n 2>/dev/null | grep -E 'LISTEN|UDP')
fi

# --- Phase 1: Snapshot Process Ticks ---
declare -A PREV_TICKS
declare -A PREV_PIDS

# Get System Total Ticks (T1)
# /proc/stat: cpu  22312 34 22 12232 ...
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T1=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))

# Read all process ticks efficiently
# We use a glob loop but only read the stat file
for statfile in "$PROC_DIR"/[0-9]*/stat; do
    [[ -r "$statfile" ]] || continue
    # Fast read
    read -r line < "$statfile" || continue
    
    # Extract PID (field 1)
    pid=${line%% *}
    
    # Extract ticks using bash string manipulation
    # Remove up to LAST parenthesis to handle commands with spaces/parens safely
    # This is tricky in bash. simpler: remove everything before first closing paren?
    # No, commands can contain closing parens.
    # Safe way: greedy match from beginning to last closing paren.
    
    # Strip comm: "pid (comm) state ..." -> " state ..."
    rest="${line##*)}"
    
    # Fields in $rest (starting with space):
    #  1:state 2:ppid 3:pgrp 4:session 5:tty_nr 6:tpgid 7:flags 8:minflt 9:cminflt 10:majflt 11:cmajflt 12:utime 13:stime ...
    # We want 12(utime) + 13(stime)
    
    # Using read to split is fast
    read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime _ <<< "$rest"
    
    PREV_TICKS[$pid]=$((utime + stime))
    PREV_PIDS[$pid]=1
done

# --- Sleep ---
sleep "$SAMPLE_INTERVAL"

# --- Phase 2: Calculate Delta & Collect Data ---
rows=()
count=0
max_pids=500

# Get System Total Ticks (T2)
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < "$SYS_PROC/stat"
TOTAL_T2=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
DIFF_TOTAL=$((TOTAL_T2 - TOTAL_T1))
(( DIFF_TOTAL < 1 )) && DIFF_TOTAL=1

# Helper functions
mem_percent() {
    local rss_kb=$1
    if (( MEM_TOTAL_KB > 0 )); then
        local pct=$(( rss_kb * 10000 / MEM_TOTAL_KB ))
        printf "%d.%02d" $((pct/100)) $((pct%100))
    else
        echo "0.00"
    fi
}

# Iterate over PIDs again
for piddir in "$PROC_DIR"/[0-9]*; do
    [[ -d "$piddir" ]] || continue
    (( ++count > max_pids )) && break

    pid="${piddir##*/}"
    
    # Skip if new process (not in snapshot 1) - can't calculate delta
    [[ -z "${PREV_PIDS[$pid]:-}" ]] && continue

    # --- Basic file checks ---
    [[ -r "$piddir/stat" && -r "$piddir/status" && -r "$piddir/statm" && -r "$piddir/comm" ]] || continue

    # --- UID and username ---
    # Fast Grep for UID
    uid=$(grep -m1 '^Uid:' "$piddir/status" 2>/dev/null | cut -f2 | tr -d '[:space:]') || continue
    [[ -z "$uid" ]] && continue

    user="${UID_MAP[$uid]:-}"
    if [[ -z "$user" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        [[ -z "$user" ]] && user="$uid"
        UID_MAP[$uid]="$user"
    fi

    # --- Comm ---
    read -r comm < "$piddir/comm" 2>/dev/null || continue
    [[ -z "$comm" ]] && continue

    # --- RSS in KB ---
    read -r _ rss_pages _ < "$piddir/statm" 2>/dev/null || continue
    rss_kb=$((rss_pages * 4))

    # --- CPU Delta ---
    read -r line < "$piddir/stat" || continue
    rest="${line##*)}"
    read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime starttime _ <<< "$rest"
    
    curr_ticks=$((utime + stime))
    prev_tick=${PREV_TICKS[$pid]:-0}
    diff_proc=$((curr_ticks - prev_tick))
    
    # If pid repurposed or error, skip
    (( diff_proc < 0 )) && continue
    
    # Calculate CPU %: (diff_proc / diff_total) * 100 * (num_cores? No, spread over total)
    # Actually standard top % is per-core normalized usually, let's stick to simple share of total time * num_cpus? 
    # Or just share of total ticks?
    # /proc/stat total includes ALL cpus.
    # So (proc / total) * 100 * NUM_CORES is standard "top" behavior (e.g. can go > 100%)
    # OR (proc / total) * 100 is "share of system capacity".
    
    # Process Exporter usually expects 0-100% per core.
    # Wait, TOTAL_T2 - TOTAL_T1 is sum of ticks across ALL CPUs.
    # So if we have 4 cores, we have 400 ticks per second total? No, HZ * Cores.
    # So: (diff_proc / diff_total) * 100 * Num_Cores.
    # Let's count cores.
    NUM_CORES=$(grep -c ^processor "$SYS_PROC/cpuinfo" 2>/dev/null || echo 1)
    
    pct_int=$(( diff_proc * 10000 * NUM_CORES / DIFF_TOTAL ))
    cpu_pct=$(printf "%d.%02d" $((pct_int/100)) $((pct_int%100)))

    # Uptime
    # starttime is in jiffies after boot
    # Boot time is in seconds
    uptime_sec=$(( NOW - BOOT_TIME - starttime / CLK_TCK ))
    (( uptime_sec < 0 )) && uptime_sec=0

    mem_pct=$(mem_percent "$rss_kb")

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

    # Skip zero processes (Active filter)
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

    # Get ports for this PID
    ports="${pid_networks[$pid]:-}"
    # Clean up leading colon
    ports="${ports#:}"
    # Remove trailing comma
    ports="${ports%,}"

    rows+=("$pid\t$user\t$cpu_pct\t$mem_pct\t$rss_kb\t$uptime_sec\t$comm\t$rd\t$wr\t$ports\t${cgroup_path:-/}\t$runtime")
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