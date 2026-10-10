#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_config() {
    local path="$1" log_dir="$2" disk_warn="$3" disk_crit="$4" watchlist="${5:-}"
    cat > "$path" <<EOF
DISK_WARN=$disk_warn
DISK_CRIT=$disk_crit
MEM_WARN=100
MEM_CRIT=101
SWAP_WARN=100
SWAP_CRIT=101
LOAD_WARN_PER_CPU=100
LOAD_CRIT_PER_CPU=101
ZOMBIE_WARN=999999
PROC_WATCHLIST="$watchlist"
TOP_N=1
LOG_DIR="$log_dir"
LOG_MAX_BYTES=1048576
LOG_KEEP=2
EOF
}

run_check() {
    local expected="$1"; shift
    set +e
    HEALTH_CONF="$CONFIG" "$@" bash "$ROOT/health_check.sh"
    local actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'FAIL: expected exit %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

CONFIG="$TMP_DIR/warn.conf"
write_config "$CONFIG" "$TMP_DIR/warn-logs" 0 101
run_check 1 env
grep -q 'level=WARN check=disk' "$TMP_DIR/warn-logs/health.log"
printf 'PASS warning threshold returns exit 1\n'

CONFIG="$TMP_DIR/critical.conf"
write_config "$CONFIG" "$TMP_DIR/critical-logs" 0 1
run_check 2 env
grep -q 'level=CRIT check=disk' "$TMP_DIR/critical-logs/health.log"
printf 'PASS critical threshold returns exit 2\n'

CONFIG="$TMP_DIR/process.conf"
write_config "$CONFIG" "$TMP_DIR/process-logs" 100 101 'codex_process_that_does_not_exist_123'
run_check 2 env
grep -q 'level=CRIT check=process_watch .*running=no' "$TMP_DIR/process-logs/health.log"
printf 'PASS missing watched process returns critical\n'

python3 - "$ROOT/report.py" "$TMP_DIR/critical-logs/health.log" <<'PY'
import subprocess
import sys

result = subprocess.run(
    [sys.executable, sys.argv[1], "--log", sys.argv[2], "--hours", "87600"],
    check=True, capture_output=True, text=True,
)
assert "(1 runs)" in result.stdout, result.stdout
assert "CRIT  disk" in result.stdout, result.stdout
print("PASS report counts runs and alerts")
PY

printf 'All tests passed.\n'
