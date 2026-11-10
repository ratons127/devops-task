#!/usr/bin/env bash
#
# system_health.sh - lightweight host health check for production Linux servers.
#
# Collects CPU, memory, per-filesystem disk usage, load average and the top 5
# processes by memory; appends a timestamped entry to a log file (text or JSON),
# warns when thresholds are exceeded, and exits with a monitoring-friendly code.
#
# Exit codes:  0 = healthy   1 = warning   2 = critical   3 = unknown/script error
#
set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR

# ----------------------------------------------------------------- defaults
WARN_CPU=90
WARN_MEM=85
WARN_DISK=80
CRIT_CPU=98
CRIT_MEM=95
CRIT_DISK=90
LOG_FILE="${HEALTH_LOG_FILE:-${SCRIPT_DIR}/health_log.txt}"
MAX_LOG_BYTES=$((1024 * 1024)) # rotate at 1 MiB
KEEP_LOGS=5                    # keep health_log.txt.1 .. .5
OUTPUT_JSON=false
QUIET=false
CPU_SAMPLE_SECONDS=1
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}" # optional Slack/Discord webhook

readonly EXIT_OK=0 EXIT_WARN=1 EXIT_CRIT=2 EXIT_UNKNOWN=3

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Collect host health metrics, append them to a log file and report threshold breaches.

Thresholds (percent, integers 1-100):
  --cpu N            CPU usage warning threshold          (default: ${WARN_CPU})
  --mem N            Memory usage warning threshold       (default: ${WARN_MEM})
  --disk N           Disk usage warning threshold, any FS (default: ${WARN_DISK})
  --cpu-crit N       CPU usage critical threshold         (default: ${CRIT_CPU})
  --mem-crit N       Memory usage critical threshold      (default: ${CRIT_MEM})
  --disk-crit N      Disk usage critical threshold        (default: ${CRIT_DISK})

Output:
  --json             Emit the report (stdout and log entry) as a single JSON line
  --log-file PATH    Log file to append to (default: ${LOG_FILE}; env HEALTH_LOG_FILE)
  --max-size BYTES   Rotate the log when it exceeds this size (default: ${MAX_LOG_BYTES})
  --keep N           Number of rotated logs to keep (default: ${KEEP_LOGS})
  -q, --quiet        Do not print the report to stdout (warnings still go to stderr)
  -h, --help         Show this help

Environment:
  HEALTH_WEBHOOK_URL Slack or Discord incoming-webhook URL; if set, a message is
                     posted whenever the status is WARNING or CRITICAL.

Exit codes: 0 healthy, 1 warning, 2 critical, 3 unknown (script/usage error).

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --disk 80 --cpu 90 --mem 85 --json
  ${SCRIPT_NAME} --log-file /var/log/system_health/health_log.txt --quiet
EOF
}

die() {
  echo "[ERROR] $*" >&2
  exit "$EXIT_UNKNOWN"
}

# Any unexpected failure under `set -e` reports UNKNOWN rather than a misleading 1.
trap 'echo "[ERROR] ${SCRIPT_NAME}: unexpected failure at line ${LINENO}" >&2; exit ${EXIT_UNKNOWN}' ERR

require_percent() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > 100)); then
    die "${name} must be an integer between 1 and 100 (got '${value}')"
  fi
}

require_int() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < 1)); then
    die "${name} must be a positive integer (got '${value}')"
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cpu | --mem | --disk | --cpu-crit | --mem-crit | --disk-crit | --log-file | --max-size | --keep)
        (($# >= 2)) || die "$1 requires a value"
        ;;
    esac
    case "$1" in
      --cpu) WARN_CPU="$2"; shift 2 ;;
      --mem) WARN_MEM="$2"; shift 2 ;;
      --disk) WARN_DISK="$2"; shift 2 ;;
      --cpu-crit) CRIT_CPU="$2"; shift 2 ;;
      --mem-crit) CRIT_MEM="$2"; shift 2 ;;
      --disk-crit) CRIT_DISK="$2"; shift 2 ;;
      --log-file) LOG_FILE="$2"; shift 2 ;;
      --max-size) MAX_LOG_BYTES="$2"; shift 2 ;;
      --keep) KEEP_LOGS="$2"; shift 2 ;;
      --json) OUTPUT_JSON=true; shift ;;
      -q | --quiet) QUIET=true; shift ;;
      -h | --help) usage; exit "$EXIT_OK" ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  require_percent "--cpu" "$WARN_CPU"
  require_percent "--mem" "$WARN_MEM"
  require_percent "--disk" "$WARN_DISK"
  require_percent "--cpu-crit" "$CRIT_CPU"
  require_percent "--mem-crit" "$CRIT_MEM"
  require_percent "--disk-crit" "$CRIT_DISK"
  require_int "--max-size" "$MAX_LOG_BYTES"
  require_int "--keep" "$KEEP_LOGS"
  ((WARN_CPU <= CRIT_CPU && WARN_MEM <= CRIT_MEM && WARN_DISK <= CRIT_DISK)) \
    || die "warning thresholds must not exceed critical thresholds"
}

check_dependencies() {
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] || die "this script requires Linux /proc"
  local cmd
  for cmd in df ps awk; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

# ----------------------------------------------------------------- collectors
# CPU usage % over a short sample window, from /proc/stat deltas.
collect_cpu() {
  local _ user nice system idle iowait irq softirq steal
  local idle1 total1 idle2 total2
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  idle1=$((idle + iowait))
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  sleep "$CPU_SAMPLE_SECONDS"
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  idle2=$((idle + iowait))
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))

  local dt=$((total2 - total1)) di=$((idle2 - idle1))
  if ((dt <= 0)); then
    CPU_PCT=0
  else
    CPU_PCT=$(((100 * (dt - di) + dt / 2) / dt))
  fi
}

# Memory usage % based on MemAvailable (what the kernel can actually hand out).
collect_mem() {
  local total avail
  total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  [[ -n "$total" && -n "$avail" && "$total" -gt 0 ]] || die "cannot read memory info"
  MEM_TOTAL_MB=$((total / 1024))
  MEM_USED_MB=$(((total - avail) / 1024))
  MEM_PCT=$(((100 * (total - avail) + total / 2) / total))
}

# One "mountpoint|fstype|size_kb|used_kb|pct" line per real filesystem.
collect_disks() {
  DISKS=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && DISKS+=("$line")
  done < <(
    df -P -k -T 2>/dev/null \
      | awk 'NR > 1 && $2 !~ /^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup2?|nsfs|ramfs|autofs|efivarfs)$/ {
               pct = $6; sub(/%/, "", pct)
               printf "%s|%s|%s|%s|%s\n", $7, $2, $3, $4, pct
             }' \
      | sort -u -t'|' -k1,1
  )
  ((${#DISKS[@]} > 0)) || die "no filesystems found by df"
}

collect_load() {
  read -r LOAD1 LOAD5 LOAD15 _ </proc/loadavg
  CPU_CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
}

# "pid|user|mem_pct|rss_kb|command" for the 5 largest processes by memory.
collect_top_procs() {
  TOP_PROCS=()
  local line
  while IFS= read -r line; do
    TOP_PROCS+=("$line")
  done < <(ps -eo pid=,user=,pmem=,rss=,comm= --sort=-rss 2>/dev/null \
    | head -n 5 \
    | awk '{ cmd = $5; for (i = 6; i <= NF; i++) cmd = cmd " " $i
             printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, cmd }')
}

# ----------------------------------------------------------------- evaluation
STATUS=$EXIT_OK
MESSAGES=()

raise() {
  local level="$1" msg="$2"
  MESSAGES+=("[${level}] ${msg}")
  if [[ "$level" == "CRITICAL" ]]; then
    STATUS=$EXIT_CRIT
  elif ((STATUS < EXIT_WARN)); then
    STATUS=$EXIT_WARN
  fi
}

check_threshold() {
  local what="$1" value="$2" warn="$3" crit="$4"
  if ((value >= crit)); then
    raise CRITICAL "${what} usage ${value}% >= critical threshold ${crit}%"
  elif ((value >= warn)); then
    raise WARNING "${what} usage ${value}% >= warning threshold ${warn}%"
  fi
}

evaluate() {
  check_threshold "CPU" "$CPU_PCT" "$WARN_CPU" "$CRIT_CPU"
  check_threshold "Memory" "$MEM_PCT" "$WARN_MEM" "$CRIT_MEM"
  local d mount pct
  for d in "${DISKS[@]}"; do
    IFS='|' read -r mount _ _ _ pct <<<"$d"
    check_threshold "Disk ${mount}" "$pct" "$WARN_DISK" "$CRIT_DISK"
  done
}

status_name() {
  case "$1" in
    "$EXIT_OK") echo "OK" ;;
    "$EXIT_WARN") echo "WARNING" ;;
    "$EXIT_CRIT") echo "CRITICAL" ;;
    *) echo "UNKNOWN" ;;
  esac
}

# ----------------------------------------------------------------- rendering
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

render_json() {
  local ts="$1" first d p m
  printf '{"timestamp":"%s","host":"%s","status":"%s",' "$ts" "$(json_escape "$HOSTNAME")" "$(status_name "$STATUS")"
  printf '"cpu":{"usage_pct":%d,"cores":%d},' "$CPU_PCT" "$CPU_CORES"
  printf '"memory":{"usage_pct":%d,"used_mb":%d,"total_mb":%d},' "$MEM_PCT" "$MEM_USED_MB" "$MEM_TOTAL_MB"
  printf '"load_avg":{"1m":%s,"5m":%s,"15m":%s},' "$LOAD1" "$LOAD5" "$LOAD15"

  printf '"disks":['
  first=true
  for d in "${DISKS[@]}"; do
    local mount fstype size used pct
    IFS='|' read -r mount fstype size used pct <<<"$d"
    $first || printf ','
    first=false
    printf '{"mount":"%s","fstype":"%s","size_kb":%s,"used_kb":%s,"usage_pct":%s}' \
      "$(json_escape "$mount")" "$(json_escape "$fstype")" "$size" "$used" "$pct"
  done
  printf '],'

  printf '"top_processes_by_mem":['
  first=true
  for p in "${TOP_PROCS[@]}"; do
    local pid user pmem rss cmd
    IFS='|' read -r pid user pmem rss cmd <<<"$p"
    $first || printf ','
    first=false
    printf '{"pid":%s,"user":"%s","mem_pct":%s,"rss_kb":%s,"command":"%s"}' \
      "$pid" "$(json_escape "$user")" "$pmem" "$rss" "$(json_escape "$cmd")"
  done
  printf '],'

  printf '"messages":['
  first=true
  for m in "${MESSAGES[@]}"; do
    $first || printf ','
    first=false
    printf '"%s"' "$(json_escape "$m")"
  done
  printf ']}\n'
}

render_text() {
  local ts="$1" d p
  echo "===== ${ts} ${HOSTNAME} status=$(status_name "$STATUS") ====="
  printf 'CPU:     %d%% (%d cores)\n' "$CPU_PCT" "$CPU_CORES"
  printf 'Memory:  %d%% (%d / %d MB)\n' "$MEM_PCT" "$MEM_USED_MB" "$MEM_TOTAL_MB"
  printf 'Load:    %s %s %s (1m 5m 15m)\n' "$LOAD1" "$LOAD5" "$LOAD15"
  echo "Disks:"
  for d in "${DISKS[@]}"; do
    local mount fstype size used pct
    IFS='|' read -r mount fstype size used pct <<<"$d"
    printf '  %-30s %-8s %3s%%  (%s / %s MB)\n' "$mount" "$fstype" "$pct" "$((used / 1024))" "$((size / 1024))"
  done
  echo "Top 5 processes by memory:"
  printf '  %-8s %-12s %6s %10s  %s\n' PID USER MEM% RSS_KB COMMAND
  for p in "${TOP_PROCS[@]}"; do
    local pid user pmem rss cmd
    IFS='|' read -r pid user pmem rss cmd <<<"$p"
    printf '  %-8s %-12s %6s %10s  %s\n' "$pid" "$user" "$pmem" "$rss" "$cmd"
  done
  local m
  for m in "${MESSAGES[@]}"; do
    echo "$m"
  done
}

# ----------------------------------------------------------------- log handling
rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(wc -c <"$LOG_FILE")
  ((size >= MAX_LOG_BYTES)) || return 0

  local i
  rm -f "${LOG_FILE}.${KEEP_LOGS}"
  for ((i = KEEP_LOGS - 1; i >= 1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

write_log() {
  local report="$1"
  rotate_log
  printf '%s\n' "$report" >>"$LOG_FILE" || die "cannot write to ${LOG_FILE}"
}

notify_webhook() {
  [[ -n "$WEBHOOK_URL" && "$STATUS" -ne "$EXIT_OK" ]] || return 0
  command -v curl >/dev/null 2>&1 || { echo "[WARNING] curl not found; webhook skipped" >&2; return 0; }

  local text payload
  text="$(status_name "$STATUS") on ${HOSTNAME}: $(printf '%s; ' "${MESSAGES[@]}")"
  # "text" is read by Slack, "content" by Discord; each ignores the other.
  payload=$(printf '{"text":"%s","content":"%s"}' "$(json_escape "$text")" "$(json_escape "$text")")
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null \
    || echo "[WARNING] webhook notification failed" >&2
}

# ----------------------------------------------------------------- main
main() {
  parse_args "$@"
  check_dependencies

  local log_dir
  log_dir="$(dirname "$LOG_FILE")"
  mkdir -p "$log_dir" 2>/dev/null || die "cannot create log directory ${log_dir}"

  # Prevent overlapping runs (e.g. a slow run plus the next timer tick).
  if command -v flock >/dev/null 2>&1; then
    # Braces scope the 2>/dev/null to this line; a bare `exec ... 2>/dev/null`
    # would silence stderr for the rest of the script.
    { exec 9>>"${LOG_FILE}.lock"; } 2>/dev/null || die "cannot open lock file ${LOG_FILE}.lock"
    flock -n 9 || die "another instance is already running"
  fi

  collect_cpu
  collect_mem
  collect_disks
  collect_load
  collect_top_procs
  evaluate

  local ts report
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if $OUTPUT_JSON; then
    report="$(render_json "$ts")"
  else
    report="$(render_text "$ts")"
  fi

  write_log "$report"
  $QUIET || printf '%s\n' "$report"

  # Threshold breaches always reach stderr so cron mail / journald capture them.
  local m
  for m in "${MESSAGES[@]}"; do
    echo "$m" >&2
  done

  notify_webhook
  exit "$STATUS"
}

main "$@"
