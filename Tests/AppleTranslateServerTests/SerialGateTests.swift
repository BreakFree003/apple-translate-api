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

    private struct Boom: Error {}

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

    @Test("被保护的活儿抛错，门也得还回来（否则这个语言对从此卡死）")
    func releasesOnThrow() async throws {
        let gate = SerialGate()

        func work() async throws {
            await gate.acquire()
            do {
                throw Boom()
            } catch {
                await gate.release()
                throw error
            }
        }

        for _ in 0..<3 {
            await #expect(throws: Boom.self) { try await work() }
        }

        // 前面漏还过一次，这里就永远拿不到门。用超时兜底，免得测试挂死而不是失败。
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
        #expect(acquired, "门没还回来")
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
