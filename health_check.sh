#!/usr/bin/env bash
# health_check.sh - Linux server health check: disk, memory, load, processes.
# Logs metrics and threshold breaches; exit code reflects worst status.
#   0 = OK, 1 = WARNING, 2 = CRITICAL
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HEALTH_CONF:-$SCRIPT_DIR/health_check.conf}"

# ---- Defaults (override in health_check.conf) ----
DISK_WARN=80;  DISK_CRIT=90        # % used per filesystem
MEM_WARN=80;   MEM_CRIT=90         # % used (based on MemAvailable)
SWAP_WARN=50;  SWAP_CRIT=80        # % swap used
LOAD_WARN_PER_CPU=0.8              # 1-min load average / CPU count
LOAD_CRIT_PER_CPU=1.5
ZOMBIE_WARN=5
PROC_WATCHLIST=""                  # space-separated process names that must be running
TOP_N=5
LOG_DIR="$SCRIPT_DIR/logs"
LOG_MAX_BYTES=10485760
LOG_KEEP=5

# shellcheck disable=SC1090
if [[ -r "$CONFIG_FILE" ]]; then
    if ! source "$CONFIG_FILE"; then
        CONFIG_ERROR="malformed"
    fi
else
    CONFIG_ERROR="missing_or_unreadable"
fi

# Validate numeric configuration before it reaches arithmetic or awk.
valid_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
for setting in DISK_WARN DISK_CRIT MEM_WARN MEM_CRIT SWAP_WARN SWAP_CRIT \
    LOAD_WARN_PER_CPU LOAD_CRIT_PER_CPU ZOMBIE_WARN TOP_N LOG_MAX_BYTES LOG_KEEP; do
    if ! valid_number "${!setting}"; then
        printf 'Invalid numeric setting %s in %s\n' "$setting" "$CONFIG_FILE" >&2
        exit 2
    fi
done
for setting in ZOMBIE_WARN TOP_N LOG_MAX_BYTES LOG_KEEP; do
    if ! [[ "${!setting}" =~ ^[0-9]+$ ]]; then
        printf 'Setting %s must be an integer in %s\n' "$setting" "$CONFIG_FILE" >&2
        exit 2
    fi
done
if (( LOG_MAX_BYTES < 1 || LOG_KEEP < 0 )); then
    printf 'LOG_MAX_BYTES must be positive and LOG_KEEP non-negative\n' >&2
    exit 2
fi

if ! mkdir -p "$LOG_DIR"; then
    printf 'Cannot create log directory: %s\n' "$LOG_DIR" >&2
    exit 2
fi
LOG_FILE="$LOG_DIR/health.log"
ALERT_FILE="$LOG_DIR/alerts.log"

rotate_log() {
    local file="$1" size i
    [[ -f "$file" ]] || return 0
    size=$(wc -c < "$file") || return 1
    (( size < LOG_MAX_BYTES )) && return 0
    if (( LOG_KEEP == 0 )); then
        : > "$file"
        return
    fi
    rm -f -- "$file.$LOG_KEEP"
    for ((i=LOG_KEEP-1; i>=1; i--)); do
        [[ -f "$file.$i" ]] && mv -- "$file.$i" "$file.$((i+1))"
    done
    mv -- "$file" "$file.1"
}
rotate_log "$LOG_FILE" || exit 2
rotate_log "$ALERT_FILE" || exit 2
HOST="$(hostname)"
STATUS=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {  # log LEVEL CHECK message
    local level="$1" check="$2"; shift 2
    local line
    line="$(ts) host=$HOST level=$level check=$check $*"
    rotate_log "$LOG_FILE" || return 1
    echo "$line" >> "$LOG_FILE"
    if [[ "$level" == "WARN" || "$level" == "CRIT" ]]; then
        rotate_log "$ALERT_FILE" || return 1
        echo "$line" >> "$ALERT_FILE"
    fi
    [[ -t 1 ]] && echo "$line"
    return 0
}

raise() {  # raise <1|2>
    (( $1 > STATUS )) && STATUS=$1
    return 0
}

# Compare a numeric value against warn/crit; prints INFO, WARN or CRIT.
level_for() {  # level_for value warn crit
    awk -v v="$1" -v w="$2" -v c="$3" \
        'BEGIN { if (v >= c) print "CRIT"; else if (v >= w) print "WARN"; else print "INFO" }'
}

apply_level() {  # apply_level LEVEL
    case "$1" in
        WARN) raise 1 ;;
        CRIT) raise 2 ;;
    esac
}

check_disk() {
    local pct mount level
    if ! command -v df >/dev/null 2>&1; then
        log CRIT disk "error=missing_df"; raise 2; return
    fi
    while read -r pct mount; do
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        level="$(level_for "$pct" "$DISK_WARN" "$DISK_CRIT")"
        log "$level" disk "mount=$mount used_pct=$pct warn=$DISK_WARN crit=$DISK_CRIT"
        apply_level "$level"
    done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {m=$6; for(i=7;i<=NF;i++) m=m "%20" $i; gsub("%", "", $5); print $5, m}')
}

check_memory() {
    if [[ ! -r /proc/meminfo ]]; then
        log CRIT memory "error=cannot_read_/proc/meminfo"; raise 2; return
    fi
    local total avail swap_total swap_free mem_pct swap_pct level
    total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)

    if ! [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || (( total == 0 || avail > total )); then
        log CRIT memory "error=invalid_/proc/meminfo"; raise 2; return
    fi
    mem_pct=$(awk -v t="$total" -v a="$avail" 'BEGIN { printf "%.1f", (t-a)*100/t }')
    level="$(level_for "$mem_pct" "$MEM_WARN" "$MEM_CRIT")"
    log "$level" memory "used_pct=$mem_pct total_kb=$total available_kb=$avail warn=$MEM_WARN crit=$MEM_CRIT"
    apply_level "$level"

    if [[ "$swap_total" =~ ^[0-9]+$ && "$swap_free" =~ ^[0-9]+$ ]] && (( swap_total > 0 && swap_free <= swap_total )); then
        swap_pct=$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN { printf "%.1f", (t-f)*100/t }')
        level="$(level_for "$swap_pct" "$SWAP_WARN" "$SWAP_CRIT")"
        log "$level" swap "used_pct=$swap_pct warn=$SWAP_WARN crit=$SWAP_CRIT"
        apply_level "$level"
    fi
}

check_load() {
    local load1 cpus per level
    if [[ ! -r /proc/loadavg ]]; then
        log CRIT load "error=cannot_read_/proc/loadavg"; raise 2; return
    fi
    load1=$(awk '{print $1}' /proc/loadavg)
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus > 0 )) || cpus=1
    if ! valid_number "$load1"; then
        log CRIT load "error=invalid_/proc/loadavg"; raise 2; return
    fi
    per=$(awk -v l="$load1" -v c="$cpus" 'BEGIN { printf "%.2f", l/c }')
    level="$(level_for "$per" "$LOAD_WARN_PER_CPU" "$LOAD_CRIT_PER_CPU")"
    log "$level" load "load1=$load1 cpus=$cpus per_cpu=$per"
    apply_level "$level"
}

check_processes() {
    local total zombies level p
    if ! command -v ps >/dev/null 2>&1; then
        log CRIT processes "error=missing_ps"; raise 2; return
    fi
    total=$(ps -e -o pid= | wc -l)
    zombies=$(ps -eo stat --no-headers | grep -c '^Z' || true)
    level="INFO"
    (( zombies >= ZOMBIE_WARN )) && level="WARN"
    log "$level" processes "total=$total zombies=$zombies zombie_warn=$ZOMBIE_WARN"
    apply_level "$level"

    # Top consumers (informational, aids troubleshooting)
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu --no-headers | head -n "$TOP_N" |
        while read -r pid comm cpu mem; do
            log INFO top_process "pid=$pid name=$comm cpu_pct=$cpu mem_pct=$mem"
        done

    # Required processes
    local -a watched_processes=()
    read -r -a watched_processes <<< "$PROC_WATCHLIST"
    for p in "${watched_processes[@]}"; do
        if pgrep -x "$p" >/dev/null 2>&1; then
            log INFO process_watch "name=$p running=yes"
        else
            log CRIT process_watch "name=$p running=no error=process_not_found"
            raise 2
        fi
    done
}

main() {
    if [[ -n "${CONFIG_ERROR:-}" ]]; then
        log WARN config "error=$CONFIG_ERROR path=$CONFIG_FILE"
        raise 1
    fi
    log INFO run "start config=$CONFIG_FILE"
    check_disk
    check_memory
    check_load
    check_processes
    local summary=OK
    (( STATUS == 1 )) && summary=WARNING
    (( STATUS == 2 )) && summary=CRITICAL
    log INFO run "end overall=$summary exit_code=$STATUS"
    exit "$STATUS"
}

main "$@"
