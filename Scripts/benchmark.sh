#!/usr/bin/env bash
# 目录加载性能基准：1k / 10k / 50k 项目录
#
#   bash Scripts/benchmark.sh                 # release 构建，自动准备测试目录
#   bash Scripts/benchmark.sh debug           # 用 debug 构建（数字偏慢，只看趋势）
#   bash Scripts/benchmark.sh release ~/Pictures   # 额外跑一个真实目录
#
# 说明：这里只测「目录枚举 + 属性预取」的耗时（M3 验收的首屏指标），
# 滚动帧率需要人工在应用内观察（10k 项目录持续滚动）。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
EXTRA_DIR="${2:-}"
SIZES=(1000 10000 50000)
ROOT="${TMPDIR:-/tmp}pane-bench"

echo "▶ 构建（${CONFIG}）…"
swift build -c "$CONFIG" >/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PaneApp"

if [ ! -x "$BIN" ]; then
    echo "✗ 找不到可执行文件：$BIN"
    exit 1
fi

echo "▶ 准备测试目录：$ROOT"
for n in "${SIZES[@]}"; do
    dir="$ROOT/$n"
    count=0
    if [ -d "$dir" ]; then
        count=$(find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
    fi
    if [ "$count" != "$n" ]; then
        echo "  · 生成 ${n} 个文件 …"
        rm -rf "$dir"
        mkdir -p "$dir"
        (
            # 必须在目标目录内生成，避免污染工程根目录
            cd "$dir"
            seq 1 "$n" | awk '{ printf "file_%06d.txt\n", $1 }' | xargs -n 400 touch
            # 混合 20 个子目录（贴近真实结构）
            for i in $(seq 1 20); do
                mkdir -p "subdir_$i"
            done
        )
    fi
done

echo
echo "▶ 基准结果（$(swift --version 2>/dev/null | grep -m1 'Apple Swift' )）"
date "+  时间：%Y-%m-%d %H:%M:%S"
echo

for n in "${SIZES[@]}"; do
    "$BIN" --bench "$ROOT/$n" --repeat 3
done

if [ -n "$EXTRA_DIR" ] && [ -d "$EXTRA_DIR" ]; then
    echo
    "$BIN" --bench "$EXTRA_DIR" --repeat 3
fi

echo
echo "验收参考：1 万项首屏 < 200ms；滚动满帧需在应用内人工确认。"
echo "清理测试数据：rm -rf \"${ROOT}\""
