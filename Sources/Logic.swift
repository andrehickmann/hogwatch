import Foundation

/// Thresholds for colours and alerts.
enum Limits {
    static let loadWarnFactor = 1.5          // × logical cores
    static let loadCritFactor = 3.0
    static let loadSustain: TimeInterval = 120
    static let memWarnSustain: TimeInterval = 600
    static let diskMBps = 200.0
    static let diskIOPS = 3000.0
    static let diskSustain: TimeInterval = 120
    static let thermalSustain: TimeInterval = 60
    static let hotTemp = 85.0                // °C, SoC tile turns orange
    static let hotCPU = 50.0                 // % of one core, orphans and containers
    static let hotWindow: TimeInterval = 600
    static let cooldown: TimeInterval = 900
}

/// One row of `ps` output.
struct ProcRow {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let pcpu: Double
    let rssKB: Int
    let elapsed: TimeInterval
    let cpuTime: TimeInterval
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

enum PS {
    static let format = "pid=,ppid=,uid=,pcpu=,rss=,etime=,time=,comm="

    /// Parses one line of `ps -o \(format)`. The command path comes last and may contain spaces.
    static func parse(_ line: Substring) -> ProcRow? {
        var rest = line.drop(while: { $0 == " " })
        var f: [Substring] = []
        for _ in 0..<7 {
            guard let end = rest.firstIndex(of: " ") else { return nil }
            f.append(rest[..<end])
            rest = rest[end...].drop(while: { $0 == " " })
        }
        guard let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]),
              let pcpu = Double(f[3]), let rss = Int(f[4]), !rest.isEmpty else { return nil }
        return ProcRow(pid: pid, ppid: ppid, uid: uid, pcpu: pcpu, rssKB: rss,
                       elapsed: duration(f[5]), cpuTime: duration(f[6]), path: String(rest))
    }

    /// `[[dd-]hh:]mm:ss[.cc]`; `ps` lets the minutes of `time` run past 59.
    static func duration(_ s: Substring) -> TimeInterval {
        var days = 0.0
        var t = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            t = s[s.index(after: dash)...]
        }
        return days * 86400 + t.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}

/// Average CPU (percent of one core) over a sliding window, from cumulative CPU seconds.
struct CPUWindow {
    private var samples: [(t: TimeInterval, cpu: TimeInterval)] = []

    /// Records a sample; returns the average over `window` once that much history exists.
    mutating func add(t: TimeInterval, cpu: TimeInterval, window: TimeInterval) -> Double? {
        if samples.isEmpty || t - samples[samples.count - 1].t >= 10 { samples.append((t, cpu)) }
        while samples.count > 1, samples[1].t <= t - window { samples.removeFirst() }
        guard let first = samples.first, t - first.t >= window * 0.9 else { return nil }
        return (cpu - first.cpu) / (t - first.t) * 100
    }
}

/// Fires once a condition has held for `sustain` seconds. Afterwards it stays quiet until the
/// condition has cleared and at least `cooldown` seconds have passed.
struct AlertGate {
    let sustain: TimeInterval
    var cooldown: TimeInterval = Limits.cooldown
    private var since: TimeInterval?
    private var lastFired: TimeInterval?
    private var armed = true

    init(sustain: TimeInterval) { self.sustain = sustain }

    mutating func update(_ active: Bool, now: TimeInterval) -> Bool {
        guard active else { since = nil; armed = true; return false }
        let start = since ?? now
        since = start
        guard armed, now - start >= sustain else { return false }
        if let last = lastFired, now - last < cooldown { return false }
        armed = false
        lastFired = now
        return true
    }
}

enum Freq {
    static let idleStates: Set<String> = ["IDLE", "OFF", "DOWN"]

    /// Residency-weighted MHz of one IOReport channel. The states after the idle ones map, in order,
    /// to `table` (low → high). The number in a state name like `V0P14` does not: `V0P14` is the lowest.
    static func accumulate(_ states: [(name: String, residency: Int64)], table: [Double]) -> (active: Int64, weighted: Double) {
        var active: Int64 = 0
        var weighted = 0.0
        var i = 0
        for s in states where !idleStates.contains(s.name) {
            if i < table.count {
                weighted += Double(s.residency) * table[i]
                active += s.residency
            }
            i += 1
        }
        return (active, weighted)
    }
}

/// Human-readable names for processes, with a hint where they come from.
enum Describe {
    // Order matters: `vue-tsc` before `tsc`, `vitest` before `vite`.
    static let tools = ["vue-tsc", "vitest", "playwright", "jest", "cypress", "storybook", "webpack",
                        "esbuild", "eslint", "vite", "nuxt", "next", "tsc", "turbo", "phpunit", "pnpm", "npm"]
    static let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "php", "java"]

    static func title(path: String, args: [String]) -> String {
        let name = (path as NSString).lastPathComponent
        let headless = args.contains { $0 == "--headless" || $0.hasPrefix("--headless=") }
        return headless && !name.contains("headless") ? "\(name) (headless)" : name
    }

    static func tool(path: String, args: [String]) -> String? {
        let joined = ([path] + args).joined(separator: " ")
        if joined.contains("ms-playwright") { return "playwright" }
        for t in tools where joined.contains("/\(t)/") || joined.contains("/\(t) ") || joined.hasSuffix("/\(t)") || args.contains(t) {
            return t
        }
        let name = (path as NSString).lastPathComponent
        guard interpreters.contains(name) || name.hasPrefix("python") else { return nil }
        return args.dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent }
    }
}

enum Lsof {
    /// Parses `lsof -F pn` output into listening sockets.
    static func parse(_ s: String) -> [(pid: Int32, host: String, port: Int)] {
        var pid: Int32 = 0
        var out: [(pid: Int32, host: String, port: Int)] = []
        for line in s.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) {
                out.append((pid, String(line[line.index(after: line.startIndex)..<colon]), port))
            }
        }
        return out
    }
}

enum Fmt {
    static func age(_ s: TimeInterval) -> String {
        if s >= 86400 { return "\(Int(s / 86400)) T" }
        if s >= 3600 { return "\(Int(s / 3600)) h" }
        return "\(max(1, Int(s / 60))) min"
    }

    static func gb(_ bytes: Double) -> String {
        (bytes / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    static func mb(_ bytes: Double) -> String {
        bytes >= 1_073_741_824 ? gb(bytes) : "\(Int(bytes / 1_048_576)) MB"
    }

    static func ghz(_ mhz: Double?) -> String {
        guard let mhz else { return "–" }
        return (mhz / 1000).formatted(.number.precision(.fractionLength(1)))
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded())) %" }

    static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
