# apple-translate-api

把 **macOS 自带的端上翻译**（Apple 的 `Translation` 框架）包成一个 **OpenAI 兼容**的本地 HTTP 服务 —— 全离线、不要 API key、不要联网、不申请任何权限。

任何认 OpenAI 接口的客户端（[沉浸式翻译](#沉浸式翻译)、Bob、Chatbox、各种 SDK、你自己的脚本）把 `base_url` 指过来就能当翻译用。

```bash
# 装并启动（第二行别漏，Homebrew 7 要求显式信任第三方 tap）
brew tap BreakFree003/apple-translate-api https://github.com/BreakFree003/apple-translate-api
brew trust breakfree003/apple-translate-api
brew install apple-translate-api
brew services start apple-translate-api

curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello, world."}]}' | jq -r '.choices[0].message.content'
# -> 你好，世界。
```

## 要求

| 项 | 要求 |
|---|---|
| 系统 | **macOS 26.0+**。`TranslationSession(installedSource:target:)` 是 macOS 26 才有的 API，之前的系统用不了 |
| 工具链 | Swift 6。**只装 CommandLineTools 就够**，不需要 Xcode（`brew install` 会自己构建） |
| 语言包 | 需要你在系统设置里装。**这是最容易踩的一步**，见[语言包](#语言包) |
| 权限 | 无。Entitlements 是空的 |
| 网络 | 不需要。翻译全在本机 |

## 安装

### Homebrew（推荐）

```bash
brew tap BreakFree003/apple-translate-api https://github.com/BreakFree003/apple-translate-api
brew trust breakfree003/apple-translate-api
brew install apple-translate-api
```

`brew trust` 这行不能省：Homebrew 7 起会拒绝加载第三方 tap 里的公式，漏掉会报
`Error: Refusing to load formula ... from untrusted tap`。

（也可以另开一个 `homebrew-apple-translate-api` 仓库专门放公式，那样第一行不用带 URL；`brew trust` 一样跑不掉。）

### 当后台服务跑

```bash
brew services start apple-translate-api     # launchd 托管：登录自启、崩了自动拉起
curl -s http://127.0.0.1:8787/health
brew services stop apple-translate-api      # 不想要常驻就停掉
```

日志在 `$(brew --prefix)/var/log/apple-translate-api.log`。

改服务参数**不用碰 plist**。brew services 会读这个文件，一行一个 `KEY=value`（支持 `#` 注释），**优先级高于公式里的默认值**：

```bash
cat > ~/.homebrew/services/apple-translate-api.env <<'EOF'
AT_LOG=0
AT_PORT=8787
EOF
brew services restart apple-translate-api
```

（`~/.homebrew` 是 `HOMEBREW_USER_CONFIG_HOME` 的默认值，换过就按你的来。）

### 从源码

```bash
git clone https://github.com/BreakFree003/apple-translate-api
cd apple-translate-api
swift build -c release
AT_PORT=8787 .build/release/apple-translate-server
```

## 用法

服务只绑 `127.0.0.1`，不会触发防火墙弹窗，默认是**前台进程**（`Ctrl-C` 退出，`SIGTERM` 也处理了，`brew services stop` 能干净收尾）。

```bash
# OpenAI 兼容接口
curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Translate into Japanese: Good morning!"}]}'

# 简化接口：直接给正文和目标语言
curl -s http://127.0.0.1:8787/v1/translate \
  -H 'Content-Type: application/json' \
  -d '{"text":"Good morning!","target":"ja"}'
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8787/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="apple-translate",
    messages=[{"role": "user", "content": "Where is the nearest subway station?"}],
).choices[0].message.content)
```

流式（SSE）与非流式都支持，`GET /health`、`GET /v1/models`、`GET /v1/languages` 用于探活和查询能力。

```bash
apple-translate-server --version    # apple-translate-server 0.1.0
apple-translate-server --help       # 全部环境变量与开关
```

日志（`AT_LOG=1` 时每条请求一行）走 stderr。**错误日志不受 `AT_LOG` 控制** —— 端口被占这类启动失败永远打得出来，不会变成安静的 `exit 1`。

## 客户端配置

### 沉浸式翻译

[沉浸式翻译](https://immersivetranslate.com/) 是浏览器扩展，跟本服务在同一台机器上，能直接连 `127.0.0.1` —— 整页翻译的每段都在你机器上翻完，不出网、不要 Key。

**走它内置的「OpenAI」那一档，不要用 Beta 的「自定义接口」**：后者要求 `{"source_lang","target_lang","text_list":[…]}` 这种专门格式，本服务没实现。

**设置 → 翻译服务 → 底部「添加 OpenAI 兼容服务」**（老版本是选 `OpenAI` 再切到「自定义 API Key」），填：

| 字段 | 填什么 |
| --- | --- |
| 自定义翻译服务名称 | `Apple Translate`（随便起） |
| 自定义 API 接口地址 | `http://127.0.0.1:8787/v1/chat/completions` |
| APIKEY | 随便填，如 `sk-local` —— 本服务不校验 |
| 模型 | 勾「输入自定义模型名称」，填 `apple-translate`（即 `AT_MODEL`） |
| 每秒最大请求数 | `2`～`3`，别用默认值 |

最后点「点击测试服务」，翻一段短的确认。参考量级：一次 100 段 / 9000 字符（约一篇中等长度的网页）的正文，服务端 3 秒左右翻完。

几件要知道的事：

- **地址要写全 `/v1/chat/completions`**，别只写 `http://127.0.0.1:8787`。老版本扩展（Firefox 商店曾分发的 1.30.2）对只填主机名的写法会拼成 `/chat/completions`，直接 404。
- **模型名填什么都行**：本服务不读请求里的 `model` 字段，响应里一律回 `AT_MODEL`。扩展爱发的 `temperature` / `max_tokens` / `top_p` 也一律忽略 —— JSON 里多出来的键不会让请求失败。
- **目标语言是扩展写在 prompt 里、由本服务认出来的**（`Translate into Chinese…` / `翻译成中文：`），所以 `AT_DEFAULT_TARGET` 基本用不上。但扩展里选的目标语言如果本地**没装那个语言包**，会回 400 `language_not_installed`，装法见[语言包](#语言包)。
- **「每秒最大请求数」要调低**。整页翻译会瞬间产生几十个请求，而本服务受系统框架限制**只能串行翻**（见[性能与限制](#性能与限制)），排队会让排在后面的请求等很久；扩展的请求超时在百秒量级，攒多了就开始报错。调到 2~3，让扩展自己控节奏，反而更快更稳。
- **一批太长会被 413**。扩展会把多段合并成一个请求发，超过 `AT_MAX_CHARS`（默认 20000 字符）或 `AT_MAX_BODY`（1 MiB）会被拒。遇到就调大服务端的 `AT_MAX_CHARS`，或在扩展里把每批字符数调小。
- **想完全跳过「猜 prompt」**：在扩展的 `开发者设置 → Edit Full User Config` 里给 `translationServices.openai.bodyConfigs` 加上 `{"target_language": "zh-Hans"}`，本服务认这个非标字段，优先级高于 prompt 解析（见[目标语言怎么定](#目标语言怎么定)）。该字段属于扩展的高级配置，名字和可用性以你装的版本为准。

| 现象 | 多半是 |
| --- | --- |
| 404 | 地址没写到 `/v1/chat/completions` |
| 连不上 | 服务没起；或 `AT_HOST` 绑的不是回环 |
| 400 `language_not_installed` | 本地没装该目标语言的语言包 |
| 400 `invalid_request` | 选成了 Beta 的「自定义接口」，body 不是 OpenAI 格式 |
| 413 | 批次太长，见上 |
| 翻得慢 | 排队，调低每秒最大请求数 |

### 其它 OpenAI 客户端

```
Base URL: http://127.0.0.1:8787/v1
API Key:  随便填（不校验）
Model:    apple-translate
```

## 配置

全部走环境变量（`brew services` 用户改 `~/.homebrew/services/apple-translate-api.env`）：

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
| `AT_MAX_HEADERS` | `65536` | 请求头字节上限。头收全了也查，超了报 431 |
| `AT_READ_TIMEOUT` | `30` | 连接建好后等一个完整请求的秒数，`0` = 不超时。只约束收请求，不约束翻译 |
| `AT_SOURCE_MODE` | `english` | 源语言策略：`english` / `auto` / `retry`，见下 |
| `AT_STRATEGY` | 不指定 | `lowLatency` / `highFidelity`（macOS 26.4+），见下 |

### `AT_SOURCE_MODE`：源语言怎么定

`TranslationSession` 不接受 `auto`，源语言**必须自己判**。而系统检测器 `NLLanguageRecognizer` 在短句上会**自信地判错** —— 4324 条真实英文句子（man page 正文）里有 20 条（0.46%）被判成波兰语/葡萄牙语/印尼语等，好几句置信度 0.9 以上：

```
-m num, --max-count=num Stop reading the file after num matches.   → pt 0.994
pkcs12 PKCS#12 Data Management.                                    → pl 0.953
72 Unknown TFTP transfer ID.                                        → id 0.919
```

这些语言包没装 → 整条请求 `400 language_not_installed`。置信度阈值救不了，因为它是**自信地判错**；整页翻译时表现为「一大片没翻出来」。所以本服务的默认策略是**不检测**：

| 模式 | 行为 | 适合 |
|---|---|---|
| `english`（默认） | 完全不检测，一律当 `AT_DEFAULT_SOURCE`（请求里显式指定的除外） | 内容以英文为主 —— 整页翻译通常就是这种 |
| `auto` | 检测器说了算，判错就 400 | 真要区分语种，宁可报错也不静默翻错 |
| `retry` | 先按检测结果试；**没装包**就用 `AT_DEFAULT_SOURCE` 再试一次 | 多语种混杂：装了的语种照常识别，没装的不再白白失败 |

`retry` 实测：上面那 20 条原本必然 400 的句子，20/20 都返回了正常译文。

两个诚实的补充：`english` 模式下正文真混进外语时会拿英语去翻它（实测一段葡萄牙语基本原样返回，**HTTP 200 而不是报错** —— 表现是「这段没翻」，不会翻成胡话）；`retry` 则在英文短句被误判成**已装包**的语种时会静默翻错。另外，检测本身几乎不花钱（`auto` 比 `english` 每条只多 0.7 ms），所以默认选 `english` 是为了**确定性**，不是为了快。

### `AT_STRATEGY`：en→zh-Hans 上不需要它

`TranslationSession.Strategy`（macOS 26.4+）有 `highFidelity` / `lowLatency` 两档，[hotchpotch/trn](https://github.com/hotchpotch/trn) 报告 low 档「约快 10 倍」。在本机对 **en→zh-Hans** 实测三档：

| 策略 | 短句中位 | 2415 字符 | 译文 |
|---|---|---|---|
| 不指定（默认） | 23ms | 1253ms | 基准 |
| `lowLatency` | 23ms | 1152ms | 与基准**逐字相同** |
| `highFidelity` | 33ms | 1133ms | 与基准**逐字相同** |

**没差别** —— 那条 10× 是 en→ja 的结论，en↔zh 走的不是同一条路径。开关留着备用，别指望它给中英提速。

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

正文取最后一条 user 消息：首行若是指令（`...into Japanese:` / `...翻译成中文：`），冒号之后才是正文，否则整条当正文；包裹正文的 ``` 围栏会被剥掉。语言名认 20 种写法（`ja` / `jp` / `Japanese` / `日本語` / `日语` / `日文` 都行），完整清单见 `GET /v1/languages`。

`source` 只能自己给或由 `AT_SOURCE_MODE` 决定 —— 框架不接受 `auto`。检测走 `NLLanguageRecognizer`，另加了一层「不够自信时偏向 `AT_DEFAULT_SOURCE`」的裁决（置信度 ≥ 0.75 直接采信）。

## 语言包

**服务不会替你下载语言包，也不能**（这个模式下 `canRequestDownloads == false`）。没装的语言对会明确返回 `400 language_not_installed`，并告诉你去哪儿装：

> 系统设置 → **通用 → 语言和地区 → 翻译语言**
> （直接跳：`open x-apple.systempreferences:com.apple.Localization-Settings.extension`）

**别拿资产目录判断装没装。** 那底下的 `com.apple.sequoia.asset.mt.bi-en-zh-ja-ko.<lang>.20` 是模型分片，删掉某个语言包之后它**还留在盘上**，会骗人。唯一可信的判据是框架自己报的状态：

```bash
curl -s "http://127.0.0.1:8787/v1/languages?source=en&target=ja" | jq -r .pair_status
# installed（装了）/ supported（认得但没下载）/ unsupported（这对不支持）
```

`GET /v1/languages` 不带参数时列出的 `system_supported` 是**平台能力**，不是本机装了什么。另外 `LanguageAvailability.status()` 冷启动不可信（第一次可能报 `supported`，紧接着就翻译成功），别拿它当闸门 —— 本服务的做法是直接翻，失败了再归类错误。

## 性能与限制

- **延迟**：≈ `16 ms + 0.32 ms/字`（en→zh-Hans）：50 字 32 ms、500 字 176 ms、5000 字 1.73 s、10000 字 3.38 s。200 字以下是固定开销主导。首次调用偏慢（要 warm up），服务启动时会自己预热一次。
- **并发是假的，排队是真的**：系统 `Translation` 框架内部就是串行的 —— 8 条并发发出 264 ms，而 8 条**串行**是 277 ms（加速比 1.05×）；N 从 1 到 32，req/s 恒定在 30 上下。**多开进程也没用**（实测两个进程各绑一个端口，大请求在飞时另一个进程上的短句从 0.06 s 变成 2.92 s）—— 串行点在系统共享的 `translationd` 里，不在本服务里。要做批量翻译就串行慢慢来，别堆并发。
- **一次连接一个请求**（`Connection: close`），没有 keep-alive 复用；连上不发的连接 30 秒会被踢掉（`AT_READ_TIMEOUT`）。
- **请求体必须带 `Content-Length`**：chunked 明确返回 `411 length_required`（不会静默当成空 body）。
- **只翻正文，不是通用对话模型**：system 提示只用来提取语言；`usage` 是按字符数估的假 token，别拿它算钱。
- **延迟随长度近似线性**，但 2000 字以下的小请求差异不大；重复句子会被框架里的缓存/预测帮到，真实非重复语料比上表慢 12~14%。

### 资源占用

`python3 scripts/bench.py` 对着正在跑的服务打，只读 `ps`，不侵入进程。实测（Mac mini M4 / 10 核 / 16 GB / macOS 27.0.1）：

| 指标 | 实测 |
|---|---|
| 空载常驻内存 | ~20 MB |
| 空载 CPU | 0.00% |
| 打完 1000 条请求 | 19.9 → 19.7 MB，静置 30 秒再 −0.06 MB（没有增长，不是泄漏） |
| 本进程每条请求 CPU | 4~6 ms |
| 线程 / fd | 6 / 11，不随请求增长 |
| 串行吞吐 | ~31 req/s（40 字正文） |
| 冷启动 | exec 到 `/health` 能应答约 12 ms，首条翻译约 95 ms |

**真正吃资源的不在这个进程里**：翻译运算跑在系统的 `translationd`，常驻 **~320~360 MB**，翻的时候基本吃满一个核（~0.32 ms/字）：500 字约 174 ms、10000 字约 3.4 s。它是全系统共享的守护进程（Safari、预览、查词也走它），不是本服务拉起来的 —— 想省这几百 MB 就只能不用系统的翻译框架。

（上表在**非空闲**机器上取的，中位数，可重复性约 ±10%。）

### 安全

- **默认只绑 `127.0.0.1`**，本机之外访问不到，也不会弹防火墙。
- **没有任何鉴权**。一旦 `AT_HOST=0.0.0.0`，同网段任何人都能拿你的机器当翻译机（顺带吃你的 CPU）。真要对外，请自己在前面套一层带认证的反向代理。
- **CORS 回的是 `Access-Control-Allow-Origin: *`** —— 你浏览器里打开的任意网页都能访问 `http://127.0.0.1:8787` 并把内容送进来翻译。本地工具的常见取舍，能接受就用；介意的话在网关层收口。

## 排错

| 现象 | 原因 / 怎么办 |
|---|---|
| 400 `language_not_installed` | 语言包没装。装法见[语言包](#语言包)；消息里会点名是哪个语言对 |
| 400 `unsupported_target_language` / `unsupported_source_language` | 语言名不在支持的 20 种里，`GET /v1/languages` 有完整清单 |
| 400 `unsupported_language_pair` | 框架不支持这一对语言 |
| 400 `empty_input` | 没给正文 |
| 400 `invalid_request` | body 不是 OpenAI chat completions 格式（比如给别的工具用的「自定义接口」格式） |
| 400 `invalid_content_length` | `Content-Length` 非法或重复出现 |
| 411 `length_required` | 用了 chunked，请改成带 `Content-Length` |
| 413 `input_too_long` / `body_too_large` | 超过 `AT_MAX_CHARS` / `AT_MAX_BODY`，按需调大 |
| 431 `headers_too_large` | 请求头超过 `AT_MAX_HEADERS` |
| 502 `translation_failed` | 框架自己报的错，日志里有原文 |
| 启动即退出、日志说 `Address already in use` | 端口被占，改 `AT_PORT` 或停掉占用的进程 |

源语言判得可疑时，直接用 CLI 看检测器怎么想：

```bash
apple-translate-server --detect "The cat sat on the mat."
#   tr 0.582
#   en 0.322
# → en
```

## 开发

```bash
./scripts/test.sh    # 40 个单测：HTTP 解析、串行闸门、prompt 切分、语言目录、配置解析（不碰翻译框架）
./scripts/e2e.sh     # 端到端验收：起两个真服务、发真请求、翻真文本，25 项断言（需要语言包）
```

`./scripts/test.sh` 而不是裸 `swift test`：只装 CommandLineTools 的机器上，裸 `swift test` 的增量构建有时会在显式 module 的插件列表里漏掉 `TestingMacros`（报 `plugin for module 'TestingMacros' not found`，与本项目代码无关）；脚本会给编译器显式指定那个插件目录，4/4 稳定通过。

e2e 依赖语言包的断言会**跟着系统实际状态走**：装了 `ja` 就要求翻出假名，没装就要求返回明确点名 `ja` 的 `400 language_not_installed` —— 两条路都不许静默翻错。CI（`.github/workflows/ci.yml`，`macos-26`）只跑构建 + 单测 + CLI 自检，不跑 e2e。

发布流程：版本号只有 `Sources/AppleTranslateServer/Version.swift` 一处，改完提交后

```bash
./scripts/release.sh 0.1.0          # 干跑：查版本号/工作树/tag 冲突，跑构建和单测
./scripts/release.sh 0.1.0 --go     # 打 tag → push → 抓 GitHub tarball 算 sha256 → 写进 formula
```

那个 `sha256` 只有 tag 推上去之后才算得出来，所以交给脚本，别手抄 —— 抄错了 brew 只会回一句 `SHA256 mismatch`。

## 同类项目

调研过 30+ 个仓库，最接近的是 [rock74710/TranslateML](https://github.com/rock74710/TranslateML)（同样只要求 macOS 26.0，同样走 `installedSource:`，也提供了 `/v1/chat/completions`）。完整对照、协议生态、各家踩过的坑见 [`docs/prior-art.md`](docs/prior-art.md)。

一句话：**「Apple 端上翻译 → 本地 HTTP 服务」至少有 5 个人在做，但「OpenAI 方言 + 任意 source/target + 无 Xcode 的 SwiftPM CLI」这个组合目前只有这里。** 生态主流的接口其实是 DeepL / LibreTranslate / DLX，不是 OpenAI。

## 许可

MIT，见 [LICENSE](LICENSE)。
