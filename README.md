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

实测这个类**没有 `@MainActor`**，detached Task / 后台队列里调用都正常，多个 session 可以同时存在也不会崩（但框架内部是串行的，别指望并发提速 —— 见「性能与限制」），纯命令行二进制直接跑，不需要 `.app` bundle。

## 要求

| 项 | 要求 |
|---|---|
| 系统 | **macOS 26.0+**（macOS 15–25 用不了，见上） |
| 工具链 | Swift 6（**CommandLineTools 就够**，不需要 Xcode） |
| 语言包 | 在 **系统设置 → 通用 → 语言与地区 → 翻译语言** 里装好要用的语言对 |
| 权限 | 无。Entitlements 是空的 |

## 安装

### Homebrew（推荐）

公式就在主仓库里，不用另开一个 tap 仓库。**第二行的 `brew trust` 别漏** —— Homebrew 7 起，第三方 tap 必须先显式信任，否则它会直接拒绝加载公式（`Error: Refusing to load formula ... from untrusted tap`）：

```bash
brew tap BreakFree003/apple-translate-api https://github.com/BreakFree003/apple-translate-api
brew trust breakfree003/apple-translate-api
brew install apple-translate-api
```

（也可以另开一个 `homebrew-apple-translate-api` 仓库放公式，那样第一行不用带 URL；但 `brew trust` 这步一样跑不掉。）

当后台服务跑 —— launchd 托管，登录后自动起、崩了自动拉起来：

```bash
brew services start apple-translate-api
curl -s http://127.0.0.1:8787/health
brew services stop apple-translate-api      # 不想要常驻就停掉
```

改服务参数**不用碰 plist**。brew services 会读这个文件（一行一个 `KEY=value`，`#` 注释），
它比公式里的默认值优先级更高：

```bash
cat > ~/.homebrew/services/apple-translate-api.env <<'EOF'
AT_PORT=8787
AT_DEFAULT_TARGET=ja
# AT_HOST=0.0.0.0    # 注意：这样就是对外暴露，而本服务没有任何鉴权
EOF
brew services restart apple-translate-api
```

`~/.homebrew` 是 `HOMEBREW_USER_CONFIG_HOME` 的默认值（换过就按你的来）。
日志在 `$(brew --prefix)/var/log/apple-translate-api.log`。

### 从源码

```bash
git clone https://github.com/BreakFree003/apple-translate-api && cd apple-translate-api
swift build -c release
AT_PORT=8787 .build/release/apple-translate-server
```

## 运行

服务只绑 `127.0.0.1`，不会触发 macOS 的防火墙弹窗，且默认是**前台进程**（`Ctrl-C` 退出，`SIGTERM` 也处理了，`brew services stop` 能干净收尾）。

要自己放后台就重定向日志：

```bash
nohup .build/release/apple-translate-server > /tmp/apple-translate.log 2>&1 &
```

日志（`AT_LOG=1` 时每条请求一行）全部走 stderr，落到哪由你决定。
**错误日志不受 `AT_LOG` 控制** —— 端口被占这类启动失败永远打得出来，不会变成安静的 `exit 1`。

```bash
apple-translate-server --version    # apple-translate-server 0.1.0
apple-translate-server --help       # 全部环境变量与开关
```

## 配置

全部走环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AT_HOST` | `127.0.0.1` | 监听地址 |
| `AT_PORT` | `8787` | 端口 |
| `AT_DEFAULT_SOURCE` | `en` | 源语言判不准时的兜底 |
| `AT_DEFAULT_TARGET` | `zh-Hans` | 请求里没说目标语言时用哪个 |
| `AT_MODEL` | `apple-translate` | 对外报的模型名 |
| `AT_LOG` | `1` | 请求日志打到 stderr（**错误日志不受它控制**） |
| `AT_SMART_SKIP` | `1` | 正文已经是目标语言时原样返回，不翻 |
| `AT_MAX_CHARS` | `20000` | 单次请求正文字符上限，超了报 413 |
| `AT_MAX_BODY` | `1048576` | 单次请求正文字节上限（1 MiB）。按 `Content-Length` 就拦，不等收完 |
| `AT_MAX_HEADERS` | `65536` | 请求头字节上限。头收全了也查，超了同样 431（不只防「不发 terminator」） |
| `AT_READ_TIMEOUT` | `30` | 连接建好后等一个完整请求的秒数，`0` = 不超时。只约束收请求，不约束翻译 |
| `AT_SOURCE_MODE` | `english` | 源语言策略，见下。默认**不检测**，一律按 `AT_DEFAULT_SOURCE` 翻 |
| `AT_STRATEGY` | 不指定 | `lowLatency` / `highFidelity`（macOS 26.4+）。**实测 en→zh-Hans 上没差别**，见下 |

### `AT_SOURCE_MODE`：短句判错怎么办

框架不认 `auto`，源语言只能自己判，而 `NLLanguageRecognizer` 在短句上错得很自信 —— 实测 4324 条真实英文句子（man page 正文）里，20 条（0.46%）被判成波兰语/葡萄牙语/印尼语等，其中好几条置信度 0.9 以上：

```
-m num, --max-count=num Stop reading the file after num matches.   → pt 0.994
pkcs12 PKCS#12 Data Management.                                    → pl 0.953
72 Unknown TFTP transfer ID.                                        → id 0.919
```

那些语言包没装 → 整条请求 `400 language_not_installed`。置信度阈值救不了，因为它是**自信地判错**。

**所以这一版把默认值改成了 `english`（不检测）** —— 上面这类误判就不会发生。三种模式的取舍：

| 模式 | 行为 | 适合 |
|---|---|---|
| `english` | 完全不检测，一律当 `AT_DEFAULT_SOURCE`（请求里显式指定的除外） | **默认值**。内容 99% 是英文 —— 整页翻译就是这种 |
| `auto` | 检测器说了算，判错就 400 | 真要区分语种，宁可报错也不静默翻错 |
| `retry` | 先按检测结果试；**没装包**就用 `AT_DEFAULT_SOURCE` 再试一次 | 多语种混杂：装了的语种照常识别，没装的不再白白失败。但英文短句被误判成**已装包**的语种时会静默翻错 |

`retry` 实测：上面那 20 条原本必然 400 的句子，**20/20 都返回了正常译文**（日志里留下 `source pt has no pack, retrying as en`）。

顺带一个反直觉的实测：**检测本身几乎不花钱** —— `auto` 比 `english` 每条只多 **0.7 ms（约 +3%）**。所以默认改成 `english` 是为了**确定性**（不会有「英文短句被判成别的语种」这种意外），不是为了快。

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

### 沉浸式翻译

[沉浸式翻译](https://immersivetranslate.com/) 是浏览器扩展，跟本服务在同一台机器上，能直接连 `127.0.0.1` —— 整页翻译的每段都在你机器上翻完，不出网、不要 Key。

**走它内置的「OpenAI」那一档，不要用 Beta 的「自定义接口」。** 后者要求 `{"source_lang","target_lang","text_list":[…]}` 那种专门格式，本服务没实现。

先起服务（`brew services start apple-translate-api`），然后扩展 **设置 → 翻译服务 → 底部「添加 OpenAI 兼容服务」**（老版本是选 `OpenAI` 再切到「自定义 API Key」），填：

| 字段 | 填什么 |
| --- | --- |
| 自定义翻译服务名称 | `Apple Translate`（随便起） |
| 自定义 API 接口地址 | `http://127.0.0.1:8787/v1/chat/completions` |
| APIKEY | 随便填，如 `sk-local` —— 本服务不校验 |
| 模型 | 勾「输入自定义模型名称」，填 `apple-translate`（即 `AT_MODEL`） |
| 每秒最大请求数 | `2`～`3`，别用默认值 |

最后点「点击测试服务」，翻一段短的确认。

参考量级：一次 **100 段 / 9090 字符**（约等于一篇中等长度的网页）的正文，服务端 **3.1 秒**翻完。

几件要知道的事：

- **源语言默认就固定成英文**（`AT_SOURCE_MODE=english`，不做检测）—— 这个默认值就是为整页翻译设的。整页翻译几乎全是短句，而检测器会**自信地**把英文短句判成别的语言 —— 实测 `-m num, --max-count=num Stop reading the file after num matches.` 判成 `pt 0.994`（英语只有 0.005）。那个语言包没装 → 整条 400，页面上就是一片没翻出来。
  - **要看别的语种 → `AT_SOURCE_MODE=auto`**：检测器说了算，判错就 400（会明确告诉你去装哪个语言包）。
  - **多语种混杂 → `AT_SOURCE_MODE=retry`**：先按检测结果试，检测到的语种没装包才回退到 en，比 `english` 聪明；但英文短句被误判成**已经装包**的语种时会静默翻错。这类句子实测 20/20 都能正常翻出来。
  - `english` 的代价：正文里真混进外语时会拿英语去翻它 —— 实测一段葡萄牙语基本原样返回（只换了标点），无用但不会翻成胡话。
  - 请求里显式给的 `source` 三种模式都不会覆盖（实测 `source: "ja"` 在 `english` 模式下照样按 ja 走，没装包就 400）。
- **地址要写全 `/v1/chat/completions`**，别只写 `http://127.0.0.1:8787`。旧版本扩展（Firefox 商店曾分发的 1.30.2）对只填主机名的写法会拼成 `/chat/completions`，直接 404；写全路径各版本都对。
- **模型名填什么都行**：本服务不读请求里的 `model` 字段，响应里一律回 `AT_MODEL`。扩展爱发的 `temperature` / `max_tokens` / `top_p` 也一律忽略 —— JSON 里多出来的键不会让请求失败。
- **目标语言是扩展写在 prompt 里、由本服务认出来的**（`Translate into Chinese…` / `翻译成中文：`），所以 `AT_DEFAULT_TARGET` 基本用不上。但扩展里选的目标语言如果本地**没装那个语言包**，会回 400 `language_not_installed`，装法见[语言包在哪装](#语言包在哪装)。
- **「每秒最大请求数」要调低**。整页翻译会瞬间产生几十个请求，而本服务受系统框架限制**只能串行翻**（见「性能与限制」），排队会让排在后面的请求等很久；扩展的请求超时在百秒量级，攒多了就开始报错。调到 2~3，让扩展自己控节奏，反而更快更稳。
- **一批太长会被 413**。扩展会把多段合并成一个请求发，超过 `AT_MAX_CHARS`（默认 20000 字符）或 `AT_MAX_BODY`（1 MiB）会被拒。遇到就调大服务端的 `AT_MAX_CHARS`，或在扩展里把每批字符数调小。
- **想完全跳过「猜 prompt」**：在扩展的 `开发者设置 → Edit Full User Config` 里给 `translationServices.openai.bodyConfigs` 加上 `{"target_language": "zh-Hans"}`，本服务认这个非标字段，优先级高于 prompt 解析（见[目标语言怎么定](#目标语言怎么定)）。该字段属于扩展的高级配置，名字和可用性以你装的那个版本为准。

| 现象 | 多半是 |
| --- | --- |
| 404 | 地址没写到 `/v1/chat/completions` |
| 连不上 | 服务没起；或 `AT_HOST` 绑的不是回环 |
| 400 `language_not_installed` | 本地没装该目标语言的语言包 |
| 400 `invalid_request` | 选成了 Beta 的「自定义接口」，body 不是 OpenAI 格式 |
| 413 | 批次太长，见上 |
| 翻得慢 | 排队，调低每秒最大请求数 |

## 安全

- **默认只绑 `127.0.0.1`**，本机之外访问不到，也不会弹防火墙。
- **没有任何鉴权**。一旦 `AT_HOST=0.0.0.0`，同网段任何人都能拿你的机器当翻译机（顺带吃你的 CPU）。真要对外，请自己在前面套一层带认证的反向代理。
- **CORS 回的是 `Access-Control-Allow-Origin: *`** —— 你浏览器里打开的任意网页都能访问 `http://127.0.0.1:8787` 并把内容送进来翻译。本地工具的常见取舍，能接受就用；介意的话在网关层收口。

## 性能与限制

- **延迟**：≈ `16 ms + 0.32 ms/字`（en→zh-Hans）：50 字 32 ms、500 字 176 ms、5000 字 1.73 s、10000 字 3.38 s。首次调用偏慢（要 warm up），服务启动时会自己预热一次。
- **语言包不会自动下载**：这个模式下 `canRequestDownloads == false`，没装就返回 `400 language_not_installed`，并告诉你去系统设置哪儿装。
- **`LanguageAvailability.status()` 冷启动不可信**：第一次可能报 `supported`（意思是要下载），紧接着就翻译成功。别拿它当闸门 —— 本服务的做法是直接翻，失败了再归类错误。
- **只翻最后一段正文**，不是通用对话模型；system 提示只用来提取语言。
- **`usage` 是按字符数估的假 token**，别拿它算钱。
- **并发是假的，排队是真的**：`Translation` 框架内部就是串行的 —— 一条 12000 字的 en→zh-Hans 在飞时，
  **另一个语言对**（zh-Hans→en）的小请求照样要等满 5.4s（对同一台机器上未改动的版本做对照实验是 5.1s）。
  所以上面那行「8 路并发 264 ms」是把 8 条请求排着队跑完的总时间 —— 实测和 8 条串行（277 ms）几乎一样，
  **不是 8 路并行**。发 32 条也一样：墙钟线性涨，req/s 恒定在 30 上下。
  服务端按语言对缓存 session，并用一把**显式的闸门**（`SerialGate`）把同一 session 的调用排成队 ——
  注意这里不能只包一层 actor：actor 在 `await` 处是可重入的，「包个 actor 就等于串行」是错的
  （这个错在本项目里真实存在过两轮）。排队**换不来吞吐**。**多开进程也没用**：实测两个进程各绑一个端口（`AT_PORT=8793` / `8794`），大请求在 A 上飞时，
  B 上的短句请求从空载 **0.06s** 变成 **2.92s** —— 串行点在系统共享的 `translationd` 里，不在本服务里。
  所以能做的只有「别堆并发、把请求切小」，真要吞吐只能等 Apple 改框架。
- **一次连接一个请求**（`Connection: close`），没有 keep-alive 复用；连上不发的连接 30 秒会被踢掉（`AT_READ_TIMEOUT`）。
- **`Content-Length` 之外的传输方式不支持**：chunked 请求体会明确返回 `411 length_required`（不会静默当成空 body）。

## 资源占用

`python3 scripts/bench.py` 对着正在跑的服务打，只读 `ps`，不侵入进程。实测（Mac mini M4 / 10 核 / 16 GB / macOS 27.0.1）：

| 指标 | 实测 |
|---|---|
| 空载常驻内存 | **~20 MB** |
| 空载 CPU | **0.00%**（30 秒窗口增量 0.000s） |
| 打完 1000 条请求 | 19.9 → 19.7 MB，静置 30 秒再 −0.06 MB —— **没有增长**，不是泄漏 |
| 本进程每条请求 CPU | 4~6 ms（连接建立 + JSON + 日志；长文本档 6 ms） |
| 线程 / fd | 6 / 11，不随请求增长 |
| 串行吞吐 | **~31 req/s**（200 条 40 字，0 失败；短请求延迟中位 31.8 ms） |
| 8 路并发发出 | 264 ms，8/8 成功 0 失败 —— 而 8 条**串行**是 277 ms，即并发加速比 **1.05×** |
| 冷启动 | exec 到 `/health` 能应答约 12 ms（热页缓存），首条翻译约 95 ms |

（测量条件：`AT_LOG=0`，机器**不空闲**（loadavg 1.7~3.2），取中位数；可重复性约 ±10%。）

**真正吃资源的不在这个进程里**：翻译运算跑在系统的 `/System/Library/Frameworks/Translation.framework/translationd`，实测常驻 **~320~360 MB**，CPU 时间几乎等于墙钟（翻的时候基本吃满一个核）：40 字约 28 ms、500 字约 174 ms、5000 字约 1.7 s、10000 字约 3.4 s，也就是 **~0.32 ms/字**。它是全系统共享的守护进程（Safari、预览、查词也走它），不是本服务拉起来的，也不归本服务管 —— 想省这几百 MB 就只能不用系统的翻译框架。

延迟随长度近似线性 —— 200 字以下是固定开销主导，500 字以上约 `16 ms + 0.32 ms/字`（en→zh-Hans，每档 5 次取中位）：

| 输入 | 中位耗时 | 本进程 CPU/条 | translationd CPU/条 | 吞吐 |
|---|---|---|---|---|
| 50 字符 | 32 ms | 4 ms | 28 ms | ~1.5k 字符/s |
| 500 字符 | 176 ms | 4 ms | 174 ms | ~2.8k 字符/s |
| 2 000 字符 | 678 ms | 4 ms | 686 ms | ~2.9k 字符/s |
| 5 000 字符 | 1.73 s | 6 ms | 1.70 s | ~2.9k 字符/s |
| 10 000 字符 | 3.38 s | 6 ms | 3.36 s | ~3.0k 字符/s |

换成**真实非重复语料**会比上表慢 12~14%（重复句子能被框架里的缓存/预测帮到，偏乐观）。

排查源语言误判可以用：

```bash
.build/release/apple-translate-server --detect "The cat sat on the mat."
#   tr 0.582
#   en 0.322
# → en
```

## 测试

```bash
./scripts/test.sh   # 40 个单测：HTTP 解析、串行闸门、prompt 切分、语言目录、配置解析（不碰翻译框架）
./scripts/e2e.sh    # 端到端验收，需要语言包
```

**为什么单测要过一层 `scripts/test.sh`。** 只装 CommandLineTools 的机器上，裸 `swift test` 的增量构建有时会在显式 module 的插件列表里漏掉 `TestingMacros`：

```
error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
       could not be found for macro 'Test'; plugin for module 'TestingMacros' not found
```

实测裸跑是 PASS/FAIL 交替（连跑 4 次挂 2 次），显式给出 `-plugin-path` 之后 4/4 通过。脚本就是替你加这个参数（也兼容装了完整 Xcode 的机器），**这个报错跟本项目的代码无关**。撞上了手动加也行：

```bash
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

## 验收

```bash
./scripts/e2e.sh
```

（`AT_BIN=/opt/homebrew/bin/apple-translate-server ./scripts/e2e.sh` 可以改成验收 brew 装的那个二进制。）

起**两个**真服务 —— 默认配置的 8791，和显式开了 `AT_SOURCE_MODE=auto` 的 8792（后者专测源语言检测那两条断言）—— 发真请求、翻真文本，25 项断言：接口形状、默认固定英文、检测能力、目标语言的可观测性质（日语必须有假名、中文必须有汉字且无假名）、指令切分、SSE、错误码、`openai` SDK 的非流式与流式调用。任一项失败非 0 退出并打印两个服务的日志。

依赖语言包的断言会**跟着系统实际状态走**：装了 `ja` 就要求翻出假名，没装就要求返回明确点名 `ja` 的 `400 language_not_installed` —— 两条路都不许静默翻错，也不会因为某台机器上删了包而假绿。

## 发布

版本号只有一处：`Sources/AppleTranslateServer/Version.swift`。改完提交，然后：

```bash
./scripts/release.sh 0.1.0          # 干跑：查版本号/工作树/tag 冲突，跑构建和单测
./scripts/release.sh 0.1.0 --go     # 打 tag → push → 抓 GitHub tarball 算 sha256 → 写进 formula
```

那个 `sha256` 只有 tag 推上去之后才算得出来，所以它交给脚本，别手抄 —— 抄错了 brew 只会回一句 `SHA256 mismatch`。

`--go` 之后还有一步：把 `Formula/apple-translate-api.rb` **提交进主仓库**（脚本已经替你改好 url/sha256，但不替你 commit）。要是你另开了 `homebrew-apple-translate-api` 仓库，再把它复制过去。

## 同类项目

调研过 30+ 个仓库，最接近的是 [rock74710/TranslateML](https://github.com/rock74710/TranslateML)（同样只要求 macOS 26.0，同样走 `installedSource:`，也提供了 `/v1/chat/completions`）。

完整对照、协议生态、可直接复用的库、各家踩过的坑，见 [`docs/prior-art.md`](docs/prior-art.md)。

一句话：**「Apple 端上翻译 → 本地 HTTP 服务」至少有 5 个人在做，但「OpenAI 方言 + 任意 source/target + 无 Xcode 的 SwiftPM CLI」这个组合目前只有我们。** 生态主流的接口其实是 DeepL / LibreTranslate / DLX，不是 OpenAI。

## 许可

MIT，见 [LICENSE](LICENSE)。
