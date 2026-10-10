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
echo "▶ 在端口 ${PORT} 起服务（日志：${LOG}）"
AT_PORT="$PORT" AT_LOG=1 "$BIN" >"$LOG" 2>&1 &
PID=$!

cleanup() {
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 60); do
    if curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        READY=1
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "服务没起来，日志："
        cat "$LOG"
        exit 1
    fi
    sleep 0.5
done
if [ "$READY" -ne 1 ]; then
    echo "等了 30 秒 /health 还不通，日志："
    cat "$LOG"
    exit 1
fi

set +e
AT_E2E_BASE="http://127.0.0.1:$PORT" python3 scripts/e2e.py
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
    echo
    echo "▶ 服务日志"
    cat "$LOG"
fi
exit "$STATUS"
