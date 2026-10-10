# Linux Server Monitoring and Automated Health Checks

Bash-based health checks for Linux servers with threshold-based warnings and
structured logging, plus a small Python tool to summarize the logs.

## What it checks

| Check | Source | Thresholds (config) |
|-------|--------|---------------------|
| Disk utilization (per filesystem) | `df -P` | `DISK_WARN`, `DISK_CRIT` |
| Memory and swap usage | `/proc/meminfo` | `MEM_*`, `SWAP_*` |
| CPU load (per core) | `/proc/loadavg`, `nproc` | `LOAD_*_PER_CPU` |
| Running processes, zombies, top CPU consumers | `ps`, `pgrep` | `ZOMBIE_WARN`, `PROC_WATCHLIST` |

Exit code: `0` OK, `1` warning, `2` critical (usable by cron, Nagios-style wrappers, CI).

## Usage

```bash
chmod +x health_check.sh
./health_check.sh                      # uses health_check.conf
HEALTH_CONF=/etc/hc.conf ./health_check.sh
python3 report.py --hours 24           # summarize recent runs
bash tests/run_tests.sh                # isolated regression tests
```

## Logs

- `logs/health.log`: every metric, one `key=value` line each (easy to grep/parse)
- `logs/alerts.log`: only `WARN` and `CRIT` lines, for quick troubleshooting
- Both logs rotate independently at `LOG_MAX_BYTES` (default 10 MiB). Numbered
  archives `.1` through `.LOG_KEEP` are retained (default 5); set `LOG_KEEP=0`
  to truncate at the size limit without retaining archives.

```
2026-10-10 20:30:01 host=web01 level=WARN check=disk mount=/var used_pct=83 warn=80 crit=90
```

## Automate with cron

```cron
*/5 * * * * /opt/linux-health-monitor/health_check.sh >/dev/null 2>&1
0 8 * * *   python3 /opt/linux-health-monitor/report.py --log /opt/linux-health-monitor/logs/health.log | mail -s "Daily health report" you@example.com
```

## Configuration

Edit `health_check.conf` to tune thresholds, set a process watchlist
(e.g. `PROC_WATCHLIST="sshd cron nginx"`), change `LOG_DIR`, or configure
`LOG_MAX_BYTES` and `LOG_KEEP`. Numeric values are validated when the script
starts. A missing or unreadable config uses built-in defaults and records a
configuration warning; malformed numeric settings exit with code 2. Mount
path spaces are recorded as `%20` so each log record remains whitespace-safe.

## Tests

Run `bash tests/run_tests.sh` from this directory. The tests use temporary
configuration and log directories via `HEALTH_CONF` and remove them on exit;
they do not edit the real config or project logs. They require Bash, Python 3,
and standard Linux utilities. Run ShellCheck separately with
`shellcheck health_check.sh tests/run_tests.sh`.
