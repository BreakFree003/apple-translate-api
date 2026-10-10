# 开发与发布

给要改这个仓库的人看的。使用者请读 [README](../README.md)。

## 跑测试

```bash
./scripts/test.sh    # 40 个单测：HTTP 解析、串行闸门、prompt 切分、语言目录、配置解析（不碰翻译框架）
./scripts/e2e.sh     # 端到端验收：起两个真服务、发真请求、翻真文本，25 项断言（需要语言包）
```

**为什么单测要过一层 `scripts/test.sh`**，而不是裸 `swift test`：只装 CommandLineTools 的机器上，裸 `swift test` 的增量构建有时会在显式 module 的插件列表里漏掉 `TestingMacros`，报

```
error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
       could not be found for macro 'Test'; plugin for module 'TestingMacros' not found
```

实测裸跑是 PASS/FAIL 交替（连跑 4 次挂 2 次），显式给出 `-plugin-path` 之后 4/4 通过。脚本就是替你加这个参数（也兼容装了完整 Xcode 的机器）。**这个报错跟本项目代码无关。**

`e2e.sh` 起两个实例：默认配置的 8791，和显式 `AT_SOURCE_MODE=auto` 的 8792 —— 后者专测源语言检测那两条断言（默认是 `english`，不检测）。依赖语言包的断言会**跟着系统实际状态走**：装了 `ja` 就要求翻出假名，没装就要求返回明确点名 `ja` 的 `400 language_not_installed`；两条路都不许静默翻错，也不会因为某台机器删了包而假绿。

想验收别处装的二进制（比如 brew 那份）：

```bash
AT_BIN=/opt/homebrew/bin/apple-translate-server ./scripts/e2e.sh
```

## CI

`.github/workflows/ci.yml`，`runs-on: macos-26`，只跑构建 + 单测 + CLI 自检（起服务打 `/health`）。**e2e 不进 CI** —— 它要求本机装好语言包，runner 上没有。

## 发布

版本号只有一处：`Sources/AppleTranslateServer/Version.swift`。改完提交，然后

```bash
./scripts/release.sh 0.1.0          # 干跑：查版本号 / 工作树 / tag 冲突，跑构建和单测
./scripts/release.sh 0.1.0 --go     # 打 tag → push → 抓 GitHub tarball 算 sha256 → 写进 formula
```

`--go` 之后还有一步：把改好的 `Formula/apple-translate-api.rb` 提交进主仓库（脚本替你改 url/sha256，但不替你 commit）。

那个 `sha256` 只有 tag 推上去之后才算得出来，所以它交给脚本，别手抄 —— 抄错了 brew 只会回一句 `SHA256 mismatch`。

## 单独验一遍 formula（不用先推 GitHub）

Homebrew 7 要求公式待在某个 tap 里，所以本地验证是这样：

```bash
brew tap-new local/apple-translate-api --no-git
cp Formula/apple-translate-api.rb \
   "$(brew --repository)/Library/Taps/local/homebrew-apple-translate-api/Formula/"
# 把 url/sha256 换成指向本地 tarball 的 file:// 与它的真哈希，然后
brew install --build-from-source local/apple-translate-api/apple-translate-api
brew test local/apple-translate-api/apple-translate-api
```

`brew test` 会在一个空闲端口上起临时服务、打 `/health`、再关掉，不需要语言包。

## 一些踩过的坑（别再踩）

- **Formula 里 `Formula#system` 不接受 `out:` / `err:` 关键字参数**（sorbet 会报 TypeError）。要收输出就用单字符串走 shell。
- **`ENV["SWIFTPM_MODULECACHE_OVERRIDE"]` 必须设**：SwiftPM 默认把 module cache 写到 `~/Library/Caches/org.swift.swiftpm`，brew 的构建 sandbox 不放行那里。`--disable-sandbox` 只关 SwiftPM 自己那层，关不掉 brew 外层那个。
- **别在 plist 上做手脚**：brew services 的 plist 由公式的 `service` 块生成，改了会在下次 `brew services restart` 时被覆盖。要改参数就写 `~/.homebrew/services/apple-translate-api.env`。
- **shell 里 `$VAR` 后面紧跟全角标点要写成 `${VAR}`**：bash 会把标点字节吃进变量名，报 `VAR�: unbound variable`。本项目在 `scripts/e2e.sh` 和 `scripts/test.sh` 里都为这个留了注释。
