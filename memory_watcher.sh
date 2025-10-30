#!/usr/bin/env bash
# macOS Memory Watcher — logs top memory hogs, swap usage, and captures samples on spikes.
# Ready to run: save as memory_watcher.sh, then: chmod +x memory_watcher.sh && ./memory_watcher.sh
# Stop with Ctrl+C.

set -u
INTERVAL_SEC="${INTERVAL_SEC:-30}"     # seconds between snapshots
TOP_N="${TOP_N:-5}"                    # how many top processes to log
RSS_ALERT_MB="${RSS_ALERT_MB:-1024}"   # sample a process if its RSS >= this (in MB)
SWAP_ALERT_MB="${SWAP_ALERT_MB:-512}"  # sample top proc if swap used >= this (in MB)

LOG_DIR="${HOME}/MemoryWatch"
SAMPLES_DIR="${LOG_DIR}/samples"
CSV="${LOG_DIR}/memory_log.csv"
EVENTS="${LOG_DIR}/events.log"

mkdir -p "$LOG_DIR" "$SAMPLES_DIR"

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Convert a string like "2048.00M" or "2.00G" to MB (integer).
to_mb() {
  local val unit
  val="$(printf "%s" "$1" | sed -E 's/([0-9]+(\.[0-9]+)?)\s*([KMG])/ \1 \3 /;t; s/$/ 0 X /' | awk '{print $1}')" || val=0
  unit="$(printf "%s" "$1" | sed -E 's/([0-9]+(\.[0-9]+)?)\s*([KMG])/ \1 \3 /;t; s/$/ 0 X /' | awk '{print $2}')" || unit="X"
  case "$unit" in
    K) awk -v v="$val" 'BEGIN{printf "%d", v/1024}' ;;
    M) awk -v v="$val" 'BEGIN{printf "%d", v}' ;;
    G) awk -v v="$val" 'BEGIN{printf "%d", v*1024}' ;;
    *) echo 0 ;;
  esac
}

swap_used_mb() {
  # vm.swapusage: total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)
  local used token
  token="$(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*used = ([0-9.]+[KMG]).*/\1/')" || token="0M"
  to_mb "$token"
}

mem_pressure_summary() {
  # Quick summary without ANSI; falls back gracefully if command missing
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure -Q 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g'
  else
    echo "memory_pressure:not_available"
  fi
}

init_csv() {
  if [ ! -s "$CSV" ]; then
    echo "timestamp,swap_used_mb,pressure,rank,pid,ppid,user,rss_mb,vsz_mb,mem_pct,command" > "$CSV"
  fi
}
init_csv

log_top() {
  local ts swap press
  ts="$(timestamp)"
  swap="$(swap_used_mb)"
  press="$(mem_pressure_summary)"

  # ps rss/vsz are in KB; convert to MB via awk
  # shellcheck disable=SC2009
  ps -axo pid,ppid,user,comm,rss,vsz,%mem \
    | awk 'NR>1 {printf "%s,%s,%s,%s,%0.0f,%0.0f,%s,%s\n",$1,$2,$3,$4,$5/1024,$6/1024,$7,$4}' \
    | sort -t, -k5,5nr \
    | head -n "$TOP_N" \
    | nl -w1 -s',' \
    | while IFS=',' read -r rank line; do
        echo "$ts,$swap,$press,$rank,$line" >> "$CSV"
      done

  # Event line (first/top process for quick read)
  local top_line
  top_line="$(tail -n "$TOP_N" "$CSV" | tail -n 1)"
  echo "[$ts] swap_used_mb=$swap pressure=[$press] top: ${top_line}" >> "$EVENTS"
}

sample_process() {
  local pid="$1" why="$2"
  local out="${SAMPLES_DIR}/sample_${pid}_$(date +%Y%m%d_%H%M%S)_${why}.txt"
  if command -v sample >/dev/null 2>&1; then
    echo "[$(timestamp)] sampling pid=$pid reason=$why -> $out" >> "$EVENTS"
    # 5 seconds of sampling, minimal overhead
    /usr/bin/sample "$pid" 5 -file "$out" >/dev/null 2>&1 || echo "[$(timestamp)] sample failed for pid=$pid" >> "$EVENTS"
  else
    echo "[$(timestamp)] 'sample' tool not found; skipping sample for pid=$pid" >> "$EVENTS"
  fi
}

maybe_sample() {
  # Look at current top process; sample if thresholds exceeded
  local swap pid rss_mb
  swap="$(swap_used_mb)"

  # Get current top by RSS (fresh ps)
  local line
  line="$(ps -axo pid,rss,comm | awk 'NR>1{printf "%s,%0.0f,%s\n",$1,$2/1024,$3}' | sort -t, -k2,2nr | head -n 1)"
  pid="$(printf "%s" "$line" | cut -d, -f1)"
  rss_mb="$(printf "%s" "$line" | cut -d, -f2)"

  # Sample if either condition is tripped
  if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
    if [ "$rss_mb" -ge "$RSS_ALERT_MB" ]; then
      sample_process "$pid" "rss_${rss_mb}MB_ge_${RSS_ALERT_MB}MB"
    elif [ "$swap" -ge "$SWAP_ALERT_MB" ]; then
      sample_process "$pid" "swap_${swap}MB_ge_${SWAP_ALERT_MB}MB"
    fi
  fi
}

echo "==== $(timestamp) :: Memory Watcher started (interval=${INTERVAL_SEC}s, top_n=${TOP_N}, rss_alert=${RSS_ALERT_MB}MB, swap_alert=${SWAP_ALERT_MB}MB) ====" >> "$EVENTS"

# Main loop
while :; do
  log_top
  maybe_sample
  sleep "$INTERVAL_SEC"
done
