#!/usr/bin/env bash

# Example:
# URL="https://example.com/file.bin" TOTAL_DOWNLOADS=10000 THREADS=20 WAIT_SECONDS=0 ./oss.sh

URL="${URL:-}"
TEMP_DIR="${TEMP_DIR:-/tmp/downloads}"
TOTAL_DOWNLOADS="${TOTAL_DOWNLOADS:-10000}"
THREADS="${THREADS:-10}"
WAIT_SECONDS="${WAIT_SECONDS:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-0.2}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-300}"
RETRIES="${RETRIES:-3}"
FAIL_LOG_LIMIT="${FAIL_LOG_LIMIT:-5}"
FAIL_LOG_LINES="${FAIL_LOG_LINES:-20}"

usage() {
  cat <<'EOF'
用法:
  URL="https://example.com/file.bin" ./oss.sh

常用配置:
  TOTAL_DOWNLOADS=10000   实际下载总次数，默认 10000
  THREADS=10              同时运行的并发任务数，默认 10
  WAIT_SECONDS=10         每个任务下载完成后的等待秒数，默认 10
  TEMP_DIR=/tmp/downloads 临时下载目录

可靠性配置:
  CONNECT_TIMEOUT=10      单次连接超时秒数
  MAX_TIME=300            curl 单次下载最大耗时；wget 读取超时秒数
  RETRIES=3               失败后的重试次数
  POLL_INTERVAL=0.2       调度轮询间隔秒数
  PROGRESS_INTERVAL=1     进度刷新间隔秒数
  LOG_DIR=/path/to/logs   保留每次下载的命令输出日志
  FAIL_LOG_LIMIT=5        失败时最多打印几个任务日志，0 表示不打印
  FAIL_LOG_LINES=20       每个失败任务最多打印多少行日志
EOF
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_positive_number() {
  awk -v value="$1" 'BEGIN {
    exit (value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 ? 0 : 1)
  }'
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

count_files() {
  find "$STATS_DIR" -name "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

file_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" 2>/dev/null | tr -d ' '
  else
    printf '0'
  fi
}

format_bytes() {
  awk -v bytes="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    i = 1
    while (bytes >= 1024 && i < 5) {
      bytes = bytes / 1024
      i++
    }
    if (i == 1) {
      printf "%d%s", bytes, unit[i]
    } else {
      printf "%.1f%s", bytes, unit[i]
    }
  }'
}

get_content_length() {
  local length

  case "$URL" in
    file://*)
      local source_file="${URL#file://}"
      if [ -f "$source_file" ]; then
        file_size "$source_file"
      fi
      return
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    length="$(curl -fsSIL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$URL" 2>/dev/null | awk 'tolower($1) == "content-length:" { gsub("\r", "", $2); value = $2 } END { print value }')"
    if is_positive_int "$length"; then
      printf '%s' "$length"
    fi
  fi
}

download_file() {
  local output_file="$1"

  case "$DOWNLOAD_TOOL" in
    curl)
      curl -fsSL \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --retry "$RETRIES" \
        --retry-delay 1 \
        -o "$output_file" \
        "$URL"
      ;;
    wget)
      wget -q \
        --dns-timeout="$CONNECT_TIMEOUT" \
        --connect-timeout="$CONNECT_TIMEOUT" \
        --read-timeout="$MAX_TIME" \
        --tries="$DOWNLOAD_TRIES" \
        -O "$output_file" \
        "$URL"
      ;;
    *)
      log "未找到 wget 或 curl，无法下载。"
      return 127
      ;;
  esac
}

download_one() {
  local index="$1"
  local temp_file="${TEMP_DIR}/file_${index}"
  local running_file="${STATS_DIR}/${index}.running"
  local waiting_file="${STATS_DIR}/${index}.waiting"
  local log_file="${RUN_LOG_DIR}/${index}.log"

  printf '%s\n' "$(date '+%s')" > "$running_file"
  if download_file "$temp_file" > "$log_file" 2>&1; then
    rm -f "$temp_file"
    rm -f "$running_file"

    if [ "$WAIT_SECONDS" -gt 0 ]; then
      printf '%s\n' "$(date '+%s')" > "$waiting_file"
      sleep "$WAIT_SECONDS"
      rm -f "$waiting_file"
    fi

    touch "${STATS_DIR}/${index}.ok"
  else
    rm -f "$temp_file"
    rm -f "$running_file" "$waiting_file"
    touch "${STATS_DIR}/${index}.fail"
    return 1
  fi
}

running_jobs() {
  jobs -rp | wc -l | tr -d ' '
}

task_progress() {
  local index="$1"
  local temp_file="${TEMP_DIR}/file_${index}"
  local bytes percent

  bytes="$(file_size "$temp_file")"
  if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
    percent=$((bytes * 100 / CONTENT_LENGTH))
    if [ "$percent" -gt 100 ]; then
      percent=100
    fi
    printf '%3s%% (%s/%s)' "$percent" "$(format_bytes "$bytes")" "$(format_bytes "$CONTENT_LENGTH")"
  else
    printf '%s/未知大小' "$(format_bytes "$bytes")"
  fi
}

render_progress() {
  local now success_count fail_count done_count running_count waiting_count active_count queued_count overall_percent
  local job_count missing_count
  local running_file waiting_file index started elapsed remaining

  now="$(date '+%s')"
  success_count="$(count_files '*.ok')"
  fail_count="$(count_files '*.fail')"
  running_count="$(count_files '*.running')"
  waiting_count="$(count_files '*.waiting')"
  done_count=$((success_count + fail_count))
  active_count=$((running_count + waiting_count))
  job_count="$(running_jobs)"
  if [ "$active_count" -lt "$job_count" ]; then
    missing_count=$((job_count - active_count))
    running_count=$((running_count + missing_count))
    active_count="$job_count"
  fi
  queued_count=$((TOTAL_DOWNLOADS - done_count - active_count))
  if [ "$queued_count" -lt 0 ]; then
    queued_count=0
  fi
  overall_percent=$((done_count * 100 / TOTAL_DOWNLOADS))

  if [ -t 1 ]; then
    printf '\033[2J\033[H'
  fi

  printf '总进度: %s/%s (%s%%) | 成功: %s | 失败: %s | 下载中: %s | 等待中: %s | 排队: %s | 并发: %s\n' \
    "$done_count" "$TOTAL_DOWNLOADS" "$overall_percent" "$success_count" "$fail_count" "$running_count" "$waiting_count" "$queued_count" "$THREADS"
  printf '说明: TOTAL_DOWNLOADS 是实际下载总次数，THREADS 只控制同时运行数量，不计入次数。\n'

  for running_file in "$STATS_DIR"/*.running; do
    [ -e "$running_file" ] || continue
    index="$(basename "$running_file" .running)"
    started="$(sed -n '1p' "$running_file" 2>/dev/null)"
    if ! is_non_negative_int "$started"; then
      started="$now"
    fi
    elapsed=$((now - started))
    printf '任务 #%s: 下载中 | %s | 已用 %ss\n' "$index" "$(task_progress "$index")" "$elapsed"
  done

  for waiting_file in "$STATS_DIR"/*.waiting; do
    [ -e "$waiting_file" ] || continue
    index="$(basename "$waiting_file" .waiting)"
    started="$(sed -n '1p' "$waiting_file" 2>/dev/null)"
    if ! is_non_negative_int "$started"; then
      started="$now"
    fi
    elapsed=$((now - started))
    remaining=$((WAIT_SECONDS - elapsed))
    if [ "$remaining" -lt 0 ]; then
      remaining=0
    fi
    printf '任务 #%s: 下载完成，等待中 | 剩余 %ss\n' "$index" "$remaining"
  done
}

print_failure_logs() {
  local index log_file shown indexes

  if [ "$FAIL_LOG_LIMIT" -eq 0 ]; then
    return
  fi

  indexes="$(find "$STATS_DIR" -name '*.fail' -type f 2>/dev/null | sed 's#.*/##; s#\.fail$##' | sort -n)"
  if [ -z "$indexes" ]; then
    return
  fi

  log "失败任务日志（最多 ${FAIL_LOG_LIMIT} 个任务，每个 ${FAIL_LOG_LINES} 行）："
  shown=0
  for index in $indexes; do
    log_file="${RUN_LOG_DIR}/${index}.log"
    printf -- '--- task #%s: %s ---\n' "$index" "$log_file"
    if [ -s "$log_file" ]; then
      tail -n "$FAIL_LOG_LINES" "$log_file"
    else
      printf '无可用日志。\n'
    fi

    shown=$((shown + 1))
    if [ "$shown" -ge "$FAIL_LOG_LIMIT" ]; then
      break
    fi
  done
}

cleanup() {
  local exit_code=$?
  local pids

  if [ "$exit_code" -ne 0 ]; then
    pids="$(jobs -pr)"
    if [ -n "$pids" ]; then
      for pid in $pids; do
        kill "$pid" 2>/dev/null || true
      done
    fi
  fi

  if [ -n "${STATS_DIR:-}" ] && [ -d "$STATS_DIR" ]; then
    rm -rf "$STATS_DIR"
  fi
  exit "$exit_code"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    echo "不支持位置参数：$1" >&2
    usage >&2
    exit 1
    ;;
esac

if [ -z "$URL" ]; then
  echo "必须通过 URL 环境变量指定下载地址。" >&2
  usage >&2
  exit 1
fi

if ! is_positive_int "$TOTAL_DOWNLOADS"; then
  echo "TOTAL_DOWNLOADS 必须是正整数。" >&2
  exit 1
fi

if ! is_positive_int "$THREADS"; then
  echo "THREADS 必须是正整数。" >&2
  exit 1
fi

if ! is_non_negative_int "$WAIT_SECONDS"; then
  echo "WAIT_SECONDS 必须是非负整数。" >&2
  exit 1
fi

if ! is_positive_int "$PROGRESS_INTERVAL"; then
  echo "PROGRESS_INTERVAL 必须是正整数。" >&2
  exit 1
fi

if ! is_positive_number "$POLL_INTERVAL"; then
  echo "POLL_INTERVAL 必须是正数，可使用小数，例如 0.2。" >&2
  exit 1
fi

if ! is_positive_int "$CONNECT_TIMEOUT"; then
  echo "CONNECT_TIMEOUT 必须是正整数。" >&2
  exit 1
fi

if ! is_positive_int "$MAX_TIME"; then
  echo "MAX_TIME 必须是正整数。" >&2
  exit 1
fi

if ! is_non_negative_int "$RETRIES"; then
  echo "RETRIES 必须是非负整数。" >&2
  exit 1
fi

if ! is_non_negative_int "$FAIL_LOG_LIMIT"; then
  echo "FAIL_LOG_LIMIT 必须是非负整数。" >&2
  exit 1
fi

if ! is_positive_int "$FAIL_LOG_LINES"; then
  echo "FAIL_LOG_LINES 必须是正整数。" >&2
  exit 1
fi

DOWNLOAD_TRIES=$((RETRIES + 1))

if command -v curl >/dev/null 2>&1; then
  DOWNLOAD_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOAD_TOOL="wget"
else
  echo "需要安装 wget 或 curl。" >&2
  exit 1
fi

if ! mkdir -p "$TEMP_DIR"; then
  echo "无法创建临时下载目录：$TEMP_DIR" >&2
  exit 1
fi

if ! STATS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oss-download-stats.XXXXXX")"; then
  echo "无法创建运行状态目录。" >&2
  exit 1
fi

RUN_LOG_DIR="${LOG_DIR:-${STATS_DIR}/logs}"
if ! mkdir -p "$RUN_LOG_DIR"; then
  echo "无法创建日志目录：$RUN_LOG_DIR" >&2
  rm -rf "$STATS_DIR"
  exit 1
fi

if ! : > "${RUN_LOG_DIR}/.write-test" 2>/dev/null; then
  echo "日志目录不可写：$RUN_LOG_DIR" >&2
  rm -rf "$STATS_DIR"
  exit 1
fi
rm -f "${RUN_LOG_DIR}/.write-test"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CONTENT_LENGTH="$(get_content_length)"
LAST_RENDER=0

log "开始下载：实际下载次数=${TOTAL_DOWNLOADS}，并发数=${THREADS}（只控制同时运行数量，不计入次数），等待时间=${WAIT_SECONDS}s，临时目录=${TEMP_DIR}"
log "下载器=${DOWNLOAD_TOOL}，连接超时=${CONNECT_TIMEOUT}s，下载/读取超时=${MAX_TIME}s，失败重试=${RETRIES} 次"
if [ -n "$CONTENT_LENGTH" ]; then
  log "单个文件大小：$(format_bytes "$CONTENT_LENGTH")"
else
  log "未获取到单个文件大小，将显示已下载字节数。"
fi

i=1
while [ "$i" -le "$TOTAL_DOWNLOADS" ] || [ "$(running_jobs)" -gt 0 ]; do
  while [ "$i" -le "$TOTAL_DOWNLOADS" ] && [ "$(running_jobs)" -lt "$THREADS" ]; do
    printf '%s\n' "$(date '+%s')" > "${STATS_DIR}/${i}.running"
    download_one "$i" &
    i=$((i + 1))
  done

  now="$(date '+%s')"
  if [ $((now - LAST_RENDER)) -ge "$PROGRESS_INTERVAL" ]; then
    render_progress
    LAST_RENDER="$now"
  fi

  sleep "$POLL_INTERVAL"
done

wait || true
render_progress

success_count="$(find "$STATS_DIR" -name '*.ok' -type f | wc -l | tr -d ' ')"
fail_count="$(find "$STATS_DIR" -name '*.fail' -type f | wc -l | tr -d ' ')"

log "所有下载完成。成功：${success_count}，失败：${fail_count}。"

if [ "$fail_count" -gt 0 ]; then
  print_failure_logs
  if [ -n "${LOG_DIR:-}" ]; then
    log "完整日志已保留在：${RUN_LOG_DIR}"
  fi
  exit 1
fi
