# apple-translate-api

把 **macOS 自带的端上翻译**（Apple 的 `Translation` 框架）包成一个 **OpenAI 兼容**的本地 HTTP 服务 —— 全离线、不要 API key、不要任何权限、不要联网。

```bash
curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello, world."}]}' | jq -r '.choices[0].message.content'
# -> 你好，世界。
```

任何认 OpenAI 接口的客户端（Bob、Chatbox、各种 SDK、你自己的脚本）把 `base_url` 指过来就能当翻译用。

---

## 它为什么能这么干

macOS 26 起，`Translation` 框架多了一个**不依赖 SwiftUI** 的入口：

```swift
let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                 target: Locale.Language(identifier: "zh-Hans"))
let response = try await session.translate("Hello, world.")
```

`@available(macOS 26.0, *)`。这一条就是整个工程的立身之本 —— 没有它，命令行进程只能去啃 SwiftUI 的 `.translationTask`（MoePeek 那种菜单栏 App 的做法：造一个 1×1 的隐形 NSWindow + NSHostingView 去托管一个 View，见 [cosZone/MoePeek](https://github.com/cosZone/MoePeek)）。

实测这个类**没有 `@MainActor`**，detached Task / 后台队列 / 两个 session 并发都正常，纯命令行二进制直接跑，不需要 `.app` bundle。

## 要求

| 项 | 要求 |
|---|---|
| 系统 | **macOS 26.0+**（macOS 15–25 用不了，见上） |
| 工具链 | Swift 6（**CommandLineTools 就够**，不需要 Xcode） |
| 语言包 | 在 **系统设置 → 通用 → 语言与地区 → 翻译语言** 里装好要用的语言对 |
| 权限 | 无。Entitlements 是空的 |

## 构建与运行

```bash
swift build -c release
AT_PORT=8787 .build/out/Products/Release/apple-translate-server
```

服务只绑 `127.0.0.1`，不会触发 macOS 的防火墙弹窗，且是**前台进程**（`Ctrl-C` 退出）。

要放后台就自己重定向日志：

```bash
nohup .build/out/Products/Release/apple-translate-server > /tmp/apple-translate.log 2>&1 &
```

本项目**不做任何开机自启注册** —— 不装 LaunchAgent、不写系统级配置。日志（`AT_LOG=1` 时每条请求一行）全部走 stderr，落到哪由你决定。

## 配置

全部走环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AT_HOST` | `127.0.0.1` | 监听地址 |
| `AT_PORT` | `8787` | 端口 |
| `AT_DEFAULT_SOURCE` | `en` | 源语言判不准时的兜底 |
| `AT_DEFAULT_TARGET` | `zh-Hans` | 请求里没说目标语言时用哪个 |
| `AT_MODEL` | `apple-translate` | 对外报的模型名 |
| `AT_LOG` | `1` | 请求日志打到 stderr |
| `AT_SMART_SKIP` | `1` | 正文已经是目标语言时原样返回，不翻 |
| `AT_MAX_CHARS` | `20000` | 单次请求正文字符上限，超了报 413 |
| `AT_SOURCE_MODE` | `auto` | 源语言策略，见下 |
| `AT_STRATEGY` | 不指定 | `lowLatency` / `highFidelity`（macOS 26.4+）。**实测 en→zh-Hans 上没差别**，见下 |

### `AT_SOURCE_MODE`：短句判错怎么办

框架不认 `auto`，源语言只能自己判，而 `NLLanguageRecognizer` 在短句上错得很自信 —— 实测 4324 条真实英文句子（man page 正文）里，20 条（0.46%）被判成波兰语/葡萄牙语/印尼语等，其中好几条置信度 0.9 以上：

```
-m num, --max-count=num Stop reading the file after num matches.   → pt 0.994
pkcs12 PKCS#12 Data Management.                                    → pl 0.953
72 Unknown TFTP transfer ID.                                        → id 0.919
```

那些语言包没装 → 整条请求 `400 language_not_installed`。置信度阈值救不了，因为它是**自信地判错**。

| 模式 | 行为 | 适合 |
|---|---|---|
| `auto` | 检测器说了算，判错就 400 | 真要区分语种 |
| `english` | 除请求里显式指定的，一律当 `AT_DEFAULT_SOURCE` | 内容 99% 是英文，不想为判错买单 |
| `retry` | 先按检测结果试；**没装包**就用 `AT_DEFAULT_SOURCE` 再试一次 | 默认推荐：装了的语种照常识别，没装的不再白白失败 |

`retry` 实测：上面那 20 条原本必然 400 的句子，**20/20 都返回了正常译文**（日志里留下 `source pt has no pack, retrying as en`）。

### `AT_STRATEGY` 实测：en→zh-Hans 上不需要它

`TranslationSession.Strategy`（macOS 26.4+）有 `highFidelity` / `lowLatency` 两档，[hotchpotch/trn](https://github.com/hotchpotch/trn) 报告 low 档「约快 10 倍」。在这台机器上对 **en→zh-Hans** 实测三档：

| 策略 | 短句中位 | 2415 字符 | 译文 |
|---|---|---|---|
| 不指定（默认） | 23ms | 1253ms | 基准 |
| `lowLatency` | 23ms | 1152ms | 与基准**逐字相同** |
| `highFidelity` | 33ms | 1133ms | 与基准**逐字相同** |

**没差别** —— 那条 10× 是 en→ja 的结论，en↔zh 走的不是同一条路径。所以这个开关留着备用（默认不指定 = 原行为），但别指望它给中英提速。

## 语言包在哪装

系统设置 → **通用 → 语言和地区 → 翻译语言**（直接跳：`open x-apple.systempreferences:com.apple.Localization-Settings.extension`）。

**别拿资产目录判断装没装。** 那底下看到的 `com.apple.sequoia.asset.mt.bi-en-zh-ja-ko.<lang>.20` 是模型包的分片，删掉某个语言包之后它**还留在盘上**，会骗人。唯一可信的判据是框架自己报的状态：

```bash
curl -s "http://127.0.0.1:8787/v1/languages?source=en&target=ja" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pair_status"])'
# installed（装了）/ supported（认得但没下载）/ unsupported（这对不支持）
```

`GET /v1/languages` 不带参数时会列出 `system_supported`（框架认得哪些语言）—— 注意那是**平台能力**，不是本机装了什么。

服务自己**不能**下载语言包（`canRequestDownloads == false`），也不该把 `status()` 当闸门（冷启动会骗人）。只能靠上面那个面板装。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活 + 当前配置 |
| GET | `/v1/models` | OpenAI 的 list 形状 |
| GET | `/v1/languages?source=&target=` | 平台支持的语言 + 本机是否装了这个语言对 |
| POST | `/v1/chat/completions` | **OpenAI 规范**（含 SSE 流式） |
| POST | `/v1/translate` | 简化版：`{"text": "...", "target": "ja", "source": "en"}` |

`/v1/translate` 之外的路径也接受去掉 `/v1` 的写法（`/chat/completions` 等）。

### 目标语言怎么定

优先级从高到低：

1. 非标字段 `target_language` / `target_lang` / `to`
2. **最后一条 user 消息**里解析出来的（`Translate the following into Japanese:` → 日语；`把下面这段翻译成中文：` → 中文）
3. system 提示里提到的
4. `AT_DEFAULT_TARGET`

正文则取最后一条 user 消息：如果首行是指令（`...into Japanese:` / `...翻译成中文：`），冒号之后才是正文；否则整条当正文。剥掉包裹正文的 ``` 围栏。

语言名认 20 种写法（`ja` / `jp` / `Japanese` / `日本語` / `日语` / `日文` 都行）。完整清单见 `GET /v1/languages`。

### 源语言

**必须自己判** —— `TranslationSession` 不接受 `auto`（实测直接抛 `unsupportedSourceLanguage`）。

用系统的 `NLLanguageRecognizer`，但短句会翻车：它认为 “The cat sat on the mat.” 是**土耳其语**（tr 0.58 / en 0.32）。所以 `LanguageDetector.swift` 加了一层「不够自信时偏向 `AT_DEFAULT_SOURCE`」的裁决；置信度 ≥ 0.75 就直接采信，不干扰明确的外语文本。

（别用 `languageHints`：实测只要给英语加任何权重的 hint，德语、法语、土耳其语会被一律判成英语。MoePeek 的 `baseHints` 做法不能照搬。）

## 客户端接法

```
Base URL: http://127.0.0.1:8787/v1
API Key:  随便填（不校验）
Model:    apple-translate
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8787/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="apple-translate",
    messages=[{"role": "user", "content": "Where is the nearest subway station?"}],
).choices[0].message.content)
```

## 性能与限制

- **延迟**：实测 37 字符 ~77ms、5200 字符 ~3.0s。首次调用偏慢（要 warm up），服务启动时会自己预热一次。
- **语言包不会自动下载**：这个模式下 `canRequestDownloads == false`，没装就返回 `400 language_not_installed`，并告诉你去系统设置哪儿装。
- **`LanguageAvailability.status()` 冷启动不可信**：第一次可能报 `supported`（意思是要下载），紧接着就翻译成功。别拿它当闸门 —— 本服务的做法是直接翻，失败了再归类错误。
- **只翻最后一段正文**，不是通用对话模型；system 提示只用来提取语言。
- **`usage` 是按字符数估的假 token**，别拿它算钱。
- 一次连接只处理一个请求（靠 `Connection: close` 划边界），没有 HTTP/1.1 keep-alive 复用。

## 资源占用

`python3 scripts/bench.py` 对着正在跑的服务打，只读 `ps`，不侵入进程。实测（Mac mini M4 / macOS 27）：

| 指标 | 实测 |
|---|---|
| 空载常驻内存 | **~21 MB** |
| 空载 CPU | **0.0%**（连跑 23.5 小时累计 33s） |
| 打完 4200 条请求后 | ~29 MB，增量收敛、静置回落（不是泄漏） |
| 本进程每条请求 CPU | ~6 ms（连接建立 + JSON + 日志） |
| 线程 / fd | 2~3 / 15~16，不随请求增长 |
| 串行吞吐 | 32~37 req/s |
| 8 路并发 | 218ms，0 失败 |

**真正吃资源的不在这个进程里**：翻译运算跑在系统的 `/System/Library/Frameworks/Translation.framework/translationd`，实测 ~420 MB 常驻、约 26 ms CPU/条。它是全系统共享的守护进程（Safari、预览、查词也走它），不是本服务拉起来的，也不归本服务管 —— 想省这 420 MB 就只能不用系统的翻译框架。

延迟随长度近似线性（≈0.5 ms/字符）：

| 输入 | 耗时 |
|---|---|
| 500 字符 | 283ms |
| 2 000 字符 | 955ms |
| 5 000 字符 | 2.49s |
| 10 000 字符 | 4.76s |

排查源语言误判可以用：

```bash
.build/out/Products/Release/apple-translate-server --detect "The cat sat on the mat."
#   tr 0.582
#   en 0.322
# → en
```

## 验收

```bash
./scripts/e2e.sh
```

起一个真服务（独立端口 8791）、发真请求、翻真文本，24 项断言：接口形状、目标语言的可观测性质（日语必须有假名、中文必须有汉字且无假名）、指令切分、SSE、错误码、`openai` SDK 的非流式与流式调用。任一项失败非 0 退出并打印服务日志。

依赖语言包的断言会**跟着系统实际状态走**：装了 `ja` 就要求翻出假名，没装就要求返回明确点名 `ja` 的 `400 language_not_installed` —— 两条路都不许静默翻错，也不会因为某台机器上删了包而假绿。

## 同类项目

调研过 30+ 个仓库，最接近的是 [rock74710/TranslateML](https://github.com/rock74710/TranslateML)（同样只要求 macOS 26.0，同样走 `installedSource:`，也提供了 `/v1/chat/completions`）。

完整对照、协议生态、可直接复用的库、各家踩过的坑，见 [`docs/prior-art.md`](docs/prior-art.md)。

一句话：**「Apple 端上翻译 → 本地 HTTP 服务」至少有 5 个人在做，但「OpenAI 方言 + 任意 source/target + 无 Xcode 的 SwiftPM CLI」这个组合目前只有我们。** 生态主流的接口其实是 DeepL / LibreTranslate / DLX，不是 OpenAI。
