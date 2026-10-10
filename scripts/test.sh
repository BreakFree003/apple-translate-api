#!/usr/bin/env bash
# swift test 的可重复封装。
#
# 为什么需要它：在只装了 CommandLineTools（没有完整 Xcode）的机器上，swift test 的增量
# 构建有时候会在显式 module 的插件列表里漏掉 TestingMacros，于是编译测试模块时报
#
#   error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
#          could not be found for macro 'Test'; plugin for module 'TestingMacros' not found
#
# 实测（macOS 27.0.1 / CLT 的 Swift 6.4）：裸跑是 PASS/FAIL 交替，连跑 4 次挂 2 次；
# 显式把插件的所在目录喂给编译器之后 4/4 通过。这个脚本就是替你加那个参数，
# 顺手兼容装了完整 Xcode 的机器。跟本项目的代码无关。
set -euo pipefail

cd "$(dirname "$0")/.."

# 工具链根目录（CLT 或 Xcode 都由 xcode-select 指出来）。
TOOLCHAIN="$(xcode-select -p 2>/dev/null || true)"

PLUGIN_DIR=""
for candidate in \
    "$TOOLCHAIN/usr/lib/swift/host/plugins/testing" \
    "$TOOLCHAIN/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        PLUGIN_DIR="$candidate"
        break
    fi
done

if [ -n "$PLUGIN_DIR" ]; then
    # ${PLUGIN_DIR} 的花括号是必须的：后面紧跟全角括号，不加的话 bash 会把标点字节
    # 当成变量名的一部分，报 "PLUGIN_DIR�: unbound variable"。（本项目在 e2e.sh 里
    # 也为同一个坑留过注释。）
    echo "▶ swift test（显式指定宏插件目录：${PLUGIN_DIR}）"
    exec swift test "$@" -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR"
fi

echo "▶ swift test"
exec swift test "$@"
