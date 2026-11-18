import AppKit

struct Proc: Identifiable {
    let pid: Int32
    var id: Int32 { pid }
    let title: String
    let tool: String?
    let cwd: String?
    let cpu: Double            // % of one core since the previous sample
    let mem: Double            // bytes: footprint for own processes, RSS for others
    let io: Double?            // bytes/s, own processes only
    let gpu: Double?           // % of the GPU
    let age: TimeInterval
    let avgCPU: Double?        // over Limits.hotWindow
    let ignoreKey: String

    /// "vitest · ~/Projects/shop/api"
    var origin: String? {
        let parts = [tool, cwd].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct Container: Identifiable {
    let id: String
    let name: String
    let image: String
    let cpu: Double?
    let avgCPU: Double?
    let age: TimeInterval
    let ports: [String]
    let publicPorts: [Int]
}

struct Port: Identifiable {
    var id: Int { port }
    let port: Int
    let pid: Int32
    let title: String
    let context: String?
    let web: Bool
    let own: Bool              // can be terminated without root
    let containerId: String?   // published by a Docker container
}

struct Snapshot {
    var date = Date()
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var load = [0.0, 0, 0]
    var cpuBusy: Double?
    var memApp = 0.0
    var memWired = 0.0
    var memCompressed = 0.0
    var memUsed: Double { memApp + memWired + memCompressed }
    var memTotal = Sys.memTotal
    var pressure: Int32 = 1
    var swapUsed = 0.0
    var readBps = 0.0
    var writeBps = 0.0
    var iops = 0.0
    var gpuUtil: Double?
    var eMHz: Double?
    var pMHz: Double?
    var gpuMHz: Double?
    var thermal = 0
    var lowPower = false
    var temps = Temps()
    var topCPU: [Proc] = []
    var topMem: [Proc] = []
    var topIO: [Proc] = []
    var topGPU: [Proc] = []
    var orphans: [Proc] = []
    var dockerUp = false
    var dockerVMCPU: Double?
    var containers: [Container] = []
    var ports: [Port] = []

    var diskMBps: Double { (readBps + writeBps) / 1_048_576 }
    var memPct: Double { memTotal > 0 ? memUsed / memTotal * 100 : 0 }

    // 0 normal, 1 warning, 2 critical
    var loadLevel: Int {
        let c = Double(cores)
        return load[0] >= c * Limits.loadCritFactor ? 2 : load[0] >= c * Limits.loadWarnFactor ? 1 : 0
    }
    var memLevel: Int { pressure >= 4 ? 2 : pressure >= 2 ? 1 : 0 }
    var diskLevel: Int { diskMBps >= Limits.diskMBps || iops >= Limits.diskIOPS ? 1 : 0 }
    var tempLevel: Int { thermal >= 1 ? 2 : (temps.soc ?? 0) >= Limits.hotTemp ? 1 : 0 }
    var dockerLevel: Int { containers.contains { ($0.avgCPU ?? $0.cpu ?? 0) >= Limits.hotCPU } ? 1 : 0 }
}

/// Collects a snapshot. Used only from the monitor's serial queue.
final class Sampler {
    private var last = Snapshot()
    private var prevTime: TimeInterval?
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var prevDisk: (read: UInt64, write: UInt64, ops: UInt64)?
    private let temps = TemperatureReader()
    let freq = FrequencyReader()

    // per-process state
    private var procTime: TimeInterval?
    private var prevCPU: [Int32: TimeInterval] = [:]
    private var prevIO: [Int32: UInt64] = [:]
    private var prevGPU: [Int32: UInt64] = [:]
    private var windows: [Int32: CPUWindow] = [:]
    private var info: [Int32: (path: String, title: String, tool: String?, cwd: String?)] = [:]
    private var rows: [Int32: ProcRow] = [:]

    // docker state
    private var prevDocker: [String: (t: TimeInterval, ns: Double)] = [:]
    private var dockerWindows: [String: CPUWindow] = [:]

    private var webCache: [String: Bool] = [:]

    func sample(procs: Bool, docker: Bool, ports: Bool, ignored: Set<String>) -> Snapshot {
        let now = Date()
        let t = now.timeIntervalSince1970
        var s = last
        s.date = now
        s.load = Sys.load()
        let dt = prevTime.map { t - $0 } ?? 0
        prevTime = t

        if let ticks = Sys.cpuTicks() {
            if let p = prevTicks, ticks.total > p.total {
                s.cpuBusy = Double(ticks.busy - p.busy) / Double(ticks.total - p.total) * 100
            }
            prevTicks = ticks
        }
        (s.memApp, s.memWired, s.memCompressed) = Sys.memory()
        s.pressure = Sys.memPressure()
        s.swapUsed = Sys.swapUsed()
        if let d = Sys.disk() {
            if let p = prevDisk, dt > 0, d.read >= p.read, d.write >= p.write, d.ops >= p.ops {
                s.readBps = Double(d.read - p.read) / dt
                s.writeBps = Double(d.write - p.write) / dt
                s.iops = Double(d.ops - p.ops) / dt
            }
            prevDisk = d
        }
        let f = freq.read()
        s.eMHz = f.e
        s.pMHz = f.p
        s.gpuMHz = f.gpu
        s.thermal = Thermal.level()
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.temps = temps.read()

        let gpu = Sys.gpu()
        s.gpuUtil = gpu.util
        if procs { sampleProcesses(into: &s, t: t, gpuNs: gpu.nsByPid, ignored: ignored) }
        if docker { sampleDocker(into: &s, t: t) }
        if ports { s.ports = samplePorts(containers: s.containers) }
        last = s
        return s
    }

    // MARK: processes

    private func sampleProcesses(into s: inout Snapshot, t: TimeInterval, gpuNs: [Int32: UInt64], ignored: Set<String>) {
        guard let out = run("/bin/ps", ["-A", "-o", PS.format]) else { return }
        let parsed = out.split(separator: "\n").compactMap(PS.parse)
        let me = getuid()
        let dt = procTime.map { t - $0 } ?? 0
        procTime = t
        rows = Dictionary(parsed.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var cpu: [Int32: Double] = [:]
        var io: [Int32: Double] = [:]
        var gpu: [Int32: Double] = [:]
        var avg: [Int32: Double] = [:]
        var nextCPU: [Int32: TimeInterval] = [:]
        var nextIO: [Int32: UInt64] = [:]
        // RSS misses compressed and swapped pages (a VM with 12 GB footprint shows 80 MB RSS), so own
        // processes use the physical footprint like Activity Monitor; others fall back to RSS.
        var mem: [Int32: Double] = [:]
        for r in parsed {
            mem[r.pid] = Double(r.rssKB) * 1024
            nextCPU[r.pid] = r.cpuTime
            if let p = prevCPU[r.pid], dt > 0 { cpu[r.pid] = max(0, (r.cpuTime - p) / dt * 100) } else { cpu[r.pid] = r.pcpu }
            var w = windows[r.pid] ?? CPUWindow()
            // Before the window is covered, fall back to the lifetime average of long-running processes.
            avg[r.pid] = w.add(t: t, cpu: r.cpuTime, window: Limits.hotWindow)
                ?? (r.elapsed >= Limits.hotWindow ? r.cpuTime / r.elapsed * 100 : nil)
            windows[r.pid] = w
            guard r.uid == me else { continue }
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(r.pid, RUSAGE_INFO_V4, $0) }
            } == 0
            if ok {
                mem[r.pid] = Double(ri.ri_phys_footprint)
                let bytes = ri.ri_diskio_bytesread + ri.ri_diskio_byteswritten
                if let p = prevIO[r.pid], dt > 0, bytes >= p { io[r.pid] = Double(bytes - p) / dt }
                nextIO[r.pid] = bytes
            }
        }
        for (pid, ns) in gpuNs {
            if let p = prevGPU[pid], dt > 0, ns >= p { gpu[pid] = Double(ns - p) / dt / 1e9 * 100 }
        }
        prevCPU = nextCPU
        prevIO = nextIO
        prevGPU = gpuNs
        windows = windows.filter { rows[$0.key] != nil }
        info = info.filter { rows[$0.key]?.path == $0.value.path }

        func proc(_ r: ProcRow) -> Proc {
            let i = describe(r)
            return Proc(pid: r.pid, title: i.title, tool: i.tool, cwd: i.cwd, cpu: cpu[r.pid] ?? 0,
                        mem: mem[r.pid] ?? 0, io: io[r.pid], gpu: gpu[r.pid], age: r.elapsed,
                        avgCPU: avg[r.pid], ignoreKey: r.path + " " + (i.tool ?? ""))
        }
        func top(_ n: Int, above floor: Double, by key: (ProcRow) -> Double) -> [Proc] {
            parsed.filter { key($0) > floor }.sorted { key($0) > key($1) }.prefix(n).map(proc)
        }
        s.topCPU = top(6, above: 0.5) { cpu[$0.pid] ?? 0 }
        s.topMem = top(8, above: 0) { mem[$0.pid] ?? 0 }
        s.topIO = top(6, above: 100_000) { io[$0.pid] ?? 0 }
        s.topGPU = top(6, above: 0.5) { gpu[$0.pid] ?? 0 }
        s.dockerVMCPU = parsed.first { $0.name == Self.vmProcess && describe($0).tool == "für Docker" }.flatMap { cpu[$0.pid] }
        // Orphan: own process whose parent died (re-parented to launchd), not a regular app, busy for long.
        s.orphans = parsed.filter { r in
            r.ppid == 1 && r.uid == me && (avg[r.pid] ?? 0) >= Limits.hotCPU
                && NSRunningApplication(processIdentifier: r.pid)?.activationPolicy != .regular
        }.map(proc).filter { !ignored.contains($0.ignoreKey) }
    }

    private static let vmProcess = "com.apple.Virtualization.VirtualMachine"

    private func describe(_ r: ProcRow) -> (path: String, title: String, tool: String?, cwd: String?) {
        if let i = info[r.pid] { return i }
        let args = Self.args(r.pid)
        let title = r.name == Self.vmProcess ? "Virtuelle Maschine" : Describe.title(path: r.path, args: args)
        var tool = Describe.tool(path: r.path, args: args)
        // XPC services and VMs run under launchd; name the app they work for ("für Docker").
        if tool == nil, let owner = Sys.responsiblePid(r.pid).flatMap(Self.appName), !title.contains(owner) {
            tool = "für \(owner)"
        }
        let i = (r.path, title, tool, Self.cwd(r.pid))
        info[r.pid] = i
        return i
    }

    /// "Docker" for /Applications/Docker.app/Contents/MacOS/com.docker.backend, else the executable name.
    private static func appName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") {
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    /// Command-line arguments (own processes only).
    static func args(_ pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }   // executable path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// Working directory (own processes only), nil for "/".
    static func cwd(_ pid: Int32) -> String? {
        var vi = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: vi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        // App bundles run inside themselves; that says nothing about the origin.
        return path.isEmpty || path == "/" || path.contains(".app/") ? nil : Fmt.shortPath(path)
    }

    /// SIGTERM to the process and its descendants, SIGKILL to survivors after 3 s.
    func terminate(_ pid: Int32, on queue: DispatchQueue) {
        var victims = [pid]
        var i = 0
        while i < victims.count {
            let parent = victims[i]
            victims += rows.values.filter { $0.ppid == parent }.map(\.pid)
            i += 1
        }
        victims = victims.filter { rows[$0]?.uid == getuid() }
        victims.forEach { kill($0, SIGTERM) }
        queue.asyncAfter(deadline: .now() + 3) {
            victims.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
        }
    }

    // MARK: docker

    private static let dockerSocket = ["/var/run/docker.sock", NSHomeDirectory() + "/.docker/run/docker.sock"]
        .first { FileManager.default.fileExists(atPath: $0) }

    private func dockerGET(_ path: String) -> Any? {
        guard let sock = Self.dockerSocket,
              let out = run("/usr/bin/curl", ["-sf", "--max-time", "2", "--unix-socket", sock, "http://localhost" + path]) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(out.utf8))
    }

    static func stopContainer(_ id: String) {
        guard let sock = dockerSocket else { return }
        _ = runCommand("/usr/bin/curl", ["-sf", "--max-time", "15", "-X", "POST", "--unix-socket", sock, "http://localhost/containers/\(id)/stop?t=5"])
    }

    private func sampleDocker(into s: inout Snapshot, t: TimeInterval) {
        guard let list = dockerGET("/containers/json") as? [[String: Any]] else {
            s.dockerUp = false
            s.containers = []
            return
        }
        s.dockerUp = true
        var seen = Set<String>()
        s.containers = list.compactMap { c in
            guard let id = c["Id"] as? String else { return nil }
            seen.insert(id)
            var cpu: Double?
            var avg: Double?
            let stats = dockerGET("/containers/\(id)/stats?stream=false&one-shot=true") as? [String: Any]
            if let ns = ((stats?["cpu_stats"] as? [String: Any])?["cpu_usage"] as? [String: Any])?["total_usage"] as? Double {
                if let p = prevDocker[id], t > p.t { cpu = (ns - p.ns) / 1e9 / (t - p.t) * 100 }
                prevDocker[id] = (t, ns)
                var w = dockerWindows[id] ?? CPUWindow()
                avg = w.add(t: t, cpu: ns / 1e9, window: Limits.hotWindow)
                dockerWindows[id] = w
            }
            let rawPorts = (c["Ports"] as? [[String: Any]]) ?? []
            let mapped = rawPorts.compactMap { p -> (pub: Int, text: String)? in
                guard let priv = p["PrivatePort"] as? Int else { return nil }
                guard let pub = p["PublicPort"] as? Int else { return nil }
                return (pub, pub == priv ? "\(pub)" : "\(pub)→\(priv)")
            }
            var uniq: [Int: String] = [:]
            mapped.forEach { uniq[$0.pub] = $0.text }
            let created = (c["Created"] as? Double).map { t - $0 } ?? 0
            return Container(id: id, name: ((c["Names"] as? [String])?.first ?? id).trimmingCharacters(in: ["/"]),
                             image: c["Image"] as? String ?? "", cpu: cpu, avgCPU: avg, age: created,
                             ports: uniq.keys.sorted().compactMap { uniq[$0] }, publicPorts: uniq.keys.sorted())
        }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }
        prevDocker = prevDocker.filter { seen.contains($0.key) }
        dockerWindows = dockerWindows.filter { seen.contains($0.key) }
    }

    // MARK: ports

    private func samplePorts(containers: [Container]) -> [Port] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]) else { return [] }
        var byPort: [Int: (pid: Int32, host: String)] = [:]
        for l in Lsof.parse(out) where byPort[l.port] == nil { byPort[l.port] = (l.pid, l.host) }
        let containerByPort = Dictionary(containers.flatMap { c in c.publicPorts.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })

        // Probe unknown ports for HTTP in parallel; cache per pid and port.
        let unknown = byPort.filter { webCache["\($0.value.pid):\($0.key)"] == nil }.map { ($0.key, $0.value) }
        var results = [Bool](repeating: false, count: unknown.count)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: unknown.count) { i in
                buf[i] = Self.speaksHTTP(host: unknown[i].1.host, port: unknown[i].0)
            }
        }
        for (i, u) in unknown.enumerated() { webCache["\(u.1.pid):\(u.0)"] = results[i] }

        let isWeb = { (port: Int) in self.webCache["\(byPort[port]!.pid):\(port)"] ?? false }
        let order = byPort.keys.sorted { (isWeb($0) ? 0 : 1, $0) < (isWeb($1) ? 0 : 1, $1) } // web servers first
        return order.map { port in
            let (pid, _) = byPort[port]!
            let row = rows[pid]
            var title = row?.name ?? "pid \(pid)"
            var context: String?
            let container = containerByPort[port]
            if let container {
                title = "Docker"
                context = container.name
            } else if let row {
                let i = describe(row)
                title = i.title
                context = [i.tool, i.cwd].compactMap { $0 }.joined(separator: " · ")
                if context == "" { context = nil }
            }
            return Port(port: port, pid: pid, title: title, context: context, web: webCache["\(pid):\(port)"] ?? false,
                        // Never offer to kill Docker's own port forwarder; that would take Docker down.
                        own: row?.uid == getuid() && !(row?.name.hasPrefix("com.docker") ?? false), containerId: container?.id)
        }
    }

    private static func speaksHTTP(host: String, port: Int) -> Bool {
        let h = host.contains(":") ? "[::1]" : "127.0.0.1"
        guard let url = URL(string: "http://\(h):\(port)/") else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 0.5)) { _, resp, _ in
            ok = resp is HTTPURLResponse
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 0.8) == .timedOut { task.cancel() }
        return ok
    }

    private func run(_ exe: String, _ args: [String]) -> String? { runCommand(exe, args) }
}

/// Runs a tool with a C locale (decimal points in `ps`) and returns its stdout.
func runCommand(_ exe: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}
