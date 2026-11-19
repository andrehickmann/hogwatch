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

    /// One sentence on what a process does, for the row's info popover. German: the user reads it.
    static func purpose(_ name: String) -> String? {
        if let p = purposes[name] { return p }
        if name.hasPrefix("mdworker") || name.hasPrefix("mds") { return purposes["mds"] }
        if name.hasPrefix("com.apple.WebKit") { return "zeigt eine Webseite an" }
        if name.contains("(Renderer)") { return "stellt einen Tab oder ein Fenster dar \u{2014} jeder bekommt einen eigenen Prozess" }
        if name.contains("(GPU)") { return "zeichnet die Oberfl\u{e4}che \u{fc}ber die Grafikkarte" }
        if name.contains("(Plugin)") || name.contains("(Utility)") { return "f\u{fc}hrt einen Teil der App getrennt aus" }
        if name.hasPrefix("spotlightknowledged") { return purposes["mds"] }
        if name.hasSuffix(" Helper") { return "Hilfsprozess der App" }
        if name.hasSuffix("XPCService") || name.hasSuffix(".xpc") { return "Hintergrunddienst eines Programms" }
        return nil
    }

    /// Only entries that are certain; an unknown process shows its full name and nothing else.
    static let purposes: [String: String] = [
        "kernel_task": "der Kern von macOS; h\u{e4}lt bei Hitze auch Rechenzeit frei, um den Mac zu k\u{fc}hlen",
        "launchd": "startet und \u{fc}berwacht alle anderen Prozesse",
        "WindowServer": "zeichnet alle Fenster und verarbeitet Maus und Tastatur",
        "loginwindow": "verwaltet die angemeldete Sitzung",
        "Finder": "Schreibtisch und Dateifenster",
        "Dock": "Dock, Mission Control und Launchpad",
        "ControlCenter": "Kontrollzentrum und Menüleistensymbole",
        "NotificationCenter": "Mitteilungen und Widgets",
        "Spotlight": "das Suchfenster",
        "WindowManager": "Stage Manager und Fensteranordnung",
        "SystemUIServer": "\u{e4}ltere Men\u{fc}leistensymbole",
        "fseventsd": "protokolliert jede Dateiänderung f\u{fc}r Spotlight und Time Machine",
        "mds": "baut den Spotlight-Index auf und durchsucht daf\u{fc}r neue Dateien",
        "corespotlightd": "Spotlight-Index der Apps",
        "installd": "installiert Pakete und Systemupdates im Hintergrund",
        "softwareupdated": "sucht und l\u{e4}dt Systemupdates",
        "mobileassetd": "l\u{e4}dt Systemkomponenten nach: Stimmen, W\u{f6}rterb\u{fc}cher, Modelle",
        "syspolicyd": "Gatekeeper: pr\u{fc}ft, ob ein Programm ausgef\u{fc}hrt werden darf",
        "amfid": "pr\u{fc}ft die Signatur startender Programme",
        "trustd": "pr\u{fc}ft Zertifikate von Servern und Programmen",
        "securityd": "verwaltet Schl\u{fc}sselbund und Zugangsdaten",
        "secd": "h\u{e4}lt den Schl\u{fc}sselbund zwischen Ger\u{e4}ten synchron",
        "tccd": "verwaltet die Zugriffsrechte auf Kamera, Mikrofon, Ordner",
        "sandboxd": "\u{fc}berwacht die Sandbox-Grenzen der Programme",
        "opendirectoryd": "Benutzerkonten und Gruppen",
        "cfprefsd": "liest und schreibt die Einstellungen aller Programme",
        "distnoted": "verteilt Nachrichten zwischen Programmen",
        "notifyd": "verteilt Systemmeldungen zwischen Prozessen",
        "logd": "schreibt das Systemprotokoll",
        "syslogd": "schreibt das klassische Systemprotokoll",
        "diskarbitrationd": "bindet Laufwerke ein und wieder aus",
        "revisiond": "verwaltet die Versionen von Dokumenten",
        "backupd": "Time Machine sichert gerade",
        "backupd-helper": "pr\u{fc}ft, ob eine Time-Machine-Sicherung f\u{e4}llig ist",
        "bird": "synchronisiert iCloud Drive",
        "cloudd": "synchronisiert iCloud-Daten der Programme",
        "fileproviderd": "stellt Dateien von iCloud, Dropbox und \u{e4}hnlichen Diensten bereit",
        "nsurlsessiond": "l\u{e4}dt im Hintergrund herunter und hoch",
        "apsd": "h\u{e4}lt die Verbindung f\u{fc}r Push-Nachrichten offen",
        "identityservicesd": "iMessage und FaceTime",
        "akd": "meldet die Apple-ID an",
        "AppleIDAuthAgent": "meldet die Apple-ID an",
        "mDNSResponder": "l\u{f6}st Namen auf: DNS und Ger\u{e4}te im lokalen Netz",
        "configd": "Netzwerkeinstellungen und Verbindungswechsel",
        "symptomsd": "beobachtet, wie gut das Netz gerade funktioniert",
        "socketfilterfw": "die Firewall",
        "airportd": "WLAN-Verbindung",
        "bluetoothd": "Bluetooth-Ger\u{e4}te",
        "coreaudiod": "Tonausgabe und -aufnahme",
        "hidd": "Tastatur, Maus und Trackpad",
        "powerd": "Ruhezustand und Energieverwaltung",
        "thermalmonitord": "\u{fc}berwacht die Temperatur",
        "rapportd": "Handoff, universelle Zwischenablage und Sidecar",
        "sharingd": "AirDrop, Freigaben und Handoff",
        "photoanalysisd": "durchsucht die Fotos nach Gesichtern, Orten und Objekten",
        "photolibraryd": "verwaltet die Fotos-Mediathek",
        "mediaanalysisd": "erkennt Text und Objekte in Bildern und Videos",
        "suggestd": "wertet Inhalte f\u{fc}r Siri-Vorschl\u{e4}ge aus",
        "parsecd": "Siri- und Spotlight-Suche im Internet",
        "knowledge-agent": "sammelt Ger\u{e4}teaktivit\u{e4}t f\u{fc}r Vorschl\u{e4}ge",
        "BiomeAgent": "sammelt Ger\u{e4}teaktivit\u{e4}t f\u{fc}r Vorschl\u{e4}ge und Fokus",
        "coreduetd": "sagt voraus, was als N\u{e4}chstes gebraucht wird",
        "runningboardd": "teilt laufenden Programmen Rechenzeit und Speicher zu",
        "containermanagerd": "verwaltet die Datenordner der Programme",
        "lsd": "verkn\u{fc}pft Dateitypen mit Programmen",
        "pboard": "die Zwischenablage",
        "universalaccessd": "Bedienungshilfen",
        "ReportCrash": "schreibt einen Absturzbericht",
        "spindump": "protokolliert ein h\u{e4}ngendes Programm",
        "UserEventAgent": "reagiert auf Systemereignisse wie angeschlossene Ger\u{e4}te",
        "kernelmanagerd": "verwaltet Kernel-Erweiterungen",
        "VTDecoderXPCService": "dekodiert Video",
        "MTLCompilerService": "\u{fc}bersetzt Grafik-Shader f\u{fc}r Metal",
        "XProtectService": "pr\u{fc}ft Dateien auf bekannte Schadsoftware",
        "dasd": "plant Hintergrundarbeiten ein, wenn der Mac Luft hat",
        "duetexpertd": "sagt aus der Nutzung voraus, was als N\u{e4}chstes gebraucht wird",
        "triald": "steuert, welche Systemfunktionen hier erprobt werden",
        "node": "ein Node.js-Programm \u{2014} meist ein Entwicklungswerkzeug oder Server",
        "ssh": "offene SSH-Verbindung",
        "git": "Git-Befehl",
        "yes": "gibt endlos Text aus \u{2014} meist ein vergessener Testbefehl",
    ]
}

/// NVMe SMART / health information log (log page 2, 512 bytes, little endian).
struct SMART {
    let criticalWarning: Int
    let tempC: Int
    let spare: Int             // % available spare
    let spareThreshold: Int
    let percentUsed: Int       // wear estimate by the controller
    let readBytes: Double
    let writtenBytes: Double
    let powerCycles: UInt64
    let powerOnHours: UInt64
    let unsafeShutdowns: UInt64
    let mediaErrors: UInt64

    init?(log b: [UInt8]) {
        guard b.count >= 192 else { return nil }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        let unit = 512_000.0 // a "data unit" is 1000 sectors of 512 bytes
        criticalWarning = Int(b[0])
        tempC = (Int(b[1]) | Int(b[2]) << 8) - 273
        spare = Int(b[3])
        spareThreshold = Int(b[4])
        percentUsed = Int(b[5])
        readBytes = Double(u64(32)) * unit
        writtenBytes = Double(u64(48)) * unit
        powerCycles = u64(112)
        powerOnHours = u64(128)
        unsafeShutdowns = u64(144)
        mediaErrors = u64(160)
    }

    /// 0 good, 1 worn (≥ 80 %), 2 problem reported by the controller
    var level: Int {
        if criticalWarning != 0 || spare < spareThreshold || mediaErrors > 0 { return 2 }
        return percentUsed >= 80 ? 1 : 0
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
        if bytes >= 1_073_741_824 { return gb(bytes) }
        let mb = bytes / 1_048_576
        return mb < 10 ? mb.formatted(.number.precision(.fractionLength(1))) + " MB" : "\(Int(mb)) MB"
    }

    static func tb(_ bytes: Double) -> String {
        (bytes / 1e12).formatted(.number.precision(.fractionLength(1))) + " TB"
    }

    static func ghz(_ mhz: Double?) -> String {
        guard let mhz else { return "–" }
        return (mhz / 1000).formatted(.number.precision(.fractionLength(1)))
    }

    /// Watt without the unit — one decimal below 10 W, whole watts above.
    static func watt(_ w: Double?) -> String {
        guard let w else { return "–" }
        return w.formatted(.number.precision(.fractionLength(w < 10 ? 1 : 0)))
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded())) %" }

    static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

struct Power {
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var dram: Double?

    /// Everything the chip's counters cover. Not the whole machine: display, SSD and Wi-Fi
    /// have no channel here, so the wall draw is higher.
    var total: Double? {
        let parts = [cpu, gpu, ane, dram].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

enum Energy {
    /// Watt from an energy delta reported by IOReport, whose channels label their own unit.
    static func watts(_ value: Int64, unit: String, dt: TimeInterval) -> Double? {
        let factor: Double
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": factor = 1
        case "mJ": factor = 1e-3
        case "uJ", "\u{00b5}J": factor = 1e-6
        case "nJ": factor = 1e-9
        default: return nil
        }
        return dt > 0 ? Double(value) * factor / dt : nil
    }
}

enum Freeze {
    /// Rows where the pointer found them: known ids keep their rank, anything new goes to the end.
    static func order<T>(_ items: [T], id: (T) -> Int32, following pids: [Int32]) -> [T] {
        guard !pids.isEmpty else { return items }
        let rank = Dictionary(pids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .map { (rank[id($0.element)] ?? pids.count + $0.offset, $0.element) }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }
}
