#!/usr/bin/env python3
"""apple-translate-api 的资源占用基准。

空载 → burst → 长文本 → 并发 → 多语言对 → 静置，逐段测 RSS 与 CPU 时间增量。

    python3 scripts/bench.py [--burst 200] [--base http://127.0.0.1:8787]

只读 /proc 等价物：用 ps 采 RSS 和累计 CPU 时间，不侵入服务进程。
"""

import argparse
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8787"


def find_pid() -> int:
    out = subprocess.run(
        ["pgrep", "-f", "Products/Release/apple-translate-server"],
        capture_output=True, text=True,
    ).stdout.split()
    if not out:
        sys.exit("找不到服务进程，先确认服务在跑")
    return int(out[0])


def sample(pid: int) -> tuple[float, float]:
    """返回 (RSS MB, 累计 CPU 秒)。"""
    out = subprocess.run(
        ["ps", "-o", "rss=,time=", "-p", str(pid)],
        capture_output=True, text=True,
    ).stdout.split()
    rss_mb = int(out[0]) / 1024
    cpu = out[1]  # mm:ss.ss 或 hh:mm:ss
    parts = [float(p) for p in cpu.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return rss_mb, seconds


def translate(text: str, **extra):
    payload = {"messages": [{"role": "user", "content": text}], **extra}
    request = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            body = json.loads(response.read().decode())
        return time.perf_counter() - start, body["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as error:
        return time.perf_counter() - start, f"<HTTP {error.code}>"


def has_cjk(text: str) -> bool:
    return any("\u4e00" <= ch <= "\u9fff" for ch in text)


def report(label: str, pid: int, mark: tuple[float, float], extra: str = "") -> tuple[float, float]:
    rss, cpu = sample(pid)
    d_rss = rss - mark[0]
    d_cpu = cpu - mark[1]
    print(f"  {label:<28} RSS {rss:6.1f} MB ({d_rss:+5.1f})   CPU {d_cpu:6.2f}s   {extra}")
    return rss, cpu


def main() -> None:
    global BASE
    parser = argparse.ArgumentParser()
    parser.add_argument("--burst", type=int, default=200, help="burst 阶段的请求数")
    parser.add_argument("--base", default=BASE)
    args = parser.parse_args()
    BASE = args.base

    pid = find_pid()
    print(f"▶ 目标进程 pid={pid}  服务 {BASE}")
    print(f"▶ 空载基线")
    mark = report("idle", pid, (0.0, 0.0))

    # ---- burst：连续短请求 -------------------------------------------------
    print(f"▶ burst：{args.burst} 条短请求，串行")
    before = mark
    latencies = []
    started = time.perf_counter()
    for i in range(args.burst):
        elapsed, out = translate(f"Benchmark request number {i}. The service is being measured.")
        latencies.append(elapsed)
        if not has_cjk(out):
            sys.exit(f"第 {i} 条没翻出中文：{out!r}")
    wall = time.perf_counter() - started
    latencies.sort()
    mark = report(
        "after burst", pid, before,
        f"{args.burst / wall:.1f} req/s  中位 {latencies[len(latencies)//2]*1000:.0f}ms  "
        f"p99 {latencies[int(len(latencies)*0.99)]*1000:.0f}ms",
    )

    # ---- 长文本 ------------------------------------------------------------
    print("▶ 长文本：5 × 5000 字符")
    before = mark
    paragraph = (
        "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. "
        "How vexingly quick daft zebras jump. The five boxing wizards jump quickly. "
    )
    long_text = (paragraph * 30)[:5000]
    for _ in range(5):
        elapsed, out = translate(long_text)
        if not has_cjk(out):
            sys.exit(f"长文本没翻出中文：{out[:80]!r}")
    mark = report("after long texts", pid, before)

    # ---- 并发 --------------------------------------------------------------
    print("▶ 并发：8 条同时发")
    before = mark
    results: list[tuple[int, str]] = [None] * 8  # type: ignore[list-item]

    def worker(index: int) -> None:
        elapsed, out = translate(f"Concurrent worker number {index} reporting in.")
        results[index] = (index, out)

    started = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - started
    bad = [out for _, out in results if not has_cjk(out)]
    report("after concurrency", pid, before, f"{wall*1000:.0f}ms  失败 {len(bad)}/{len(results)}")
    if bad:
        print(f"    ⚠️ 并发下有异常返回：{bad}")

    # ---- 多语言对 ----------------------------------------------------------
    print("▶ 多语言对（只跑本机真装了包的那些）")
    before = mark
    candidates = [
        ("Good morning.", "zh-Hans", "en"),
        ("Good morning.", "ja", "en"),
        ("こんにちは、元気ですか？", "zh-Hans", "ja"),
        ("今天天气不错。", "en", "zh-Hans"),
        ("おはようございます。", "en", "ja"),
    ]
    pairs = []
    for text, target, source in candidates:
        request = urllib.request.Request(f"{BASE}/v1/languages?source={source}&target={target}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status = json.loads(response.read().decode()).get("pair_status")
        except Exception:
            status = None
        if status == "installed":
            pairs.append((text, target, source))
        else:
            print(f"    跳过 {source}→{target}（{status or '查不到'}，包没装）")
    if not pairs:
        print("    没有任何已装的语言对可测")
    for text, target, source in pairs:
        elapsed, out = translate(text, target_language=target, source_language=source)
        print(f"    {source}→{target:<8} {elapsed*1000:6.0f}ms  {out!r}")
    mark = report("after pairs", pid, before)

    # ---- 静置回收 ----------------------------------------------------------
    print("▶ 静置 15 秒看内存是否回收")
    before = mark
    time.sleep(15)
    mark = report("idle after 15s", pid, before)

    # ---- 收尾 --------------------------------------------------------------
    print()
    print("▶ 线程 / 文件描述符")
    threads_n = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.count("\n") - 1
    fds = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout.count("\n") - 1
    print(f"  threads={threads_n}  fds={fds}")
    print()
    print(f"▶ 汇总：全程 RSS {mark[0]:.1f} MB，累计 CPU {mark[1]:.2f}s")


if __name__ == "__main__":
    main()
