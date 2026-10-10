import Testing

@testable import AppleTranslateServer

/// `SerialGate` 是「同一个 session 不被并发调用」这条保证的唯一实现，而这条保证在本项目里
/// 已经被误以为「包个 actor 就有了」两轮。所以它值得一个**能证伪**的测试：
/// 谁要是把这个闸门换回裸 actor，下面的 `maxInFlight` 立刻不再是 1。
@Suite("串行闸门")
struct SerialGateTests {
    /// 记录同时有几个任务在门里 —— 共享计数只能从 actor 里改。
    private actor Probe {
        private var inFlight = 0
        private var peak = 0

        var maxInFlight: Int { peak }

        func enter() {
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func exit() { inFlight -= 1 }
    }

    private actor Reached {
        private var entered = false
        var didEnter: Bool { entered }
        func mark() { entered = true }
    }

    @Test("8 个任务抢同一把门，同一时刻最多只有一个进得去")
    func serializesConcurrentWork() async {
        let gate = SerialGate()
        let probe = Probe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await probe.exit()
                    await gate.release()
                }
            }
        }

        let peak = await probe.maxInFlight
        #expect(peak == 1, "同一时刻进门的任务数是 \(peak)，说明根本没串行")
    }

    /// 一定抛错的替身：模拟框架 session 在翻译途中失败。
    private struct FailingSession: SessionTranslating {
        struct Boom: Error {}
        var isReady: Bool { get async { true } }
        func translate(_ text: String) async throws -> RawTranslation { throw Boom() }
    }

    @Test("SessionBox.translate 抛错后仍然还门（否则这个语言对从此卡死）")
    func releasesGateWhenSessionThrows() async {
        let box = SessionBox(session: FailingSession())

        await #expect(throws: FailingSession.Boom.self) { try await box.translate("hello") }

        // 门真还回来了，第二次调用才会再次走到 session 并再次抛错（标记 Reached）。
        // 这里轮询而不是用 withTaskGroup 抢跑：门要是漏了，那个调用会**永远**挂在
        // acquire 上，任务组退出时会等它，测试就变成挂死而不是失败。
        let reached = Reached()
        let attempt = Task {
            do { _ = try await box.translate("hello") } catch { await reached.mark() }
        }
        var enteredAgain = await reached.didEnter
        for _ in 0..<40 {
            if enteredAgain { break }
            try? await Task.sleep(for: .milliseconds(50))
            enteredAgain = await reached.didEnter
        }
        attempt.cancel()

        #expect(enteredAgain, "第二次调用没走到 session —— catch 里没把门还回来")
    }

    @Test("顺序还门不会漏：100 轮 acquire/release 之后照样拿得到")
    func doesNotLeakAfterManyRounds() async {
        let gate = SerialGate()
        for _ in 0..<100 {
            await gate.acquire()
            await gate.release()
        }

        let acquired = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await gate.acquire()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(acquired, "100 轮之后门空不出来")
    }
}
