import Foundation

@main
struct App {
    static func main() {
        let config = Config.fromEnvironment()

        // 调试开关：解释一句话会被判成什么语言，不启服务。
        // 传 "-" 则从 stdin 逐行读、逐行输出判定结果（批量跑语料用）。
        if let index = CommandLine.arguments.firstIndex(of: "--detect") {
            let rest = CommandLine.arguments.dropFirst(index + 1)
            if rest.first == "-" {
                while let line = readLine() {
                    print(LanguageDetector.detect(line, fallbackSource: config.defaultSource) ?? config.defaultSource)
                }
                exit(0)
            }
            let text = rest.joined(separator: " ")
            for candidate in LanguageDetector.diagnose(text) {
                print(String(format: "  %-10@ %.3f", candidate.language as NSString, candidate.score))
            }
            let decided = LanguageDetector.detect(text, fallbackSource: config.defaultSource)
            print("→ \(decided ?? "判不出来，用默认源语言 \(config.defaultSource)")")
            exit(0)
        }

        Log.enabled = config.logRequests

        let engine = TranslationEngine(config: config)
        let router = Router(config: config, engine: engine)
        let server = HTTPServer(config: config) { request, writer in
            await router.handle(request, writer)
        }

        // 客户端半路断开时别让进程被 SIGPIPE 打死。
        signal(SIGPIPE, SIG_IGN)
        installSignalHandlers()

        do {
            try server.start()
        } catch {
            Log.error("could not start server: \(error)")
            Log.error("port \(config.port) may already be in use — set AT_PORT to pick another one.")
            exit(1)
        }

        Log.info("model=\(config.modelName) default \(config.defaultSource)->\(config.defaultTarget) "
                 + "max_chars=\(config.maxCharacters)")

        // 首次调用有冷启动开销，先在后台付掉。
        Task {
            await engine.warmUp()
            Log.info("warm-up done")
        }

        dispatchMain()
    }

    private static func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Log.info("shutting down")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}
