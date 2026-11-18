import Charts
import SwiftUI

func levelColor(_ level: Int) -> Color { level >= 2 ? .red : level == 1 ? .orange : .primary }

let pressureNames: [Int32: String] = [1: "normal", 2: "Warnung", 4: "kritisch"]

struct PanelView: View {
    @ObservedObject var m: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabBar(m: m)
            // Fixed height: the MenuBarExtra window keeps the size of its first appearance.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !m.snap.orphans.isEmpty { OrphanBanner(m: m) }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: Self.contentHeight)
            Divider()
            HStack {
                Button {
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Verlauf", systemImage: "chart.xyaxis.line") }
                Spacer()
                Toggle("Bei Anmeldung", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                InfoButton()
                Button("Beenden") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { m.setPanelOpen(true) }
        .onDisappear { m.setPanelOpen(false) }
    }

    static let contentHeight: CGFloat = 360

    @ViewBuilder private var content: some View {
        let s = m.snap
        let recent = m.history.recent
        VStack(alignment: .leading, spacing: 4) {
            switch m.tab {
            case .cpu:
                Header(left: "Last \(Int(s.load[0].rounded())) · \(Int(s.load[1].rounded())) · \(Int(s.load[2].rounded())) · \(s.cores) Kerne",
                       right: "P \(Fmt.ghz(s.pMHz)) · E \(Fmt.ghz(s.eMHz)) GHz")
                Spark(points: recent, value: \.load, warn: Double(s.cores) * Limits.loadWarnFactor, color: levelColor(s.loadLevel))
                ForEach(s.topCPU) { ProcLine(title: $0.title, value: Fmt.pct($0.cpu), sub: $0.origin) }
            case .mem:
                Header(left: "\(Fmt.gb(s.memUsed)) von \(Fmt.gb(s.memTotal)) · Druck: \(pressureNames[s.pressure] ?? "\(s.pressure)")",
                       right: "Swap \(Fmt.gb(s.swapUsed))", rightColor: s.swapUsed > 1_073_741_824 ? .orange : .secondary)
                Header(left: "Apps \(Fmt.gb(s.memApp)) · System \(Fmt.gb(s.memWired)) · Komprimiert \(Fmt.gb(s.memCompressed))")
                Spark(points: recent, value: \.mem, warn: 85, color: levelColor(s.memLevel))
                ForEach(s.topMem) { ProcLine(title: $0.title, value: Fmt.gb($0.mem), sub: $0.origin) }
                Note("Wie die Aktivitätsanzeige: inklusive komprimierter und ausgelagerter Seiten, daher größer als „Apps“. Fremde Prozesse (root) nur mit residentem Speicher.")
            case .ssd:
                Header(left: "R \(Int(s.readBps / 1_048_576)) · W \(Int(s.writeBps / 1_048_576)) MB/s", right: "\(Int(s.iops)) IOPS")
                if let h = s.smart { SSDHealthView(h: h, today: s.writtenToday, since: s.writtenSince) }
                Spark(points: recent, value: \.ssd, warn: Limits.diskMBps, color: levelColor(s.diskLevel))
                ForEach(s.topIO) { ProcLine(title: $0.title, value: "\(Fmt.mb($0.io ?? 0))/s", sub: $0.origin) }
                Note("IO von Systemprozessen (fseventsd, Spotlight) ist ohne Root nicht zuordenbar.")
            case .gpu:
                Header(left: "\(s.gpuUtil.map { Fmt.pct($0) } ?? "–") Auslastung",
                       right: "\(Fmt.ghz(s.gpuMHz)) / \(Fmt.ghz(m.maxMHz.gpu)) GHz")
                Spark(points: recent, value: \.gpu, color: .secondary)
                ForEach(s.topGPU) { ProcLine(title: $0.title, value: Fmt.pct($0.gpu ?? 0), sub: $0.origin) }
            case .temp:
                if Sys.model.hasPrefix("MacBookPro18") {
                    MacHeatmap(s: s, maxMHz: m.maxMHz)
                } else {
                    TempList(s: s)
                }
            case .docker:
                DockerTab(m: m)
            case .ports:
                PortsTab(m: m)
            }
        }
    }
}

struct InfoButton: View {
    static let repository = URL(string: "https://github.com/andrehickmann/hogwatch")!
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .help("Über hogwatch")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                    Text("hogwatch \(version)").font(.headline)
                    Text("Zeigt, was den Mac auffrisst – CPU, Speicher, SSD, GPU, Temperatur, Docker und Ports – und warnt, bevor er unbenutzbar wird.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("github.com/andrehickmann/hogwatch", destination: Self.repository).font(.caption)
                }
                .padding(12)
                .frame(width: 250)
            }
    }
}

struct Header: View {
    let left: String
    var right = ""
    var rightColor: Color = .secondary

    var body: some View {
        HStack {
            Text(left)
            Spacer()
            Text(right).foregroundStyle(rightColor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption2).foregroundStyle(.tertiary).padding(.top, 4) }
}

struct ProcLine: View {
    let title: String
    let value: String
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(value).font(.system(.caption, design: .monospaced))
            }
            .font(.callout)
            if let sub {
                Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
    }
}

struct Spark: View {
    let points: [Point]
    let value: KeyPath<Point, Double>
    var warn: Double?
    var color: Color = .secondary

    var body: some View {
        Chart {
            ForEach(points) { LineMark(x: .value("t", $0.t), y: .value("v", $0[keyPath: value])).foregroundStyle(color) }
            if let warn {
                RuleMark(y: .value("warn", warn))
                    .foregroundStyle(.orange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 40)
        .padding(.vertical, 2)
    }
}

struct TabBar: View {
    @ObservedObject var m: Monitor

    var body: some View {
        let s = m.snap
        HStack(spacing: 3) {
            tile(.cpu, "CPU", "\(Int(s.load[0].rounded()))", s.loadLevel)
            tile(.mem, "RAM", "\(Int(s.memPct.rounded()))%", s.memLevel)
            tile(.ssd, "SSD", "\(Int(s.diskMBps.rounded()))", s.diskLevel)
            tile(.gpu, "GPU", s.gpuUtil.map { "\(Int($0))%" } ?? "–", 0)
            tile(.temp, "Temp", s.temps.soc.map { "\(Int($0))°" } ?? "–", s.tempLevel)
            tile(.docker, nil, s.dockerUp ? "\(s.containers.count)" : "–", s.dockerLevel, icon: "shippingbox")
            tile(.ports, nil, "\(s.ports.count)", 0, icon: "network")
        }
    }

    /// A tile shows a label or an SF Symbol above its value.
    private func tile(_ tab: Tab, _ label: String?, _ value: String, _ level: Int, icon: String? = nil) -> some View {
        Button { m.tab = tab } label: {
            VStack(spacing: 0) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 14)
                } else {
                    Text(label ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(levelColor(level))
            }
            .frame(maxWidth: icon == nil ? .infinity : 34)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(m.tab == tab ? Color.primary.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(m.tab == tab ? Color.primary.opacity(0.25) : .clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OrphanBanner: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(m.snap.orphans) { o in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(o.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        ConfirmButton("Beenden") { m.terminate(o) }
                        Button("Ignorieren") { m.ignore(o) }.controlSize(.small)
                    }
                    .font(.callout)
                    Text("\(Fmt.pct(o.avgCPU ?? o.cpu)) CPU · seit \(Fmt.age(o.age)) verwaist").font(.caption)
                    if let origin = o.origin {
                        Text(origin).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    }
}

/// First click arms the button for 3 s, the second one acts.
struct ConfirmButton: View {
    let label: String
    var systemImage: String?
    let action: () -> Void
    @State private var armed = false

    init(_ label: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        } label: {
            if let systemImage, !armed { Image(systemName: systemImage) } else { Text(armed ? "Sicher?" : label) }
        }
        .controlSize(.small)
        .tint(armed ? .red : nil)
        .help(label)
    }
}

struct DockerTab: View {
    @ObservedObject var m: Monitor

    var body: some View {
        let s = m.snap
        if s.dockerAsleep {
            Note("Docker im Ruhemodus: keine Container, VM angehalten. hogwatch fragt erst wieder, wenn die VM läuft.")
        } else if !s.dockerUp {
            Note("Docker läuft nicht.")
        } else {
            Header(left: "\(s.containers.count) Container", right: s.dockerVMCPU.map { "VM \(Fmt.pct($0)) CPU" } ?? "")
            if s.containers.isEmpty { Note("Keine laufenden Container.") }
            ForEach(s.containers) { c in
                HStack(alignment: .top) {
                    ProcLine(title: c.name, value: "\(c.cpu.map { Fmt.pct($0) } ?? "–") · \(Fmt.age(c.age))",
                             sub: ([c.image] + c.ports).joined(separator: " · "))
                    ConfirmButton("Stoppen") { m.stop(c.id) }
                }
            }
        }
    }
}

struct PortsTab: View {
    @ObservedObject var m: Monitor
    @State private var feedback = ""

    var body: some View {
        let ports = m.snap.ports
        Header(left: "\(ports.count) offene Ports", right: "nur eigene Prozesse")
        if !feedback.isEmpty { Note(feedback) }
        ForEach(ports) { p in
            HStack(spacing: 6) {
                row(p)
                if let id = p.containerId {
                    ConfirmButton("Container stoppen", systemImage: "stop.circle") {
                        m.stop(id)
                        feedback = "Stoppe Container \(p.context ?? "")"
                    }
                } else if p.own {
                    ConfirmButton("Prozess beenden", systemImage: "xmark.circle") {
                        m.terminate(pid: p.pid)
                        feedback = "Beende \(p.title) (pid \(p.pid))"
                    }
                }
            }
        }
    }

    private func row(_ p: Port) -> some View {
            Button {
                if p.web, let url = URL(string: "http://localhost:\(p.port)") {
                    NSWorkspace.shared.open(url)
                    feedback = "Öffnet http://localhost:\(p.port)"
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("localhost:\(p.port)", forType: .string)
                    feedback = "localhost:\(p.port) kopiert"
                }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: ":\(p.port)").font(.system(.callout, design: .monospaced))
                        .foregroundStyle(p.web ? Color.accentColor : .primary)
                        .frame(width: 58, alignment: .leading)
                    Text(([p.title] + [p.context].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: p.web ? "arrow.up.right.square" : "doc.on.doc")
                        .foregroundStyle(p.web ? Color.accentColor : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
    }
}

struct SSDHealthView: View {
    let h: SMART
    let today: Double?
    let since: Date?

    var body: some View {
        let status = ["gut", "verschlissen", "Problem gemeldet"][h.level]
        var todayText = ""
        if let today, let since {
            let midnight = Calendar.current.startOfDay(for: Date())
            todayText = since.timeIntervalSince(midnight) < 1200
                ? " · heute \(Fmt.mb(today))"
                : " · \(Fmt.mb(today)) seit \(since.formatted(date: .omitted, time: .shortened))"
        }
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Gesundheit: \(status)").foregroundStyle(h.level == 0 ? Color.green : levelColor(h.level))
                Spacer()
                Text("Verschleiß \(h.percentUsed) %")
            }
            .font(.caption)
            Text("\(Fmt.tb(h.writtenBytes)) geschrieben\(todayText) · \(h.mediaErrors) Fehler")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .help("Reserve \(h.spare) % (Grenze \(h.spareThreshold) %) · \(h.powerOnHours) Betriebsstunden · "
              + "\(h.powerCycles) Einschaltvorgänge · \(h.unsafeShutdowns) unsaubere Abschaltungen · "
              + "gelesen \(Fmt.tb(h.readBytes)) · \(h.tempC) °C")
    }
}

struct TempList: View {
    let s: Snapshot

    var body: some View {
        Header(left: "Temperatur", right: Thermal.names[min(s.thermal, 4)], rightColor: s.thermal >= 1 ? .red : .secondary)
        ProcLine(title: "SoC", value: s.temps.soc.map { "\(Int($0)) °C" } ?? "–")
        ProcLine(title: "GPU", value: s.temps.gpu.map { "\(Int($0)) °C" } ?? "–")
        ProcLine(title: "SSD", value: s.temps.ssd.map { "\(Int($0)) °C" } ?? "–")
        ProcLine(title: "Akku", value: s.temps.battery.map { "\(Int($0)) °C" } ?? "–")
    }
}

/// Top-down view of a MacBook Pro 14" opened flat: the display shows the summary, the base a heat
/// field interpolated between the sensors.
struct MacHeatmap: View {
    let s: Snapshot
    let maxMHz: (e: Double?, p: Double?, gpu: Double?)
    @State private var hover: Int?

    private struct Sensor {
        let name: String
        let x: Double   // 0…1 across the base
        let y: Double   // 0…1 from hinge to front edge
        let t: Double
    }

    private static let width: CGFloat = 316
    private static let scale: CGFloat = 0.86 // fits the fixed panel height
    private static let lid = CGRect(x: 18, y: 0, width: 280, height: 192)
    private static let base = CGRect(x: 18, y: 198, width: 280, height: 192)

    // ponytail: approximate positions; Apple publishes no sensor map. tdev1–8 are guesses.
    private var sensors: [Sensor] {
        let t = s.temps
        var out: [Sensor] = []
        if let v = t.soc { out.append(Sensor(name: "SoC, CPU-Kerne", x: 0.5, y: 0.27, t: v)) }
        if let v = t.gpu { out.append(Sensor(name: "GPU", x: 0.58, y: 0.21, t: v)) }
        if let v = t.ssd { out.append(Sensor(name: "SSD", x: 0.3, y: 0.3, t: v)) }
        let devPos: [(Double, Double)] = [(0.38, 0.14), (0.62, 0.33), (0.44, 0.38), (0.08, 0.15), (0.92, 0.15), (0.7, 0.18), (0.4, 0.25), (0.56, 0.12)]
        for (i, v) in t.dev.enumerated() { if let v { out.append(Sensor(name: "Platine tdev\(i + 1)", x: devPos[i].0, y: devPos[i].1, t: v)) } }
        let cellPos: [(Double, Double)] = [(0.2, 0.66), (0.2, 0.88), (0.5, 0.66), (0.5, 0.88), (0.8, 0.66), (0.8, 0.88)]
        for (i, v) in t.cells.prefix(6).enumerated() { out.append(Sensor(name: "Akkuzelle \(i + 1)", x: cellPos[i].0, y: cellPos[i].1, t: v)) }
        return out
    }

    private static func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: base.minX + x * base.width, y: base.minY + y * base.height)
    }

    private static let ramp: [(Double, (Double, Double, Double))] = [
        (30, (0.09, 0.37, 0.65)), (50, (0.11, 0.62, 0.46)), (70, (0.94, 0.62, 0.15)), (85, (0.85, 0.35, 0.19)), (100, (0.64, 0.18, 0.18)),
    ]

    private static func heat(_ t: Double) -> Color {
        let t = min(100, max(30, t))
        for i in 1..<ramp.count where t <= ramp[i].0 {
            let (a, ca) = ramp[i - 1], (b, cb) = ramp[i]
            let f = (t - a) / (b - a)
            return Color(red: ca.0 + (cb.0 - ca.0) * f, green: ca.1 + (cb.1 - ca.1) * f, blue: ca.2 + (cb.2 - ca.2) * f)
        }
        return Color(red: 0.64, green: 0.18, blue: 0.18)
    }

    var body: some View {
        let sensors = sensors
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, _ in
                var c = ctx
                c.scaleBy(x: Self.scale, y: Self.scale)
                draw(c, sensors)
            }
                .frame(width: Self.width * Self.scale, height: (Self.base.maxY + 2) * Self.scale)
                .frame(maxWidth: .infinity)
                .onContinuousHover { phase in
                    guard case .active(let loc) = phase else { hover = nil; return }
                    let p = CGPoint(x: loc.x / Self.scale, y: loc.y / Self.scale)
                    hover = sensors.indices.min { a, b in
                        dist(p, sensors[a]) < dist(p, sensors[b])
                    }.flatMap { dist(p, sensors[$0]) < 12 ? $0 : nil }
                }
            Text(hover.map { "\(sensors[$0].name) · \(sensors[$0].t.formatted(.number.precision(.fractionLength(1)))) °C" }
                 ?? "Punkt anfahren für Sensor und Wert.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dist(_ p: CGPoint, _ s: Sensor) -> CGFloat {
        let q = Self.point(s.x, s.y)
        return hypot(p.x - q.x, p.y - q.y)
    }

    private func draw(_ ctx: GraphicsContext, _ sensors: [Sensor]) {
        let lid = Self.lid, base = Self.base
        let bezel = Color(white: 0.16)

        // Lid with display, menu bar strip and notch
        ctx.fill(Path(roundedRect: lid, cornerRadius: 12), with: .color(bezel))
        let screen = CGRect(x: lid.minX + 7, y: lid.minY + 7, width: lid.width - 14, height: lid.height - 16)
        ctx.fill(Path(roundedRect: screen, cornerRadius: 5), with: .color(Color(white: 0.06)))
        ctx.fill(Path(roundedRect: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 9), cornerRadius: 3),
                 with: .color(Color(white: 0.14)))
        ctx.fill(Path(roundedRect: CGRect(x: lid.midX - 17, y: screen.minY - 1, width: 34, height: 10), cornerRadius: 3), with: .color(bezel))

        // Summary on the display
        let socColor: Color = s.tempLevel >= 2 ? .red : s.tempLevel == 1 ? .orange : .white
        ctx.draw(Text(s.temps.soc.map { "\(Int($0)) °C" } ?? "–").font(.system(size: 34, weight: .semibold)).foregroundColor(socColor),
                 at: CGPoint(x: screen.midX, y: screen.minY + 46))
        ctx.draw(Text("SoC").font(.caption2).foregroundColor(.gray), at: CGPoint(x: screen.midX, y: screen.minY + 72))
        let parts = [s.temps.gpu.map { "GPU \(Int($0)) °C" }, s.temps.ssd.map { "SSD \(Int($0)) °C" }, s.temps.battery.map { "Akku \(Int($0)) °C" }]
        ctx.draw(Text(parts.compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundColor(Color(white: 0.75)),
                 at: CGPoint(x: screen.midX, y: screen.minY + 98))
        ctx.draw(Text("P \(Fmt.ghz(s.pMHz)) · E \(Fmt.ghz(s.eMHz)) · GPU \(Fmt.ghz(s.gpuMHz)) GHz").font(.caption).foregroundColor(Color(white: 0.75)),
                 at: CGPoint(x: screen.midX, y: screen.minY + 118))
        var throttle = Thermal.names[min(s.thermal, 4)]
        if s.lowPower { throttle += " · Stromsparmodus" }
        ctx.draw(Text(throttle).font(.caption.weight(.medium)).foregroundColor(s.thermal >= 1 ? .red : Color(white: 0.55)),
                 at: CGPoint(x: screen.midX, y: screen.minY + 146))

        // Hinge
        ctx.fill(Path(roundedRect: CGRect(x: lid.minX - 4, y: lid.maxY + 1, width: lid.width + 8, height: 4), cornerRadius: 2),
                 with: .color(Color(white: 0.45)))

        // Heat field (inverse distance weighting), clipped to the base
        ctx.drawLayer { l in
            l.clip(to: Path(roundedRect: base, cornerRadius: 12))
            guard !sensors.isEmpty else { l.fill(Path(base), with: .color(Color(white: 0.3))); return }
            let cell: CGFloat = 4
            var y = base.minY
            while y < base.maxY {
                var x = base.minX
                while x < base.maxX {
                    let nx = Double((x - base.minX) / base.width), ny = Double((y - base.minY) / base.height)
                    var num = 0.0, den = 0.0
                    for s in sensors {
                        let d2 = (nx - s.x) * (nx - s.x) + (ny - s.y) * (ny - s.y) * 0.36 + 0.0015
                        let w = 1 / (d2 * d2)
                        num += w * s.t
                        den += w
                    }
                    // Overlap by half a point so no seams show once the canvas is scaled.
                    l.fill(Path(CGRect(x: x, y: y, width: cell + 0.5, height: cell + 0.5)), with: .color(Self.heat(num / den)))
                    x += cell
                }
                y += cell
            }
        }
        ctx.stroke(Path(roundedRect: base, cornerRadius: 12), with: .color(Color(white: 0.55)), lineWidth: 1)

        // Speaker grilles
        for gx in [0.035, 0.895] {
            for i in 0..<6 {
                for j in 0..<16 {
                    let p = Self.point(gx + Double(i) * 0.0135, 0.06 + Double(j) * 0.029)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 0.9, y: p.y - 0.9, width: 1.8, height: 1.8)), with: .color(.black.opacity(0.45)))
                }
            }
        }

        // Keyboard
        let rows: [[Double]] = [
            [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
            [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], [1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.7],
            [2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.3], [1, 1, 1, 1.25, 5, 1.25, 1, 1, 1, 1],
        ]
        var ky = 0.05
        for (ri, row) in rows.enumerated() {
            let h = ri == 0 ? 0.045 : 0.07
            let total = row.reduce(0, +)
            var kx = 0.13
            for w in row {
                let kw = w / total * 0.74
                let a = Self.point(kx, ky), b = Self.point(kx + kw, ky + h)
                let key = Path(roundedRect: CGRect(x: a.x + 1, y: a.y + 1, width: b.x - a.x - 2, height: b.y - a.y - 2), cornerRadius: 2)
                ctx.fill(key, with: .color(.black.opacity(0.42)))
                ctx.stroke(key, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
                kx += kw
            }
            ky += h + 0.008
        }

        // Trackpad
        let tp0 = Self.point(0.3, 0.58), tp1 = Self.point(0.7, 0.94)
        let pad = Path(roundedRect: CGRect(x: tp0.x, y: tp0.y, width: tp1.x - tp0.x, height: tp1.y - tp0.y), cornerRadius: 6)
        ctx.fill(pad, with: .color(.white.opacity(0.08)))
        ctx.stroke(pad, with: .color(.white.opacity(0.5)), lineWidth: 0.8)

        // Sensor dots
        for (i, s) in sensors.enumerated() {
            let p = Self.point(s.x, s.y)
            let r: CGFloat = i == 0 ? 4 : 2.6
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(.white.opacity(hover == i ? 1 : 0.85)))
            ctx.stroke(dot, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        }
    }
}
