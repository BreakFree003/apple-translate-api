#!/usr/bin/env python3
"""apple-translate-api 端到端验收。

断言来源：OpenAI Chat Completions 规范（字段形状）+ 语言的可观测性质（目标语言该出现的字符）。
不从本服务的实现里反推期望值 —— 期望是「翻成日语就该有假名」「翻成中文就该有汉字且没有假名」。

跑法见 scripts/e2e.sh（它负责起服务、传 AT_E2E_BASE、收尾）。
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("AT_E2E_BASE", "http://127.0.0.1:8791")
# 另一个实例，显式开了源语言检测（AT_SOURCE_MODE=auto）。默认值现在是 english（源语言固定
# 成 AT_DEFAULT_SOURCE、不做检测），所以「检测器能不能认出来」这类断言要打到这个 base 上。
DETECT_BASE = os.environ.get("AT_E2E_DETECT_BASE", BASE)

passed: list[str] = []
failed: list[tuple[str, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        passed.append(name)
        print(f"  ✅ {name}")
    else:
        failed.append((name, detail))
        print(f"  ❌ {name} — {detail}")


def post(path: str, payload: dict, timeout: int = 180, base=None):
    request = urllib.request.Request(
        (base or BASE) + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read().decode())


def get(path: str, timeout: int = 60, base=None):
    with urllib.request.urlopen((base or BASE) + path, timeout=timeout) as response:
        return response.status, json.loads(response.read().decode())


def chat(content: str, base=None, **extra) -> tuple[int, dict]:
    return post("/v1/chat/completions", {"messages": [{"role": "user", "content": content}], **extra}, base=base)


def content_of(body: dict) -> str:
    return body["choices"][0]["message"]["content"]


def has_cjk(text: str) -> bool:
    return any("\u4e00" <= ch <= "\u9fff" for ch in text)


def has_kana(text: str) -> bool:
    return any("\u3040" <= ch <= "\u30ff" for ch in text)


def has_latin_letter(text: str) -> bool:
    return any(ch.isascii() and ch.isalpha() for ch in text)


def pair_installed(source: str, target: str) -> bool:
    """语言包装没装由系统说了算 —— 断言得跟着它走，不能假设这台机器上有 ja。"""
    _, body = get(f"/v1/languages?source={source}&target={target}")
    return body.get("pair_status") == "installed"


def check_pack_dependent(name: str, status: int, body: dict, ready: bool, target: str, kana: bool = True) -> None:
    """装了包要求翻对；没装包要求「明确报出被解析成的目标语言」—— 两条路都不许静默翻错。"""
    if ready:
        content = content_of(body) if status == 200 else ""
        ok = status == 200 and (has_kana(content) if kana else has_cjk(content))
        check(name, ok, f"{status} {content!r}")
    else:
        error = body.get("error", {})
        check(
            f"{name}（{target} 包没装 → 必须明确 400 而不是静默翻错）",
            status == 400
            and error.get("code") == "language_not_installed"
            and target in error.get("message", ""),
            f"{status} {body}",
        )


def stream_events(payload: dict) -> tuple[str, str, str]:
    """返回 (拼起来的 delta 内容, 原始 SSE 文本)。"""
    request = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    collected = ""
    raw = ""
    with urllib.request.urlopen(request, timeout=180) as response:
        content_type = response.headers.get("Content-Type", "")
        for line in response:
            text = line.decode().strip()
            if not text:
                continue
            raw += text + "\n"
            if text.startswith("data: ") and text != "data: [DONE]":
                chunk = json.loads(text[len("data: "):])
                for choice in chunk.get("choices", []):
                    collected += choice.get("delta", {}).get("content") or ""
    return content_type, collected, raw


# ---------------------------------------------------------------------------
print("▶ 元信息")
status, health = get("/health")
check("/health 返回 200 且 status=ok", status == 200 and health.get("status") == "ok", f"{status} {health}")

status, models = get("/v1/models")
check(
    "/v1/models 是 OpenAI 的 list 形状",
    status == 200 and models.get("object") == "list" and models["data"][0]["object"] == "model",
    f"{status} {models}",
)

status, languages = get("/v1/languages?source=en&target=zh-Hans")
check(
    "/v1/languages 报告 en→zh-Hans 已安装",
    status == 200 and languages.get("pair_status") == "installed",
    f"{status} pair_status={languages.get('pair_status')}",
)
check(
    "/v1/languages 的 system_supported 用规范 id（和控制台 catalog 同一套写法）",
    all(entry in [item["id"] for item in languages["catalog"]] for entry in languages["system_supported"]),
    f"{languages.get('system_supported')}",
)

# ---------------------------------------------------------------------------
print("▶ 翻译方向")
english = "The quick brown fox jumps over the lazy dog."

status, body = chat(english)
translated = content_of(body) if status == 200 else ""
check(
    "裸英文文本默认翻成中文",
    status == 200 and has_cjk(translated) and not has_kana(translated) and translated.strip() != english,
    f"{status} {translated!r}",
)
check(
    "响应符合 chat.completion 规范",
    body.get("object") == "chat.completion"
    and body["choices"][0]["message"]["role"] == "assistant"
    and body["choices"][0]["finish_reason"] == "stop"
    and {"prompt_tokens", "completion_tokens", "total_tokens"} <= set(body.get("usage", {})),
    json.dumps(body, ensure_ascii=False)[:200],
)

ja_ready = pair_installed("en", "ja")

status, body = chat("Good morning, have a nice day.", target_language="ja")
check_pack_dependent("显式 target_language=ja 翻成日语", status, body, ja_ready, "ja")

status, health = get("/health")
check("默认把源语言固定成英文（不检测）", health.get("source_mode") == "english", str(health.get("source_mode")))

# 下面两条测的是「检测」能力本身，所以打到那个显式开了 AT_SOURCE_MODE=auto 的实例上。
status, body = chat("今天天气不错，我们去散步吧。", target_language="en", base=DETECT_BASE)
back = content_of(body) if status == 200 else ""
check(
    "中译英：自动判出源语言是中文（AT_SOURCE_MODE=auto）",
    status == 200 and has_latin_letter(back) and not has_cjk(back),
    f"{status} {back!r}",
)

# 这条断言验的是 smartSkip 本身，所以用 /v1/translate（只有它回 `skipped` 字段），
# 并且打到 AT_SOURCE_MODE=auto 的实例上 —— 那里检测器会认出源语言就是目标语言。
# 打在默认实例上的话，正文原样返回只是因为「框架把中文当英文翻成中文」，与 smartSkip 无关。
status, body = post(
    "/v1/translate",
    {"text": "今天天气不错，我们去散步吧。", "target": "zh-Hans"},
    base=DETECT_BASE,
)
check(
    "中文正文 + target=zh-Hans 时 smartSkip 生效：skipped=true 且原样返回（AT_SOURCE_MODE=auto）",
    status == 200 and body.get("skipped") is True and body.get("translation") == "今天天气不错，我们去散步吧。",
    f"{status} {body}",
)

# 回归：NLLanguageRecognizer 曾把这句话判成 tr 0.58 / en 0.32，而土耳其语包没装 → 400。
status, body = chat("The cat sat on the mat.")
short_sentence = content_of(body) if status == 200 else ""
check(
    "短句不会被误判成土耳其语（回归）",
    status == 200 and has_cjk(short_sentence),
    f"{status} {short_sentence!r} {body.get('error')}",
)

# ---------------------------------------------------------------------------
print("▶ prompt 里有指令时的切分")
bob_prompt = "Translate the following text into Japanese:\nGood morning, have a nice day."
status, body = post(
    "/v1/chat/completions",
    {
        "messages": [
            {"role": "system", "content": "You are a professional translator."},
            {"role": "user", "content": bob_prompt},
        ]
    },
)
instruction_parsed = content_of(body) if status == 200 else ""
check_pack_dependent("从指令里认出目标语言是日语", status, body, ja_ready, "ja")

leak_prompt = "Translate the following text into Chinese, and output only the translation:\nThe cat sat on the mat."
status, body = chat(leak_prompt)
leaked = content_of(body) if status == 200 else ""
check(
    "指令没被当成正文一起翻（译文里不该出现指令的词）",
    status == 200 and has_cjk(leaked) and "输出" not in leaked and "翻译" not in leaked,
    f"{status} {leaked!r}",
)

status, body = chat("把下面这段英文翻译成中文：\nThe meeting has been postponed until next Monday.")
chinese_instruction = content_of(body) if status == 200 else ""
check(
    "中文指令同样能切干净、认出目标语言",
    status == 200 and has_cjk(chinese_instruction) and "翻译" not in chinese_instruction,
    f"{status} {chinese_instruction!r}",
)

# ---------------------------------------------------------------------------
print("▶ 流式")
content_type, collected, raw = stream_events(
    {
        "messages": [
            {
                "role": "user",
                "content": "Streaming matters because clients render text as it arrives, one piece at a time.",
            }
        ],
        "stream": True,
    }
)
check("SSE 的 Content-Type 正确", "text/event-stream" in content_type, content_type)
check("流式输出拼起来是中文译文", has_cjk(collected), f"{collected!r}")
check("流以 data: [DONE] 收尾", raw.rstrip().endswith("data: [DONE]"), raw[-120:])
check(
    "每个 chunk 都是合法的 chat.completion.chunk",
    all(
        json.loads(line[len("data: "):]).get("object") == "chat.completion.chunk"
        for line in raw.splitlines()
        if line.startswith("data: ") and line != "data: [DONE]"
    ),
    raw[:200],
)

# ---------------------------------------------------------------------------
print("▶ 错误路径")
status, body = chat("hello", target_language="klingon")
check(
    "不认识的目标语言返回 400 + unsupported_target_language",
    status == 400 and body.get("error", {}).get("code") == "unsupported_target_language",
    f"{status} {body}",
)

status, body = post("/v1/chat/completions", {"messages": []})
check("没有正文时返回 400 + empty_input", status == 400 and body.get("error", {}).get("code") == "empty_input", f"{status} {body}")

status, body = post("/v1/chat/completions", {"messages": [{"role": "user", "content": "x" * 20001}]})
check("超长正文返回 413 + input_too_long", status == 413 and body.get("error", {}).get("code") == "input_too_long", f"{status} {body}")

try:
    urllib.request.urlopen(BASE + "/v1/nope", timeout=30)
    unknown_status = 200
except urllib.error.HTTPError as error:
    unknown_status = error.code
check("未知路由返回 404", unknown_status == 404, str(unknown_status))

status, body = post("/v1/translate", {"text": "Bonjour tout le monde", "target": "zh-Hans"}, base=DETECT_BASE)
check(
    "/v1/translate 能用（AT_SOURCE_MODE=auto，装了法语包的话）",
    (status == 200 and has_cjk(body.get("translation", "")))
    or (status == 400 and body.get("error", {}).get("code") == "language_not_installed"),
    f"{status} {body}",
)

# ---------------------------------------------------------------------------
print("▶ openai SDK 兼容性")
try:
    from openai import OpenAI

    client = OpenAI(base_url=BASE + "/v1", api_key="not-needed")
    completion = client.chat.completions.create(
        model="apple-translate",
        messages=[{"role": "user", "content": "Where is the nearest subway station?"}],
    )
    sdk_text = completion.choices[0].message.content
    check("openai SDK 非流式调用", has_cjk(sdk_text), repr(sdk_text))

    stream = client.chat.completions.create(
        model="apple-translate",
        messages=[{"role": "user", "content": "Please open the window, it is warm in here."}],
        stream=True,
    )
    sdk_stream_text = "".join(chunk.choices[0].delta.content or "" for chunk in stream if chunk.choices)
    check("openai SDK 流式调用", has_cjk(sdk_stream_text), repr(sdk_stream_text))
except ImportError:
    print("  ⚠️  没装 openai SDK，跳过（pip install openai 后可补测）")

# ---------------------------------------------------------------------------
print()
total = len(passed) + len(failed)
if failed:
    print(f"❌ {len(failed)}/{total} 项失败：")
    for name, detail in failed:
        print(f"   - {name}: {detail}")
    sys.exit(1)
print(f"✅ {total}/{total} 项全部通过")
