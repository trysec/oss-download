#!/usr/bin/env bash

# Example:
# URL="https://example.com/file.bin" TOTAL_DOWNLOADS=10000 THREADS=20 WAIT_SECONDS=0 ./oss.sh

URL="${URL:-https://example.com}"
TEMP_DIR="${TEMP_DIR:-/tmp/downloads}"
TOTAL_DOWNLOADS="${TOTAL_DOWNLOADS:-10000}"
THREADS="${THREADS:-10}"
WAIT_SECONDS="${WAIT_SECONDS:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-0.2}"

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

  log "开始下载第 $index 次文件..."
  if download_file "$temp_file"; then
    log "第 $index 次下载完成，文件已存储在 $temp_file"
    rm -f "$temp_file"
    log "文件 $temp_file 已删除"
    touch "${STATS_DIR}/${index}.ok"
  else
    log "第 $index 次下载失败，跳过此轮"
    rm -f "$temp_file"
    touch "${STATS_DIR}/${index}.fail"
    return 1
  fi

  if [ "$WAIT_SECONDS" -gt 0 ]; then
    log "第 $index 次任务等待 ${WAIT_SECONDS} 秒..."
    sleep "$WAIT_SECONDS"
  fi
}

running_jobs() {
  jobs -rp | wc -l | tr -d ' '
}

wait_for_slot() {
  while [ "$(running_jobs)" -ge "$THREADS" ]; do
    sleep "$POLL_INTERVAL"
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

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo "需要安装 wget 或 curl。" >&2
  exit 1
fi

mkdir -p "$TEMP_DIR"
STATS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oss-download-stats.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "开始下载：总次数=${TOTAL_DOWNLOADS}，并发数=${THREADS}，等待时间=${WAIT_SECONDS}s，临时目录=${TEMP_DIR}"

i=1
while [ "$i" -le "$TOTAL_DOWNLOADS" ]; do
  wait_for_slot
  download_one "$i" &
  i=$((i + 1))
done

wait

success_count="$(find "$STATS_DIR" -name '*.ok' -type f | wc -l | tr -d ' ')"
fail_count="$(find "$STATS_DIR" -name '*.fail' -type f | wc -l | tr -d ' ')"

log "所有下载完成。成功：${success_count}，失败：${fail_count}。"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
