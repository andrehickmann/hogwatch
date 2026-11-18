import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum Tab: String, CaseIterable {
    case cpu, mem, ssd, gpu, temp, docker, ports
}

/// One point of the history: a 2-s sample, or a one-minute average.
struct Point: Codable, Identifiable {
    var t: Date
    var load: Double
    var mem: Double     // %
    var ssd: Double     // MB/s
    var gpu: Double     // %
    var temp: Double    // °C SoC
    var top: String
    var id: Date { t }
}

/// The last 15 minutes at full rate plus 24 hours of minute averages, persisted as JSON lines.
struct History {
    private(set) var recent: [Point] = []
    private(set) var minutes: [Point] = []
    private var bucket: [Point] = []
    let file: URL

    init(file: URL) {
        self.file = file
        let cutoff = Date().addingTimeInterval(-86400)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        minutes = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? decoder.decode(Point.self, from: Data($0.utf8)) }
            .filter { $0.t > cutoff }
        rewrite()
    }

    /// Adds a sample; writes the minute average to disk when a minute is complete.
    mutating func add(_ p: Point) {
        recent.append(p)
        if recent.count > 450 { recent.removeFirst(recent.count - 450) }
        if let first = bucket.first, Self.minute(first.t) != Self.minute(p.t) {
            let n = Double(bucket.count)
            let tops = Dictionary(grouping: bucket.map(\.top), by: { $0 })
            let m = Point(t: Self.minute(first.t),
                          load: bucket.map(\.load).reduce(0, +) / n, mem: bucket.map(\.mem).reduce(0, +) / n,
                          ssd: bucket.map(\.ssd).reduce(0, +) / n, gpu: bucket.map(\.gpu).reduce(0, +) / n,
                          temp: bucket.map(\.temp).reduce(0, +) / n,
                          top: tops.max { $0.value.count < $1.value.count }?.key ?? "")
            minutes.append(m)
            bucket = []
            if minutes.count > 1440 {
                minutes.removeFirst(minutes.count - 1440)
                if Calendar.current.component(.minute, from: m.t) == 0 { rewrite() } // compact hourly
            }
            append(m)
        }
        bucket.append(p)
    }

    private static func minute(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private func append(_ p: Point) {
        guard let line = try? Self.encoder.encode(p), let h = try? FileHandle(forWritingTo: file) else { return }
        h.seekToEndOfFile()
        h.write(line + Data("\n".utf8))
        try? h.close()
    }

    private func rewrite() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = minutes.compactMap { try? Self.encoder.encode($0) }.map { $0 + Data("\n".utf8) }
        try? lines.reduce(Data(), +).write(to: file, options: .atomic)
    }
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snap = Snapshot()
    @Published private(set) var history: History
    @Published private(set) var statusImage = NSImage()
    @Published var tab: Tab = .cpu { didSet { if tab == .ports { portsDue = true } } }
    @Published private(set) var ignored: Set<String>

    private var panelOpen = false
    private var portsDue = false
    private var busy = false
    private var tick = 0
    private let queue = DispatchQueue(label: "hogwatch.sampler")
    private let sampler = Sampler()
    let alerts = Alerts()
    private var timer: Timer?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("hogwatch")
        history = History(file: dir.appendingPathComponent("history.jsonl"))
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? [])
        statusImage = renderStatus()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        step()
    }

    var maxMHz: (e: Double?, p: Double?, gpu: Double?) { sampler.freq.maxMHz }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open {
            portsDue = true
            step()
        }
    }

    /// Processes and Docker every 10 s, processes every 2 s while the panel is open. Ports (`lsof`, the
    /// expensive part) only while the panel is open, every 10 s and right after opening.
    private func step() {
        guard !busy else { return }
        busy = true
        tick += 1
        let slow = tick % 5 == 1
        let procs = panelOpen || slow
        let ports = panelOpen && (slow || portsDue)
        portsDue = false
        let ignored = self.ignored
        queue.async { [sampler] in
            let s = sampler.sample(procs: procs, docker: slow, ports: ports, ignored: ignored)
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    private func apply(_ s: Snapshot) {
        snap = s
        busy = false
        history.add(Point(t: s.date, load: s.load[0], mem: s.memPct, ssd: s.diskMBps, gpu: s.gpuUtil ?? 0,
                          temp: s.temps.soc ?? 0, top: s.topCPU.first.map { [$0.title, $0.tool].compactMap { $0 }.joined(separator: " · ") } ?? ""))
        alerts.evaluate(s)
        statusImage = renderStatus()
    }

    // MARK: actions

    func terminate(_ p: Proc) { terminate(pid: p.pid) }

    func terminate(pid: Int32) {
        let q = queue
        queue.async { [sampler] in sampler.terminate(pid, on: q) }
        refreshPortsSoon()
    }

    /// Re-reads the ports once the process or container is gone.
    private func refreshPortsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.portsDue = true }
    }

    func ignore(_ p: Proc) {
        ignored.insert(p.ignoreKey)
        UserDefaults.standard.set(Array(ignored), forKey: "ignored")
        snap.orphans.removeAll { $0.ignoreKey == p.ignoreKey }
        statusImage = renderStatus()
    }

    func stop(_ containerId: String) {
        DispatchQueue.global().async { Sampler.stopContainer(containerId) }
        refreshPortsSoon()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }

    // MARK: menu bar

    private func renderStatus() -> NSImage {
        let level = max(snap.loadLevel, snap.memLevel, snap.tempLevel == 2 ? 2 : 0, snap.orphans.isEmpty ? 0 : 2)
        let view = HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("\(Int(snap.load[0].rounded()))").monospacedDigit()
            if !snap.orphans.isEmpty { Image(systemName: "exclamationmark.triangle.fill") }
            if snap.thermal >= 1 { Image(systemName: "thermometer.high") }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(level == 0 ? Color.black : Color.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(level == 2 ? Color.red : level == 1 ? Color.orange : Color.clear))
        let r = ImageRenderer(content: view)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = level == 0 // follows the menu bar's appearance
        return img
    }
}

/// Posts a notification once a condition holds long enough, naming the likely cause.
@MainActor
final class Alerts {
    private var load = AlertGate(sustain: Limits.loadSustain)
    private var memCrit = AlertGate(sustain: 0)
    private var memWarn = AlertGate(sustain: Limits.memWarnSustain)
    private var disk = AlertGate(sustain: Limits.diskSustain)
    private var thermal = AlertGate(sustain: Limits.thermalSustain)
    private var ssd = AlertGate(sustain: 0)
    private var notifiedOrphans = Set<Int32>()
    private var notifiedContainers = Set<String>()

    func evaluate(_ s: Snapshot) {
        let now = s.date.timeIntervalSince1970
        let cores = Double(s.cores)
        let cpuHint = s.topCPU.first.map { "Größter Verbraucher: \(Self.name($0)), \(Fmt.pct($0.cpu)) CPU." } ?? ""

        if load.update(s.load[0] >= cores * Limits.loadCritFactor, now: now) {
            post("Last kritisch: \(Int(s.load[0])) bei \(s.cores) Kernen", "Seit 2 Min. über \(Int(cores * Limits.loadCritFactor)). \(cpuHint)")
        }
        let memHint = s.topMem.first.map { "Größter Verbraucher: \(Self.name($0)), \(Fmt.gb($0.mem))." } ?? ""
        if memCrit.update(s.pressure >= 4, now: now) {
            post("Speicherdruck kritisch", "Swap \(Fmt.gb(s.swapUsed)). \(memHint)")
        } else if memWarn.update(s.pressure >= 2, now: now) {
            post("Speicherdruck hoch seit 10 Min.", "Swap \(Fmt.gb(s.swapUsed)). \(memHint)")
        }
        if disk.update(s.diskMBps >= Limits.diskMBps || s.iops >= Limits.diskIOPS, now: now) {
            let hint = s.topIO.first.map { "Größter eigener Verbraucher: \(Self.name($0)), \(Fmt.mb($0.io ?? 0))/s." }
                ?? "Kein eigener Prozess erkennbar, vermutlich System (fseventsd, Spotlight)."
            post("SSD unter Dauerlast: \(Int(s.diskMBps)) MB/s, \(Int(s.iops)) IOPS", hint)
        }
        if thermal.update(s.thermal >= 1, now: now) {
            post("Mac wird gedrosselt", "SoC \(Int(s.temps.soc ?? 0)) °C. \(cpuHint)")
        }
        if let h = s.smart, ssd.update(h.level == 2, now: now) {
            post("SSD meldet ein Problem",
                 "Warnung \(h.criticalWarning), Reserve \(h.spare) % (Grenze \(h.spareThreshold) %), \(h.mediaErrors) Medienfehler. Backup prüfen.")
        }
        for o in s.orphans where !notifiedOrphans.contains(o.pid) {
            post("Verwaister Prozess: \(o.title)",
                 "\(Fmt.pct(o.avgCPU ?? o.cpu)) CPU, läuft seit \(Fmt.age(o.age)) ohne Elternprozess." + (o.origin.map { " Aus \($0)." } ?? ""))
        }
        notifiedOrphans = Set(s.orphans.map(\.pid))
        let hot = s.containers.filter { ($0.avgCPU ?? 0) >= Limits.hotCPU }
        for c in hot where !notifiedContainers.contains(c.id) {
            post("Container unter Dauerlast: \(c.name)", "\(Fmt.pct(c.avgCPU ?? 0)) CPU seit 10 Min., läuft seit \(Fmt.age(c.age)).")
        }
        notifiedContainers = Set(hot.map(\.id))
    }

    private static func name(_ p: Proc) -> String { p.tool.map { "\(p.title) (\($0))" } ?? p.title }

    func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
