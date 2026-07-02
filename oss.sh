#!/bin/bash

# 设定文件下载的URL和临时文件夹路径
URL="https://2wepogbvu71019.oss-ap-northeast-1.aliyuncs.com/ChatKnow-Setup-2.0.4-win-x64.exe"  # 请替换为实际的文件URL
TEMP_DIR="/tmp/downloads"

# 创建临时文件夹，如果不存在的话
mkdir -p "$TEMP_DIR"

# 循环10次下载文件
for i in {1..10000}
do
  # 临时文件的路径
  TEMP_FILE="$TEMP_DIR/file_$i"

  # 下载文件
  echo "开始下载第 $i 次文件..."
  wget -O "$TEMP_FILE" "$URL"

  # 检查是否下载成功
  if [ $? -eq 0 ]; then
    echo "第 $i 次下载完成，文件已存储在 $TEMP_FILE"
  else
    echo "第 $i 次下载失败，跳过此轮"
    continue
  fi

  # 删除下载的文件
  rm -f "$TEMP_FILE"
  echo "文件 $TEMP_FILE 已删除"

  # 等待10秒钟
  echo "等待10秒钟..."
  sleep 10
done

echo "所有下载完成。"