# 同类项目调研（prior art）

> 调研时间：2026-10-10。方法：GitHub Search API + `web_search`，对关键仓库 `git clone --depth 1` 读源码、其余读 raw README。
> 星数/日期均为抓取当日快照。

## 诚实度声明

本文每条结论都标了来源可信度，三种标记：

- ✅ **读源码确认** —— clone 下来逐个文件看过
- 📖 **读 README 确认** —— 打开过仓库主页/README，但没读源码
- 🔍 **仅搜索结果推断** —— 只看到标题和描述

星数会变、仓库会改，**引用具体结论时请回去看原文**。

---

## 一句话结论

**这件事不是处女地，但我们的具体组合是空位。**

至少 5 个项目在做「Apple 端上翻译 → 本地 HTTP 服务」，其中 [TranslateML](https://github.com/rock74710/TranslateML) 已经提供 OpenAI 兼容端点。没人做的是 **「OpenAI 方言 + 每次请求任意 source/target + 无 Xcode 的 SwiftPM CLI」** 这个组合 —— 但概念上绝不新颖。

整条 macOS 赛道**是最近三个月才开的**（Tahoe 开放 `Translation.framework` 的公开无头 API）。

---

## 1. 全景：Apple 端上翻译怎么被调用的

| 仓库 | ★ | 语言 | 更新 | 怎么拿到翻译 | 对外暴露 | 验证 |
|---|---|---|---|---|---|---|
| [rock74710/TranslateML](https://github.com/rock74710/TranslateML) | 10 | Swift | 2026-08-05 | `installedSource:target:` | HTTP :8990，MTranServer 兼容 + `/imme` + **`/v1/chat/completions`** | ✅ |
| [CKylinMC/AppleMT2DLXAPI](https://github.com/CKylinMC/AppleMT2DLXAPI) | 0 | Swift | 2026-09-23 | 纯无头 `installedSource` | HTTP :10825，DeepLX + DeepL v2 | ✅ |
| [ziozzang/beonyeok](https://github.com/ziozzang/beonyeok) | 0 | Swift | 2026-09-30 | `installedSource`（下载用 `translationTask`） | HTTP :8989，DeepL 兼容 | ✅ |
| [malusama/apple-translation-bridge](https://github.com/malusama/apple-translation-bridge) | 2 | Swift+Python | 2026-10-07 | `installedSource`（下载用 `translationTask`） | HTTP :3210，沉浸式翻译自定义协议 | ✅ |
| [Bowl42/pippin-mcp](https://github.com/Bowl42/pippin-mcp) | 4 | Swift | 2026-05-20 | `installedSource` | **MCP**（stdio + HTTP :1996） | ✅ |
| [Arthur-Ficial/translate](https://github.com/Arthur-Ficial/translate) | 28 | Swift | 2026-10-07 | `installedSource` + `.lowLatency` | HTTP :8989，DeepL v2 / LibreTranslate / Google v2 | ✅ |
| [xulihang/macTranslator-Server](https://github.com/xulihang/macTranslator-Server) | 0 | Swift | 2025-11-27 | **`translationTask` + 可见窗口** | 本地 REST | ✅ |
| [cosZone/MoePeek](https://github.com/cosZone/MoePeek) | 847 | Swift | 2026-10-03 | `translationTask` + 隐形 1×1 窗口 | GUI App | ✅ |
| [tisfeng/Easydict](https://github.com/tisfeng/Easydict) | 14888 | Swift | 2026-10-06 | `translationTask` + 窗口 | GUI + Vapor HTTP（`/translate` `/detect`） | ✅ |
| [yelog/SnapTraTranslator](https://github.com/yelog/SnapTraTranslator) | 148 | Swift | 2026-09-18 | `translationTask` + NSHostingView | GUI App | ✅ |
| [scriptingosx/translate-cli](https://github.com/scriptingosx/translate-cli) | 15 | Swift | 2026-01-09 | `installedSource` | CLI | ✅ |
| [hotchpotch/trn](https://github.com/hotchpotch/trn) | 10 | Swift | 2026-09-17 | `installedSource` + `--quality` | CLI（Homebrew） | ✅ |
| [0xWDG/xcstrings-translator](https://github.com/0xWDG/xcstrings-translator) | 28 | Swift | 2026-10-09 | 每目标语言一个 session | GUI | 📖 |

**明确排除**（名字像，但用的是 Apple **Foundation Models** 的端上 LLM，不是 Translation 框架）：
[FradSer/FoundationModelsTranslator](https://github.com/FradSer/FoundationModelsTranslator) (8★)、
[dipeshdhakal/SwiftTranslate](https://github.com/dipeshdhakal/SwiftTranslate) (7★)、
[betty2310/afm-translator](https://github.com/betty2310/afm-translator) (0★)、
[johnhenry/apple-foundation-models](https://github.com/johnhenry/apple-foundation-models) (3★)。

---

## 2. 最接近的三个，逐个对照

### 2.1 [TranslateML](https://github.com/rock74710/TranslateML) —— 几乎同一个东西 ✅

台湾项目，2026-07-31 创建（比我们早两个多月）。读完 `Package.swift` 和 `Sources/TranslateCore/TranslationEngine.swift` 确认：

- `swift-tools-version 6.2`，`platforms: [.macOS(.v26)]` —— **和我们一样只要求 macOS 26.0**，不用 26.4
- `actor AppleTranslationEngine`，`@preconcurrency import Translation`，`sessions: [LanguagePair: TranslationSession]`，`TranslationSession(installedSource:target:)`
- 用 **FIFO async gate** 防止 actor 在 `await` 处重入 —— 这一点我们该学（见 §3）
- HTTP 同样是 Network.framework + `requiredLocalEndpoint = 127.0.0.1`
- 它的 `FINDINGS.md` 有实测输出：`session-created canRequestDownloads=false`，并写明「這證明 headless API 可行，也證明 headless session 不能觸發下載」

**为什么它要做这个**（README 原文）：

> 在本機跑 LLM 來翻譯，速度快不到哪裡去… 改用 MTranServer，但品質實在太差。後來才查出它底層是 Mozilla 的 Bergamot 引擎 —— en→zh 落後 Google Translate 約 12–15 分（flores：38.8 vs 50.7）。

**和我们的差别**：

| | TranslateML | 我们 |
|---|---|---|
| 原生方言 | MTranServer 兼容 | OpenAI |
| OpenAI 端点目标语言 | **写死 zh-TW** | 请求体里任意指定 |
| 交付形态 | 菜单栏 App + DMG（`server` 可执行文件也算 CLI） | 纯 SwiftPM CLI，前台运行、不注册任何开机自启 |
| 端点 | 多一个 `/version` `/__heartbeat__` `/__lbheartbeat__` | 少这几个 |

### 2.2 [CKylinMC/AppleMT2DLXAPI](https://github.com/CKylinMC/AppleMT2DLXAPI) —— 最纯粹的「无头 + HTTP」✅

`Sources/AppleMTDeepLX/Translation/TranslationSessionPool.swift:161,164` = `TranslationSession(installedSource: source, target: target)`。
**全仓库没有 `translationTask`、没有 `NSHostingView`** —— 和我们一样是纯无头。端口 10825，兼容 DeepLX 的 `free`/`v1` 和 DeepL 官方 `v2`。
`Sources/.../SourceLanguageDetector.swift:14` 用 `NLLanguageRecognizer.dominantLanguage(for:)`，和我们同一条路。

### 2.3 [ziozzang/beonyeok](https://github.com/ziozzang/beonyeok) ✅

`Sources/App/Engine.swift` 用 `installedSource`；`Sources/App/App.swift` **额外用 `translationTask` 专门做语言包下载**。
README 里有一条别处没写的实测：**"Apple processes one sentence at a time system-wide (~0.5 s/sentence)"** —— 系统级串行。所以它加了 SQLite + LRU 缓存和连接并发。这条值得我们的架构参考。

---

## 3. 协议生态：主流**不是** OpenAI

真把翻译引擎塞进 `/v1/chat/completions` 的只有 4–5 个（TranslateML、[ctranslate2-server](https://github.com/franchb/ctranslate2-server)、[PopTrans](https://github.com/ifocus9/PopTrans)、[ruster](https://github.com/hohofught/ruster)，以及反向的 openai2deeplx）。主流是**翻译专用 REST**：

| 项目 | ★ | 接口 |
|---|---|---|
| [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate) | 17k | `POST /translate {q,source,target}` → `{translatedText,detectedLanguage}` |
| [DLX（原 DeepLX）](https://github.com/OwO-Network/DLX) | 8.7k | `POST /translate {text,source_lang,target_lang}` — **Bob / 沉浸式生态事实上的本地标准** |
| [MTranServer](https://github.com/xxnuo/MTranServer) | 4.7k | 自定义核心 + **一家做了 7 个兼容壳**：`/imme` `/kiss` `/deepl` `/deeplx` `/hcfy` `/google/language/translate/v2` `/google/translate_a/single` |
| Arthur-Ficial/translate | 28 | DeepL v2 + LibreTranslate + Google v2（**明确不做 OpenAI**） |

**没有任何项目只做一个协议。** 我们选 OpenAI 兼容不错（对 LLM 客户端最直接，且带 SSE 流式的同类里没见到第二个），但覆盖面窄 —— 加一条 LibreTranslate/DLX 形态的 `POST /translate` 就能一次接上 Bob 的 DeepLX 插件、沉浸式翻译自定义接口和 MTranServer 系客户端。**这是目前投入产出比最高的一个待办。**

---

## 4. 我们的位置

按不同判据看谁做到过：

| 特征 | 谁做到了 | 差在哪 |
|---|---|---|
| macOS 26 `installedSource` + 本地 HTTP | TranslateML、AppleMT2DLXAPI、beonyeok、bridge、pippin-mcp | 已完全做到 |
| 无头 HTTP + **OpenAI 兼容** | TranslateML | 目标语言写死 zh-TW；非纯 CLI |
| 纯 CLI + HTTP + **不用 Xcode** | Arthur-Ficial/translate | 方言是 DeepL/LibreTranslate/Google，**没有 OpenAI** |
| 无头 + HTTP，DeepL 方言 | AppleMT2DLXAPI、beonyeok | 没有 OpenAI 方言 |

**没有找到「OpenAI 方言 + 任意 source/target + 无 Xcode 的 SwiftPM CLI + 8787」这个组合**，但每一块单独都有人做过。

---

## 5. 可以直接复用的库（别自己重写）

- **[fmcgoohan/AppleTranslationKit](https://github.com/fmcgoohan/AppleTranslationKit)**（0★，MIT，macOS 26+，零依赖）—— 最佳候选 📖
  ```swift
  .package(url: "https://github.com/fmcgoohan/AppleTranslationKit.git", from: "0.1.0")
  ```
  `@MainActor AppleTranslationCoordinator.translate(_:targetLanguageCode:)`；内含 NaturalLanguage 检测、长文本分块、活动状态机（idle/preparing/translating/failed）+ 一次自动重试；用的正是 `init(installedSource:target:)` 和 `cancel()`。
- **[doom-fish/translation-rs](https://github.com/doom-fish/translation-rs)**（0★，Rust，crate `translation-rs` v0.5）—— 覆盖 macOS 26.5 SDK 全部公开 `Translation.framework` 符号，含 async API、LanguagePair 规范化 📖
- **不适合复用**：`Mx-Iris/SystemTranslation`（自己 README 已说 macOS 26+ 别用）；`wolfej94/TranslationKit`（要求 window scene + root view controller，README 明写 "Not Compatible with Background Tasks"，CLI 用不了）

---

## 6. 踩过的坑（带出处）

1. **语言包必须预先安装** —— 几乎人人写：`scriptingosx/translate-cli`（否则 `Error: Unable to Translate`）、`trn`、`0xWDG/Translate`、`Arthur-Ficial/translate`（有 `docs/install-translation-models.md`）、`beonyeok`、`pippin-mcp`、`atrans`
2. **无头 session 无法触发语言包下载** —— TranslateML `FINDINGS.md` 实测 `canRequestDownloads=false`。`malusama/apple-translation-bridge` 和 `beonyeok` 的应对是**额外塞一个 SwiftUI `translationTask` + NSHostingView 小窗口**专做交互式下载。
   引申：`malusama` 的 `Sources/LanguageSetup.swift` 用的就是 `TranslationSession.Configuration` + `prepareTranslation()` + 轮询 `await session.isReady`（**不是**信 `LanguageAvailability.status()`）—— 和我们踩到的冷启动不可信完全一致。**对我们这种无 Xcode 的纯 CLI，这条路提供不了。**
3. **Swift 6 Sendable**：Translation 的引用类型不是 Sendable → `@preconcurrency import Translation`（TranslateML）或 `TranslationSession+Sendable.swift`（CKylinMC）。我们在用前者。
4. **吞吐是系统级串行**：beonyeok README "Apple processes one sentence at a time system-wide (~0.5 s/sentence)" → 它们加逐行缓存 + 连接并发。
5. **网络两个坑**：
   - NWListener 的 `port` 和 `requiredLocalEndpoint` **同时设同一个端口** → `Network.NWError error 22 - Invalid argument`（TranslateML）。
     **我们没踩到**：`Sources/AppleTranslateServer/HTTPServer.swift:38` 用的是 `NWListener(using: parameters)`，端口只经 `requiredLocalEndpoint`（:33-35）设置一次。
   - 只监听 IPv4 而浏览器把 `localhost` 解析成 `::1` → **客户端配置写 `127.0.0.1`**（TranslateML README 明确警告）。我们实测 `curl localhost` 能通（macOS 同时解析出 `::1` 和 `127.0.0.1`，回落到 IPv4），但只试 `::1` 不回收的客户端会失败。
6. **构建**：macOS 27 独立 CLT 不会自动加载 TestingMacros、rpath 不全 → 测试 target 需要显式 `-load-plugin-library … libTestingMacros.dylib` + `-Xlinker -rpath`（TranslateML）。Arthur-Ficial 则明确「No Xcode required, build with Command Line Tools」。
7. **短文本/歧义语言识别**是普遍问题，各家缓解手段不同：
   - Arthur-Ficial：`--langs a,b,c` 检测提示
   - `annamade-design/lala-translate`：拉丁字母一律当英文（保短词准确）
   - TranslateML：`source_lang:"auto"` 用假名 + 简繁特征 + 汉字启发式
   - **我们**：置信度 ≥ 0.75 直接采信，否则偏向 `AT_DEFAULT_SOURCE`；另有 `AT_SOURCE_MODE=english|retry` 兜底
8. **同语言/变体互译永远是 `unsupported`**（Apple 文档）。`trn` 区分「`supported` 但资源没下载」vs「`unsupported`」—— 和我们 `/v1/languages` 的 `pair_status` 一致。
9. **关于「`installedSource` 不接受 auto」**：**没找到任何仓库把这条写成文字**。它是结构性事实（`installedSource:` 是非可选 `Locale.Language`），所有项目都是先用 `NLLanguageRecognizer` 再传显式语言 —— 证据来自代码，不是踩坑记录。

---

## 7. 客户端接入要点

- **沉浸式翻译** ✅
  - 「OpenAI 兼容」模式：API 地址必须填**完整路径** `http://127.0.0.1:8787/v1/chat/completions` —— **它不会自动拼路径，这是 404 第一大原因**
  - 「自定义接口」模式：`POST {source_lang, target_lang, text_list[]}` → `{translations:[{detected_source_lang, text}]}`
  - Prompt 变量 `{{text}} {{from}} {{to}} {{yaml}} {{html_only}}`，默认高级格式是 YAML
- **Bob** ✅ —— **不是 HTTP 客户端，是 JS 插件宿主**。直接用不了我们的服务，得装 [`bob-plugin-openai-translator`](https://github.com/nextai-translator/bob-plugin-openai-translator)（★5652）选 "OpenAI Compatible"。Bob 连本地翻译的既有标准是 DeepLX `/translate`。
- **Chatbox** ✅ —— 标准 OpenAI，base URL 填到 `/v1` 即可。
- **陪读蛙 Read Frog** ✅ —— 选「自訂 Chat Completions」，URL `http://127.0.0.1:PORT/v1`，key 任意非空，model 名任意。**别选「自訂 Responses」**（它探 `/models` 的方式不同 → 404）。
- **通用**：客户端「测试连接」会拉 `/v1/models`（我们有 ✅）。要容忍空 key 和任意非空字符串（如 `Bearer local`）。

---

## 8. 可抄的设计（按对我们的价值排序）

1. **占位符 / HTML 保护** —— `apple-translation-bridge` 用 `AttributedString.skipsTranslation = true` 标记 `{0}`、HTML 标签、URL，整段翻完再校验数量。TranslateML 用 `⟦ATS0⟧` 标记。**我们现在完全没有，翻网页会把标签搞坏。**
2. **批次 + 保序** —— 用 `TranslationSession.Request(sourceText:clientIdentifier:)` + `translations(from:)`，靠 `clientIdentifier` 保序，一次 1–128 段。我们是一段一请求。
3. **段落哨兵 `%%`**（独占一行；句中 `%%` 当字面量），输出按序以 `%%` 重拼，保证段数一致。
4. **目标语言别只靠提示词** —— TranslateML 的论证：正文里的语言名会被当指令、客户端措辞千变万化，所以它在 OpenAI 端点**硬编码**目标语言。openai2deeplx 用 **model 名后缀** `gpt-4-zh` → ZH。我们靠提示词解析，确实脆。
5. **假 SSE**（非增量引擎）：chunk1 = 全文 + `finish_reason`，chunk2 = `stop`，然后 `data: [DONE]`。我们是按 40 字符切块真推，体验比它好。
6. **参数宽容**：`temperature`/`top_p`/`max_tokens` 收了忽略别报错；`content` 接受字符串或 `[{"type":"text","text":...}]`；`model` 原样回显；`usage` 可填 0 占位。我们已满足（Decodable 忽略未知键）。
7. **语言代码归一化**：`en / en-US / en-GB → en`；`ja / ja-JP / jp → ja`；`zh-Hans / zh-CN / zh-SG → zh-Hans`。我们的 `LanguageCatalog` 已覆盖这些别名。
8. **缺语言对必须显式报错，别回显原文** —— TranslateML 和 Arthur-Ficial（退出码 4）都这么做。**我们已经是显式 400。** ✅
9. **常用端点**：`/health` `/version` `/`（清单）`/v1/models` `/languages`。可加 Mozilla 风格 `/__heartbeat__` `/__lbheartbeat__`。**我们缺 `/version` 和 `GET /`（都是 404）。**

---

## 9. 平台结论

- **Windows 完全没人做**这件事 —— 因为 Windows 没有公开的离线翻译 API（翻译全走 Azure 在线；`Windows.Globalization` 只给语言标签）。搜到的都是 `Windows.Media.Ocr` 的组合。
- **Linux 也没有系统翻译 API**，那块由 LibreTranslate / Argos / MTranServer(Bergamot) / LTEngine 填。
- **macOS 这条赛道是最近三个月才开的**（Tahoe 开放 `Translation.framework` 无头 API）。TranslateML(2026-07-31)、beonyeok(2026-09)、AppleMT2DLXAPI(2026-09)、apple-translation-bridge(2026-10-07)、我们(2026-10-09) 都是这一波。

---

## 10. 我们实测过、但别人没写的

- **`lowLatency` 对 en→zh-Hans 是个 no-op**。`TranslationSession.Strategy`（macOS 26.4+）三档实测：不指定 23ms / `lowLatency` 23ms / `highFidelity` 33ms（短句），2415 字符长文本 1253 / 1152 / 1133ms，**输出逐字相同**。`trn` 那个「low 快约 10 倍」是 en→ja 的结论，中英不吃这套。
- **24 小时真实负载**：2683 次请求，服务常驻 21→29 MB、空载 0% CPU、每条 ~6ms CPU；`translationd` 421 MB + ~26ms/条（系统共享，不是我们拉起来的）。

---

## 11. 待办（用户 2026-10-10 明确决定：先不做，只归档）

- [ ] 加 `POST /translate`（LibreTranslate / DLX 形态）—— 一次接上 Bob 的 DeepLX 插件、沉浸式翻译自定义接口、MTranServer 系客户端。**投入产出比最高。**
- [ ] 占位符 / HTML 保护（`AttributedString.skipsTranslation`）
- [ ] `/version` + `GET /`（目前 404）
- [ ] 批次接口（`translations(from:)` + `clientIdentifier` 保序）
- [ ] 考虑 model 名后缀指定目标语言（`apple-translate-ja`）
