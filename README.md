# apple-translate-api

把 **macOS 自带的端上翻译**（Apple 的 `Translation` 框架）包成一个 **OpenAI 兼容**的本地 HTTP 服务 —— 全离线、不要 API key、不要联网、不申请任何权限。

任何认 OpenAI 接口的东西（沉浸式翻译、Chatbox、各种 SDK、你自己的脚本）把 `base_url` 指过来就能当翻译用。

## 快速开始

```bash
brew tap BreakFree003/apple-translate-api https://github.com/BreakFree003/apple-translate-api
brew trust breakfree003/apple-translate-api       # Homebrew 7 起，第三方 tap 必须显式信任
brew install apple-translate-api
brew services start apple-translate-api           # 后台常驻（launchd 托管）

curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello, world."}]}' | jq -r '.choices[0].message.content'
# -> 你好，世界。
```

## 要求

| 项 | 要求 |
|---|---|
| 系统 | **macOS 26.0+** |
| 构建工具 | Swift 6。**只装 CommandLineTools 就够**，不需要 Xcode（用 brew 装的话 Homebrew 会自己构建） |
| 语言包 | 要用的语言对得先装：**系统设置 → 通用 → 语言与地区 → 翻译语言**。见[语言包](#语言包) |
| 权限 | 无 |
| 网络 | 不需要，翻译全在本机 |

## 安装

### Homebrew（推荐）

见上面[快速开始](#快速开始)。公式就在主仓库里，不用另开一个 tap 仓库；第一行的 URL 不能省（仓库名不是 `homebrew-` 前缀），第二行的 `brew trust` 也不能省。

服务参数**不用碰 plist**：brew services 会读这个文件（一行一个 `KEY=value`，`#` 注释），优先级高于公式里的默认值。

```bash
cat > ~/.homebrew/services/apple-translate-api.env <<'EOF'
AT_PORT=8787
AT_LOG=0
EOF
brew services restart apple-translate-api
```

`~/.homebrew` 是 `HOMEBREW_USER_CONFIG_HOME` 的默认值。注意**权限别放开**：这个文件如果是 group/世界可写的，brew services 会**静默忽略**它（只在终端上打一句警告），你会以为配置生效了其实没有。`0644` 就安全。

日志在 `$(brew --prefix)/var/log/apple-translate-api.log`。

卸载：

```bash
brew services stop apple-translate-api
brew uninstall apple-translate-api
brew untap breakfree003/apple-translate-api
rm -f ~/.homebrew/services/apple-translate-api.env   # 除非你建过
```

### 从源码

```bash
git clone https://github.com/BreakFree003/apple-translate-api
cd apple-translate-api
swift build -c release
AT_PORT=8787 .build/release/apple-translate-server
```

如果已经用 brew 把服务跑在 8787 上了，这里会撞 `Address already in use` —— 先 `brew services stop apple-translate-api`，或者换个 `AT_PORT`。

## 用法

```bash
# 最简：一条 user 消息
curl -s http://127.0.0.1:8787/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello, world."}]}'

# 指定目标语言（也可以直接指定语言对，见「接口」）
curl -s http://127.0.0.1:8787/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Translate into Chinese:\nGood morning!"}]}'
```

示例都用中文（`zh-Hans`）。**换成本机没装包的语言会返回 `400 language_not_installed`**，按提示去系统设置里装。

任何 OpenAI SDK：

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8787/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="apple-translate",
    messages=[{"role": "user", "content": "Where is the nearest subway station?"}],
).choices[0].message.content)
```

其它命令：

```bash
apple-translate-server --version    # apple-translate-server 0.1.0
apple-translate-server --help       # 全部环境变量与开关
apple-translate-server --detect -   # 从 stdin 逐行看语言检测结果，排查源语言判错
```

日志全部走 stderr（`AT_LOG=1` 时每条请求一行，`AT_LOG=0` 关掉请求日志）。**启动失败的日志不受 `AT_LOG` 控制**，端口被占这类问题永远打得出来。

## 客户端配置

### 沉浸式翻译

[沉浸式翻译](https://immersivetranslate.com/) 是浏览器扩展，跟本服务在同一台机器上，能直接连 `127.0.0.1` —— 整页翻译的每段都在你机器上翻完。

**走它内置的「OpenAI」那一档，不要用 Beta 的「自定义接口」。** 后者要求 `{"source_lang","target_lang","text_list":[…]}` 那种专门格式，本服务没实现。

扩展 **设置 → 翻译服务 → 底部「添加 OpenAI 兼容服务」**（老版本是选 `OpenAI` 再切到「自定义 API Key」），填：

| 字段 | 填什么 |
| --- | --- |
| 自定义翻译服务名称 | `Apple Translate`（随便起） |
| 自定义 API 接口地址 | `http://127.0.0.1:8787/v1/chat/completions` |
| APIKEY | 随便填，如 `sk-local` —— 本服务不校验 |
| 模型 | 勾「输入自定义模型名称」，填 `apple-translate` |
| 每秒最大请求数 | `2`～`3`，别用默认值 |

然后点「点击测试服务」翻一段短的确认。

- **地址要填到具体路径。** 只填 `http://127.0.0.1:8787` 会打到根路径，返回 `404 not_found`。`/v1` 可以省（`.../chat/completions` 同样有效），但推荐写全。
- **模型名填什么都行**：本服务不读请求里的 `model`，响应里一律回 `AT_MODEL`。`temperature` / `max_tokens` / `top_p` 这些也一律忽略，不会因为多带了字段而失败。
- **目标语言是扩展写在 prompt 里、由本服务认出来的**，所以 `AT_DEFAULT_TARGET` 基本用不上。扩展里选的目标语言如果本地没装包，会回 `400 language_not_installed`。
- **「每秒最大请求数」要调低。** 整页翻译会瞬间产生几十个请求，而本服务**只能串行翻**（见[性能与限制](#性能与限制)），排队会让排在后面的请求等很久。调到 2~3，让扩展自己控节奏，反而更快更稳。
- **一批太长会被 413。** 扩展会把多段合并成一个请求发，超过 `AT_MAX_CHARS`（默认 20000 字符）或 `AT_MAX_BODY`（1 MiB）会被拒。遇到就调大服务端的 `AT_MAX_CHARS`，或在扩展里把每批字符数调小。
- **想完全跳过「猜 prompt」**：在扩展的 `开发者设置 → Edit Full User Config` 里给 `translationServices.openai.bodyConfigs` 加上 `{"target_language": "zh-Hans"}`，本服务认这个非标字段，优先级高于 prompt 解析。该字段属于扩展的高级配置，名字和可用性以你装的那个版本为准。

### 其它客户端

```
Base URL: http://127.0.0.1:8787/v1
API Key:  随便填（不校验）
Model:    apple-translate
```

## 配置

全部通过环境变量（brew services 用户写在 `~/.homebrew/services/apple-translate-api.env` 里）。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `AT_HOST` | `127.0.0.1` | 监听地址 |
| `AT_PORT` | `8787` | 端口 |
| `AT_DEFAULT_SOURCE` | `en` | 源语言判不准时的兜底 |
| `AT_DEFAULT_TARGET` | `zh-Hans` | 请求里没说目标语言时用哪个 |
| `AT_MODEL` | `apple-translate` | 对外报的模型名 |
| `AT_LOG` | `1` | 请求日志打到 stderr（启动失败的日志不受它控制） |
| `AT_SMART_SKIP` | `1` | 正文已经是目标语言时原样返回，不翻 |
| `AT_SOURCE_MODE` | `english` | 源语言策略，见下 |
| `AT_MAX_CHARS` | `20000` | 单次请求正文字符上限，超了 413 |
| `AT_MAX_BODY` | `1048576` | 正文**字节**上限（1 MiB）。按 `Content-Length` 就拦，不等收完 |
| `AT_MAX_HEADERS` | `65536` | 请求头字节上限 |
| `AT_READ_TIMEOUT` | `30` | 等一个完整请求的秒数，`0` = 不超时。只约束收请求，不约束翻译 |
| `AT_STRATEGY` | 不指定 | `lowLatency` / `highFidelity`（需要 macOS 26.4+） |

### `AT_SOURCE_MODE`：源语言怎么定

源语言必须明确给出来（框架不认「自动」），只能自己判；而系统的语言识别器在**短句**上会**自信地判错**：实测 `-m num, --max-count=num Stop reading the file after num matches.` 被判成葡萄牙语（`pt 0.994`，英语只有 `0.005`）。判成的那种语言你又没装包，整条请求就 400 —— 整页翻译时表现为「一片没翻出来」。

| 模式 | 行为 | 适合 |
| --- | --- | --- |
| `english`（默认） | 完全不做检测，一律当 `AT_DEFAULT_SOURCE`（请求里显式指定的除外） | 内容是英文 —— 整页翻译基本都属于这种 |
| `auto` | 检测器说了算，判错就 400 | 真的要区分语种，宁可报错也不静默翻错 |
| `retry` | 先按检测结果试；**没装包**才回退到 `AT_DEFAULT_SOURCE` | 多语种混杂 |

代价要清楚：`english` 模式下正文里混进的非英语段落会**被当英语翻**，常常得到中英夹杂的胡话（HTTP 200，不会报错）；`retry` 更聪明，但英文短句被误判成**已经装包**的语种时同样会静默翻错。多语种内容请用 `retry` 或 `auto`。

三种模式都**不会**覆盖请求里显式给的源语言。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | 状态与当前配置（`source_mode`、`default_target` 等） |
| `GET` | `/v1/models` | OpenAI 的 list 形状，只有一个 `apple-translate` |
| `GET` | `/v1/languages` | 平台支持的语言、已装的语言包；`?source=&target=` 可查某一对的状态 |
| `POST` | `/v1/chat/completions` | 主接口，兼容 OpenAI，支持 `stream: true`（SSE） |
| `POST` | `/v1/translate` | 简化接口：`{"text": "...", "target": "zh-Hans"}`，可指定 `source` |

**除了 `/health`，其它路径都同时接受去掉 `/v1` 的写法**（`/chat/completions`、`/translate`、`/models`、`/languages`）；`/health` 只有这一种写法。

### 目标语言怎么定

优先级从高到低：

1. 顶层非标字段 `target_language` / `target_lang` / `to`（`source_language` / `from` 同理）
2. **最后一条 user 消息**里解析出来的（`Translate the following into Japanese:` → 日语；`把下面这段翻译成中文：` → 中文）
3. system 提示里提到的
4. `AT_DEFAULT_TARGET`

正文取最后一条 user 消息：如果首行是指令，冒号之后才是正文；否则整条当正文。包裹正文的 ` ``` ` 围栏会被剥掉。**只有没有 user 消息时，system 消息才会被当成正文。**

语言名支持别名：20 种语言共 143 种写法（`ja` / `jp` / `Japanese` / `日本語` / `日语` / `日文` 都行）。`GET /v1/languages` 只列 20 个规范 id，别名清单见 `Sources/AppleTranslateServer/LanguageCatalog.swift`。

以上切分**只发生在 `/v1/chat/completions`**；`/v1/translate` 不管指令，原样翻 `text`。另外 `/v1/chat/completions` 也认顶层的 `text` 字段（**优先于** user 消息）。

## 语言包

服务**不能**替你下载语言包（这个模式下 `canRequestDownloads == false`），没装就返回 `400 language_not_installed` 并告诉你中文设置路径。装法：**系统设置 → 通用 → 语言与地区 → 翻译语言**。

查当前状态：

```bash
curl -s "http://127.0.0.1:8787/v1/languages?source=en&target=ja" | jq .pair_status
# installed / supported（认得但没下载）/ unsupported（这对根本不支持）
```

语言名写错时 `pair_status` 会**整个键都不出现**（不是报错）—— 想确认写法对不对，看响应里有没有这个键。

## 性能与限制

- **延迟**：和正文长度近似线性，大约 **0.3~0.7 ms/字**（en→zh-Hans）—— 同样长度、同样机器，文本内容和机器负载不同能差一倍。量级参考：500 字约 0.2 s，2000 字约 0.7 s，5000 字约 1.7~2.5 s，10000 字约 3.4~5 s。几百字以下主要在付一个几十毫秒的固定开销。
- **并发是假的，排队是真的**：`Translation` 框架内部就是串行的，本服务再快也只能一条一条翻。发 8 条和一条条发 8 条耗时几乎一样，发 32 条墙钟线性增长。多开进程绑不同端口**也一样** —— 串行点在系统共享的 `translationd` 里。所以：**别堆并发，网关侧排队或者直接把「每秒请求数」调低**。
- **一次连接一个请求**（`Connection: close`），没有 keep-alive 复用；连上不发完整请求的连接 30 秒会被踢掉（`AT_READ_TIMEOUT`）。
- **只支持 `Content-Length`**：chunked 请求体会明确返回 `411 length_required`，不会静默当成空 body。
- **`usage` 是按字符数估的假 token**（约等于字数 ÷4），别拿它算钱。
- **只翻正文**，不是通用对话模型；system 提示默认只用来提取目标语言。

### 资源占用

| 指标 | 实测 |
| --- | --- |
| 本服务常驻内存 | **~20 MB**，跑几千条请求也不涨 |
| 本服务空载 CPU | **0.0%** |
| 串行吞吐 | 约 **20~40 req/s**（几十字的短句） |
| 启动到能应答 | 毫秒级（启动时会自己预热一次） |

**真正吃资源的不在这个进程里**：翻译运算跑在系统的 `/System/Library/Frameworks/Translation.framework/translationd`，常驻 **~280~360 MB**，翻的时候基本吃满一个核。它是全系统共享的守护进程（Safari、预览、查词也走它），不是本服务拉起来的，也不归本服务管 —— 想省这几百 MB 就只能不用系统的翻译框架。

### 已知问题

- **翻译框架卡死时没有超时保护。** 系统 `translationd` 某次调用若**永不返回**，那一对语言的调用会一直排着队，后面的请求全都卡住不动 —— 而且 `AT_READ_TIMEOUT` 帮不上忙（它只约束收请求，不管在飞的翻译）。遇到了就 `brew services restart apple-translate-api`，或者重启系统的翻译服务。实际撞上的概率很低，暂时没做请求级超时：要做就得先定清楚超时之后是放弃这次调用、返回 504、还是重启 `translationd`。
- **`AT_SOURCE_MODE=english`（默认）下，非英语段落会被当英语翻**，常见结果是中英夹杂的胡话（HTTP 200，不报错）。多语种内容请改用 `retry` 或 `auto`，见 [`AT_SOURCE_MODE`](#at_source_mode源语言怎么定)。

### 安全

- **默认只绑 `127.0.0.1`**，本机之外访问不到。
- **没有任何鉴权。** 一旦把 `AT_HOST` 设成 `0.0.0.0`，同网段任何人都能拿你的机器当翻译机（顺带吃你的 CPU）。真要对外，请自己在前面套一层带认证的反向代理。
- **CORS 回的是 `Access-Control-Allow-Origin: *`** —— 你浏览器里打开的任意网页都能访问它并把内容送进来翻译。本地工具的常见取舍，介意的话在网关层收口。

## 排错

| 现象 | 原因 / 怎么办 |
| --- | --- |
| 启动即退出，日志 `Address already in use` | 端口被占。换 `AT_PORT`，或先 `brew services stop apple-translate-api` |
| `404 not_found` | 路径写错了（比如地址只填了 `http://127.0.0.1:8787`）。正确路径见[接口](#接口) |
| `400 invalid_request` | 请求体不是合法 JSON 或缺少必需字段 |
| `400 empty_input` | 没有可翻的正文（既没有 user 消息也没有 `text`） |
| `400 language_not_installed` | 语言包没装，按报错里的路径去系统设置装 |
| `400 unsupported_target_language` / `unsupported_source_language` | 语言名不认识，对照 `GET /v1/languages` |
| `400 unsupported_language_pair` | 这对语言框架不支持 |
| `400 invalid_content_length` | `Content-Length` 不是非负整数，或出现了两次 |
| `411 length_required` | 用了 chunked 传输，改用 `Content-Length` |
| `413 input_too_long` / `body_too_large` | 正文超 `AT_MAX_CHARS` / `AT_MAX_BODY` |
| `431 headers_too_large` | 请求头超 `AT_MAX_HEADERS` |
| `502 translation_failed` | 系统翻译框架报错，日志里有原始错误 |
| `500 internal_error` | 兜底。日志（`$(brew --prefix)/var/log/apple-translate-api.log`）里有详情 |
| 翻译结果不对 / 整段没翻 | 多半是源语言判错，用 `--detect -` 看检测结果，再决定 `AT_SOURCE_MODE` |

## 问题与反馈

<https://github.com/BreakFree003/apple-translate-api/issues>

## 许可

MIT，见 [LICENSE](LICENSE)。
