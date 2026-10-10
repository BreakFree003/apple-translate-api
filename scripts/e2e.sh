#!/usr/bin/env bash
# apple-translate-api 端到端验收。
#
#   ./scripts/e2e.sh
#
# 起一个真服务（独立端口）、发真请求、翻真文本，跑完自动收尾。
# 任何一项断言失败就以非 0 退出，并打印服务日志。
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${E2E_PORT:-8791}"
CONFIG="${E2E_CONFIG:-debug}"

# 默认测源码构建产物。要验 brew（或别处）装的那个二进制，就覆盖 AT_BIN：
#   AT_BIN=/opt/homebrew/bin/apple-translate-server ./scripts/e2e.sh
if [ -n "${AT_BIN:-}" ]; then
    BIN="$AT_BIN"
    echo "▶ 用 AT_BIN 指定的二进制：$BIN"
else
    # 变量一律用 ${} 包起来：后面紧跟全角标点时，bash 会把标点的字节吃进变量名。
    echo "▶ 构建（${CONFIG}）"
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/apple-translate-server"
fi

if [ ! -x "$BIN" ]; then
    echo "找不到可执行文件：$BIN" >&2
    exit 1
fi

LOG="$(mktemp -t apple-translate-e2e)"
DETECT_PORT="$((PORT + 1))"
DETECT_LOG="$(mktemp -t apple-translate-e2e-detect)"

echo "▶ 在端口 ${PORT} 起服务（默认配置；日志：${LOG}）"
AT_PORT="$PORT" AT_LOG=1 "$BIN" >"$LOG" 2>&1 &
PID=$!

# 再起一个显式打开源语言检测的实例。默认值现在是 english（固定英文、不检测），
# 而「检测器能不能把中文/法语认出来」这件事仍然值得测 —— 那几条断言打到这个实例上。
echo "▶ 在端口 ${DETECT_PORT} 起服务（AT_SOURCE_MODE=auto；日志：${DETECT_LOG}）"
AT_PORT="$DETECT_PORT" AT_SOURCE_MODE=auto AT_LOG=1 "$BIN" >"$DETECT_LOG" 2>&1 &
DETECT_PID=$!

cleanup() {
    kill "$PID" "$DETECT_PID" 2>/dev/null || true
    wait "$PID" "$DETECT_PID" 2>/dev/null || true
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 60); do
    if curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 &&
       curl -fsS -m 2 "http://127.0.0.1:$DETECT_PORT/health" >/dev/null 2>&1; then
        READY=1
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null || ! kill -0 "$DETECT_PID" 2>/dev/null; then
        echo "服务没起来，日志："
        cat "$LOG" "$DETECT_LOG"
        exit 1
    fi
    sleep 0.5
done
if [ "$READY" -ne 1 ]; then
    echo "等了 30 秒 /health 还不通，日志："
    cat "$LOG" "$DETECT_LOG"
    exit 1
fi

set +e
AT_E2E_BASE="http://127.0.0.1:$PORT" \
AT_E2E_DETECT_BASE="http://127.0.0.1:$DETECT_PORT" \
    python3 scripts/e2e.py
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
    echo
    echo "▶ 服务日志（默认配置）"
    cat "$LOG"
    echo
    echo "▶ 服务日志（AT_SOURCE_MODE=auto）"
    cat "$DETECT_LOG"
fi
exit "$STATUS"
