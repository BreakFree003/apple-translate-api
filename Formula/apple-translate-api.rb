# Homebrew 公式。
#
# 放在主仓库里当唯一事实源；要能用 `brew tap <user>/apple-translate-api` 装，
# 需要有另一个名为 homebrew-apple-translate-api 的仓库，把这个文件放到它的 Formula/ 下。
# （只有主仓库也能装：brew tap <user>/apple-translate-api https://github.com/<user>/apple-translate-api）
#
# 本地验证（不用先推 GitHub，Homebrew 7 要求公式待在某个 tap 里）：
#   brew tap-new local/apple-translate-api --no-git
#   cp Formula/apple-translate-api.rb "$(brew --repository)/Library/Taps/local/homebrew-apple-translate-api/Formula/"
#   # 把 url/sha256 换成指向本地 tarball 的 file:// 与它的真哈希，然后：
#   brew install --build-from-source local/apple-translate-api/apple-translate-api
#   brew test local/apple-translate-api/apple-translate-api
# 发布前只剩 sha256 要换（url 已经是最终形态）：跑 scripts/release.sh --go 会自动写进去。
class AppleTranslateApi < Formula
  desc "Apple on-device translation exposed as an OpenAI-compatible HTTP API"
  homepage "https://github.com/BreakFree003/apple-translate-api"
  # 打 tag 之后替换成：
  #   url "https://github.com/BreakFree003/apple-translate-api/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "<shasum -a 256 那个 tarball 的结果>"
  url "https://github.com/BreakFree003/apple-translate-api/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "34ef6a5ea570f8b466db3704edfc202e52edb5f66c8792d34a18610405a61d73"
  license "MIT"
  head "https://github.com/BreakFree003/apple-translate-api.git", branch: "main"

  # TranslationSession(installedSource:target:) 是 macOS 26 才有的 API。
  # 裸符号 = 「该版本或更高」（tahoe = 26，golden_gate = 27）；
  # 旧的 ">= :tahoe" 字符串形式已经被 Homebrew 拒绝了。
  depends_on macos: :tahoe

  # 启动前需要本机装好语言对（系统设置里手动装），这里不做检查 —— 服务起得来就说明环境对。

  def install
    # SwiftPM 默认把 module cache 写进 ~/Library/Caches/org.swift.swiftpm，
    # 而 brew 的构建 sandbox 不放行那里 —— 指到 buildpath 里绕开（--disable-sandbox
    # 只关 SwiftPM 自己的 sandbox，关不掉 brew 外面那层）。
    ENV["SWIFTPM_MODULECACHE_OVERRIDE"] = buildpath/".swiftpm-cache"

    # Homebrew 有现成的 Swift 构建参数（release + jobs）。macOS 的 std_swift_args 里已经
    # 含 --disable-sandbox（extend/os/mac/formula.rb），后面那个是显式再写一遍 —— 冗余，
    # 但能让「为什么能在这个 sandbox 里构建」一眼看懂，留着。
    system "swift", "build", *std_swift_args, "--disable-sandbox"

    # .build/release 是指向 out/Products/Release 的符号链接，两种写法都能取到。
    bin.install ".build/release/apple-translate-server"
  end

  # brew services 会照这个块生成 LaunchAgent plist，别手改 plist。
  # 不设 keep_alive 起不来自动重启；keep_alive true 同时会带上 RunAtLoad（登录即起）。
  service do
    run [opt_bin/"apple-translate-server"]
    keep_alive true
    log_path var/"log/apple-translate-api.log"
    error_log_path var/"log/apple-translate-api.log"
    # 只监听回环、默认端口 8787；要改就在
    #   ~/.homebrew/services/apple-translate-api.env
    # 里写 KEY=value（brew services 读这个文件，优先级高于这里）。
    environment_variables AT_HOST: "127.0.0.1", AT_PORT: "8787", AT_LOG: "1"
    working_dir var
  end

  test do
    # 不需要语言包也不碰翻译框架的自检。
    assert_match "apple-translate-server", shell_output("#{bin}/apple-translate-server --version")
    assert_match "AT_HOST", shell_output("#{bin}/apple-translate-server --help")

    # 真起一个服务打 /health（换个空闲端口，免得撞上用户正在跑的那个）。
    port = free_port
    pid = fork do
      exec({ "AT_PORT" => port.to_s, "AT_LOG" => "0" }, (bin/"apple-translate-server").to_s)
    end
    begin
      60.times do
        # 写成单字符串（走 shell）是有意的：Formula#system 不收 out:/err: 关键字。
        break if system("curl -fsS -m 2 http://127.0.0.1:#{port}/health >/dev/null 2>&1")

        sleep 0.5
      end
      health = shell_output("curl -fsS -m 5 http://127.0.0.1:#{port}/health")
      assert_match(%r{"status"\s*:\s*"ok"}, health)
    ensure
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
