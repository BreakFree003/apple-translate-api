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
BIN="$(swift build --show-bin-path)/apple-translate-server"

echo "▶ 构建"
swift build

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
