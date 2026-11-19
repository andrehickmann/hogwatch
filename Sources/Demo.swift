import Foundation

/// Made-up data for screenshots (`hogwatch --demo`): no real process names, paths or projects.
/// The story: a playwright Chromium left behind for 15 days, test runs on top, a busy Postgres container.
enum Demo {
    private static let gb = 1_073_741_824.0
    private static let mb = 1_048_576.0

    private static func proc(_ pid: Int32, _ title: String, _ tool: String? = nil, _ cwd: String? = nil,
                             cpu: Double = 0, mem: Double = 0, io: Double? = nil, gpu: Double? = nil,
                             age: TimeInterval = 3600, avg: Double? = nil) -> Proc {
        Proc(pid: pid, title: title, tool: tool, cwd: cwd, cpu: cpu, mem: mem * gb, io: io.map { $0 * mb },
             gpu: gpu, age: age, avgCPU: avg, ignoreKey: title)
    }

    static func snapshot(t: Date) -> Snapshot {
        let w = sin(t.timeIntervalSince1970 / 7)
        var s = Snapshot()
        s.date = t
        s.cores = 10
        s.load = [47 + w * 3, 41, 33]
        s.memApp = 14.2 * gb
        s.memWired = 5.1 * gb
        s.memCompressed = 9.4 * gb
        s.memTotal = 32 * gb
        s.pressure = 2
        s.swapUsed = 6.3 * gb
        s.readBps = (180 + w * 20) * mb
        s.writeBps = 95 * mb
        s.iops = 3400
        s.gpuUtil = 18
        s.power = Power(cpu: 11.4, gpu: 1.8, ane: 0, dram: 1.6)
        s.eMHz = 1840
        s.pMHz = 3110
        s.gpuMHz = 720
        s.temps = Temps(soc: 78, gpu: 71, ssd: 52, dev: [62, 70, 72, 41, 44, 66, 75, 76], cells: [36, 37, 39, 38, 36, 37])

        let shop = "~/Projects/shop/web"
        let orphan = proc(41_001, "Chromium (headless)", "playwright", shop + "/.worktrees/e2e", cpu: 131, mem: 0.9, age: 15 * 86400, avg: 128)
        s.orphans = [orphan]
        s.topCPU = [orphan,
                    proc(41_002, "node", "vitest", shop, cpu: 96, mem: 1.8),
                    proc(41_003, "node", "vue-tsc", shop, cpu: 88, mem: 1.1),
                    proc(41_004, "fseventsd", cpu: 52, mem: 0.6),
                    proc(41_005, "mds_stores", cpu: 31),
                    proc(41_006, "WindowServer", cpu: 24)]
        s.topMem = [proc(41_010, "Virtuelle Maschine", "für Docker", mem: 8.1),
                    proc(41_011, "Google Chrome Helper (Renderer)", mem: 2.3),
                    proc(41_002, "node", "vitest", shop, mem: 1.8),
                    proc(41_012, "Xcode", mem: 1.4),
                    proc(41_003, "node", "vue-tsc", shop, mem: 1.1),
                    proc(41_001, "Chromium (headless)", "playwright", shop + "/.worktrees/e2e", mem: 0.9),
                    proc(41_013, "Slack Helper (Renderer)", mem: 0.9),
                    proc(41_014, "Code Helper (Plugin)", mem: 0.8)]
        s.topIO = [proc(41_003, "node", "vue-tsc", shop, io: 120),
                   proc(41_002, "node", "vitest", shop, io: 64),
                   proc(41_015, "mdworker_shared", io: 22)]
        s.topGPU = [proc(41_006, "WindowServer", gpu: 9),
                    proc(41_001, "Chromium (headless)", "playwright", shop + "/.worktrees/e2e", gpu: 5),
                    proc(41_016, "Google Chrome Helper (GPU)", gpu: 3)]

        var log = [UInt8](repeating: 0, count: 512)
        log[1] = 0x45; log[2] = 0x01 // 325 K
        log[3] = 100; log[4] = 99; log[5] = 4
        let units: [(Int, UInt64)] = [(32, 120_000_000), (48, 74_000_000), (112, 412), (128, 3120), (144, 3)]
        for (o, v) in units { for i in 0..<8 { log[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
        s.smart = SMART(log: log)
        s.writtenToday = 84 * gb
        s.writtenSince = Calendar.current.startOfDay(for: t)

        s.dockerUp = true
        s.dockerVMCPU = 142
        s.containers = [
            Container(id: "demo-db", name: "shop-db", image: "postgres:17", cpu: 118, avgCPU: 112, age: 3 * 3600,
                      ports: ["5433→5432"], publicPorts: [5433]),
            Container(id: "demo-s3", name: "shop-minio", image: "minio/minio", cpu: 2, avgCPU: 2, age: 6 * 86400,
                      ports: ["9000", "9001"], publicPorts: [9000, 9001]),
        ]
        s.ports = [
            Port(port: 3000, pid: 41_020, title: "node", context: "nest · ~/Projects/shop/api", web: true, own: true, containerId: nil),
            Port(port: 5173, pid: 41_021, title: "node", context: "vite · " + shop, web: true, own: true, containerId: nil),
            Port(port: 6006, pid: 41_022, title: "node", context: "storybook · " + shop, web: true, own: true, containerId: nil),
            Port(port: 9001, pid: 41_023, title: "Docker", context: "shop-minio", web: true, own: false, containerId: "demo-s3"),
            Port(port: 5037, pid: 41_024, title: "adb", context: nil, web: false, own: true, containerId: nil),
            Port(port: 5433, pid: 41_023, title: "Docker", context: "shop-db", web: false, own: false, containerId: "demo-db"),
            Port(port: 9000, pid: 41_023, title: "Docker", context: "shop-minio", web: false, own: false, containerId: "demo-s3"),
        ]
        return s
    }

    /// Smooth pseudo-noise in -1…1.
    private static func noise(_ x: Double) -> Double { (sin(x) + sin(x * 2.7 + 1) * 0.6 + sin(x * 7.3 + 2) * 0.3) / 1.9 }

    /// 24 h of minute averages: a quiet machine, the orphan since 15 hours, test runs in the last
    /// three hours. The last 15 minutes lead up to the current snapshot.
    static func history(now: Date) -> History {
        let minutes = (0..<1440).map { i -> Point in
            let ago = Double(1440 - i) / 60 // hours
            let orphan = ago < 15
            let tests = ago < 3
            let n = noise(Double(i) / 25)
            let load = 7 + n * 3 + (orphan ? 13 : 0) + (tests ? 22 + noise(Double(i) / 6) * 12 : 0)
            return Point(t: now.addingTimeInterval(-ago * 3600), load: load,
                         mem: 66 + (orphan ? 9 : 0) + (tests ? 12 : 0) + n * 3,
                         ssd: 10 + abs(n) * 15 + (tests ? 150 + noise(Double(i) / 4) * 90 : 0),
                         gpu: 8 + n * 4 + (orphan ? 5 : 0), temp: 46 + load * 0.55 + n * 2,
                         top: tests ? "node · vitest" : orphan ? "Chromium (headless) · playwright" : "WindowServer")
        }
        let recent = (0..<450).map { i -> Point in
            let n = noise(Double(i) / 30)
            return Point(t: now.addingTimeInterval(Double(i - 450) * 2), load: 44 + n * 5, mem: 89 + n,
                         ssd: 240 + n * 60, gpu: 17 + n * 3, temp: 77 + n, top: "Chromium (headless) · playwright")
        }
        return History(recent: recent, minutes: minutes)
    }
}
