#!/usr/bin/env bash
# macOS Memory Watcher — logs top memory hogs, swap usage, and captures samples on spikes.
# Detects memory leaks, tracks swap usage, and monitors SSD wear from swap.
# Ready to run: save as memory_watcher.sh, then: chmod +x memory_watcher.sh && ./memory_watcher.sh
# Stop with Ctrl+C.

set -u
INTERVAL_SEC="${INTERVAL_SEC:-30}"     # seconds between snapshots
TOP_N="${TOP_N:-10}"                   # how many top processes to log
RSS_ALERT_MB="${RSS_ALERT_MB:-1024}"   # sample a process if its RSS >= this (in MB)
SWAP_ALERT_MB="${SWAP_ALERT_MB:-512}"  # sample top proc if swap used >= this (in MB)
LEAK_GROWTH_MB="${LEAK_GROWTH_MB:-100}" # flag potential leak if process grows by this much
LEAK_CHECK_INTERVALS="${LEAK_CHECK_INTERVALS:-10}" # check for leaks every N intervals

LOG_DIR="${HOME}/MemoryWatch"
SAMPLES_DIR="${LOG_DIR}/samples"
CSV="${LOG_DIR}/memory_log.csv"
EVENTS="${LOG_DIR}/events.log"
LEAKS_LOG="${LOG_DIR}/memory_leaks.log"
SWAP_HISTORY="${LOG_DIR}/swap_history.csv"
PROCESS_HISTORY="${LOG_DIR}/process_history.txt"

mkdir -p "$LOG_DIR" "$SAMPLES_DIR"

# Track process memory over time for leak detection
declare -A PROCESS_MEMORY
ITERATION_COUNT=0

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
  if [ ! -s "$SWAP_HISTORY" ]; then
    echo "timestamp,swap_used_mb,swap_total_mb,pressure,free_pct" > "$SWAP_HISTORY"
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

  # Check if process exists first
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[$(timestamp)] process $pid no longer exists, skipping sample" >> "$EVENTS"
    return 1
  fi

  if command -v sample >/dev/null 2>&1; then
    echo "[$(timestamp)] sampling pid=$pid reason=$why -> $out" >> "$EVENTS"
    # 5 seconds of sampling, minimal overhead
    if ! /usr/bin/sample "$pid" 5 -file "$out" 2>&1 | tee -a "$EVENTS" | grep -q "error"; then
      # Also capture heap info if leaks tool is available
      if command -v leaks >/dev/null 2>&1; then
        /usr/bin/leaks "$pid" >> "${out%.txt}_leaks.txt" 2>&1 &
      fi
    else
      echo "[$(timestamp)] sample failed for pid=$pid (process may have terminated)" >> "$EVENTS"
    fi
  else
    echo "[$(timestamp)] 'sample' tool not found; skipping sample for pid=$pid" >> "$EVENTS"
  fi
}

log_swap_history() {
  local ts swap total free_pct press
  ts="$(timestamp)"
  swap="$(swap_used_mb)"
  press="$(mem_pressure_summary)"

  # Extract swap total and calculate free percentage
  local swap_info
  swap_info="$(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null)"
  total="$(echo "$swap_info" | sed -E 's/.*total = ([0-9.]+[KMG]).*/\1/' | xargs -I {} bash -c "$(declare -f to_mb); to_mb {}")"

  if [ "$total" -gt 0 ]; then
    free_pct="$(awk -v s="$swap" -v t="$total" 'BEGIN{printf "%d", 100-((s/t)*100)}')"
  else
    free_pct="100"
  fi

  echo "$ts,$swap,$total,$press,$free_pct" >> "$SWAP_HISTORY"
}

check_memory_leaks() {
  # Check for potential memory leaks by tracking process growth
  local ts
  ts="$(timestamp)"

  # Get all processes with RSS > 100MB
  ps -axo pid,comm,rss | awk 'NR>1 && $3>102400 {printf "%s:%s:%d\n",$1,$2,$3/1024}' | while IFS=: read -r pid comm rss_mb; do
    local key="${pid}_${comm}"
    local prev_rss="${PROCESS_MEMORY[$key]:-0}"

    if [ "$prev_rss" -gt 0 ]; then
      local growth=$((rss_mb - prev_rss))
      if [ "$growth" -ge "$LEAK_GROWTH_MB" ]; then
        echo "[$ts] POTENTIAL LEAK: $comm (PID $pid) grew ${growth}MB: ${prev_rss}MB -> ${rss_mb}MB" >> "$LEAKS_LOG"
        echo "[$ts] POTENTIAL LEAK detected: $comm (PID $pid) grew ${growth}MB" >> "$EVENTS"

        # Trigger detailed sampling for leak suspects
        sample_process "$pid" "leak_suspect_growth_${growth}MB"
      fi
    fi

    # Update tracking
    PROCESS_MEMORY[$key]=$rss_mb
  done
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

  # Log swap history every interval
  log_swap_history

  # Check for memory leaks periodically
  ITERATION_COUNT=$((ITERATION_COUNT + 1))
  if [ $((ITERATION_COUNT % LEAK_CHECK_INTERVALS)) -eq 0 ]; then
    check_memory_leaks
  fi
}

echo "==== $(timestamp) :: Memory Watcher started (interval=${INTERVAL_SEC}s, top_n=${TOP_N}, rss_alert=${RSS_ALERT_MB}MB, swap_alert=${SWAP_ALERT_MB}MB) ====" >> "$EVENTS"

# Main loop
while :; do
  log_top
  maybe_sample
  sleep "$INTERVAL_SEC"
done
