#!/usr/bin/env bash

# Example:
# URL="https://example.com/file.bin" TOTAL_DOWNLOADS=10000 THREADS=20 WAIT_SECONDS=0 ./oss.sh

URL="${URL:-https://example.com}"
TEMP_DIR="${TEMP_DIR:-/tmp/downloads}"
TOTAL_DOWNLOADS="${TOTAL_DOWNLOADS:-10000}"
THREADS="${THREADS:-10}"
WAIT_SECONDS="${WAIT_SECONDS:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-0.2}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-1}"

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
    length="$(curl -fsSIL "$URL" 2>/dev/null | awk 'tolower($1) == "content-length:" { gsub("\r", "", $2); value = $2 } END { print value }')"
    if is_positive_int "$length"; then
      printf '%s' "$length"
    fi
  fi
}

download_file() {
  local output_file="$1"

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output_file" "$URL"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$output_file" "$URL"
  else
    log "未找到 wget 或 curl，无法下载。"
    return 127
  fi
}

download_one() {
  local index="$1"
  local temp_file="${TEMP_DIR}/file_${index}"
  local running_file="${STATS_DIR}/${index}.running"
  local waiting_file="${STATS_DIR}/${index}.waiting"
  local log_file="${STATS_DIR}/${index}.log"

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

cleanup() {
  local exit_code=$?
  local pids

  if [ "$exit_code" -ne 0 ]; then
    pids="$(jobs -pr)"
    if [ -n "$pids" ]; then
      kill $pids 2>/dev/null || true
    fi
  fi

  rm -rf "$STATS_DIR"
  exit "$exit_code"
}

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

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo "需要安装 wget 或 curl。" >&2
  exit 1
fi

mkdir -p "$TEMP_DIR"
STATS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oss-download-stats.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CONTENT_LENGTH="$(get_content_length)"
LAST_RENDER=0

log "开始下载：实际下载次数=${TOTAL_DOWNLOADS}，并发数=${THREADS}（只控制同时运行数量，不计入次数），等待时间=${WAIT_SECONDS}s，临时目录=${TEMP_DIR}"
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
  exit 1
fi
