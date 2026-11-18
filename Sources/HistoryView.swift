import Charts
import SwiftUI

/// Window with five stacked charts on a shared time axis. Hovering shows all values and the top
/// process at that moment.
struct HistoryView: View {
    @ObservedObject var m: Monitor
    @State private var minutes = 1440
    @State private var selected: Date?

    private struct Metric: Identifiable {
        let id: String
        let key: KeyPath<Point, Double>
        let unit: String
        var warn: Double?
        var crit: Double?
    }

    var body: some View {
        let cores = Double(m.snap.cores)
        let metrics = [
            Metric(id: "Last", key: \.load, unit: "", warn: cores * Limits.loadWarnFactor, crit: cores * Limits.loadCritFactor),
            Metric(id: "Speicher", key: \.mem, unit: " %"),
            Metric(id: "SSD", key: \.ssd, unit: " MB/s", warn: Limits.diskMBps),
            Metric(id: "GPU", key: \.gpu, unit: " %"),
            Metric(id: "SoC", key: \.temp, unit: " °C", warn: Limits.hotTemp),
        ]
        let end = Date()
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        // Minute averages, continued by the live samples since the last full minute.
        let stored = m.history.minutes.filter { $0.t >= start }
        let live = m.history.recent.filter { $0.t > (stored.last?.t.addingTimeInterval(60) ?? start) }
        let points = minutes == 15 ? m.history.recent : stored + live

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Verlauf").font(.headline)
                Spacer()
                Picker("", selection: $minutes) {
                    Text("15 Min").tag(15)
                    Text("1 h").tag(60)
                    Text("24 h").tag(1440)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if points.isEmpty {
                Text("Noch keine Daten. Der Verlauf speichert einen Wert pro Minute; 15 Min zeigt sofort etwas.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(metrics) { metric in
                    HStack(alignment: .top) {
                        Text(metric.id).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        chart(metric, points, start...end, showAxis: metric.id == metrics.last?.id)
                    }
                }
                detail(points, metrics)
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 480)
    }

    private func chart(_ metric: Metric, _ points: [Point], _ domain: ClosedRange<Date>, showAxis: Bool) -> some View {
        Chart {
            ForEach(points) { LineMark(x: .value("Zeit", $0.t), y: .value(metric.id, $0[keyPath: metric.key])) }
            if let w = metric.warn {
                RuleMark(y: .value("warn", w)).foregroundStyle(.orange.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
            if let c = metric.crit {
                RuleMark(y: .value("crit", c)).foregroundStyle(.red.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
            if let selected {
                RuleMark(x: .value("Auswahl", selected)).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            if showAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
        .chartYAxis {
            // Fixed label width keeps the plot areas, and so the time axes, aligned across charts.
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text(value.as(Double.self).map { "\(Int($0))" } ?? "").frame(width: 32, alignment: .leading)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let frame = proxy.plotFrame else { return }
                            selected = proxy.value(atX: p.x - geo[frame].origin.x, as: Date.self)
                        case .ended:
                            selected = nil
                        }
                    }
            }
        }
        .frame(height: showAxis ? 86 : 66)
    }

    @ViewBuilder
    private func detail(_ points: [Point], _ metrics: [Metric]) -> some View {
        let p = selected.flatMap { sel in points.min { abs($0.t.timeIntervalSince(sel)) < abs($1.t.timeIntervalSince(sel)) } }
        VStack(alignment: .leading, spacing: 2) {
            if let p {
                Text(p.t.formatted(date: .omitted, time: .shortened) + " · "
                     + metrics.map { "\($0.id) \(Int(p[keyPath: $0.key].rounded()))\($0.unit)" }.joined(separator: " · "))
                Text("Größter Verbraucher: \(p.top.isEmpty ? "–" : p.top)").foregroundStyle(.secondary)
            } else {
                Text("Mit der Maus über die Kurven fahren: Werte und größter Verbraucher zum Zeitpunkt.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
