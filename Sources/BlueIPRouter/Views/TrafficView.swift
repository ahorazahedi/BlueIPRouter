import BlueIPRouterCore
import Charts
import SwiftUI

/// Per-interface traffic over time: how much goes through the VPN tunnel, Wi-Fi and other links.
struct TrafficView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .hour
    @State private var direction: Direction = .both

    enum Range: String, CaseIterable, Identifiable {
        case fifteen = "15 min", hour = "1 hour", day = "24 hours", week = "7 days"
        var id: String { rawValue }
        var title: String { L10n.tr(rawValue) }
        var seconds: TimeInterval {
            switch self {
            case .fifteen: return 900
            case .hour: return 3600
            case .day: return 86400
            case .week: return 7 * 86400
            }
        }
        var usesMinutes: Bool { self == .day || self == .week }
    }

    enum Direction: String, CaseIterable, Identifiable {
        case both = "Down + up", down = "Download", up = "Upload"
        var id: String { rawValue }
        var title: String { L10n.tr(rawValue) }
    }

    struct Point: Identifiable {
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
        var date: Date
        var series: String
        var value: Double
    }

    private var interfaces: [String] {
        let source = range.usesMinutes ? model.traffic.minutes : model.traffic.recent
        return source.keys.filter { name in
            let info = model.interface(name)
            return !(info?.isSystemNoise ?? true) || info?.isFullTunnel == true || name.hasPrefix("ppp")
        }.sorted()
    }

    private func samples(_ name: String) -> [TrafficSample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let source = range.usesMinutes ? model.traffic.minutes[name] : model.traffic.recent[name]
        return (source ?? []).filter { $0.date >= cutoff }
    }

    /// Bytes per second for the chart (minute buckets hold bytes, so divide by 60).
    private func rate(_ s: TrafficSample) -> Double {
        let scale = range.usesMinutes ? 1.0 / 60 : 1
        switch direction {
        case .both: return (s.rx + s.tx) * scale
        case .down: return s.rx * scale
        case .up: return s.tx * scale
        }
    }

    /// Total bytes moved in the range.
    private func total(_ name: String) -> (rx: Double, tx: Double) {
        let list = samples(name)
        if range.usesMinutes { return (list.reduce(0) { $0 + $1.rx }, list.reduce(0) { $0 + $1.tx }) }
        let step = model.workspace.settings.refreshSeconds
        return (list.reduce(0) { $0 + $1.rx * step }, list.reduce(0) { $0 + $1.tx * step })
    }

    private var points: [Point] {
        interfaces.flatMap { name in
            samples(name).map { Point(date: $0.date, series: "\(model.displayName(name)) (\(name))", value: rate($0)) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Traffic"), subtitle: L10n.tr("How much data each interface carries over time")) {
                    HStack {
                        Picker("", selection: $direction) { ForEach(Direction.allCases) { Text($0.title).tag($0) } }
                            .frame(width: 140).labelsHidden()
                        Picker("", selection: $range) { ForEach(Range.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).frame(width: 320).labelsHidden()
                    }
                }
                Card(L10n.tr("Throughput"), symbol: "chart.xyaxis.line") {
                    if points.isEmpty {
                        Text(range.usesMinutes ? L10n.tr("Minute totals appear after the app has been running for a few minutes.")
                                               : L10n.tr("Collecting… samples are taken every %lld seconds.", Int(model.workspace.settings.refreshSeconds)))
                            .foregroundStyle(.secondary).frame(height: 260)
                    } else {
                        Chart(points) { p in
                            AreaMark(x: .value(L10n.tr("Time"), p.date), y: .value(L10n.tr("Rate"), p.value), stacking: .standard)
                                .foregroundStyle(by: .value(L10n.tr("Interface"), p.series))
                                .interpolationMethod(.monotone)
                                .opacity(0.75)
                        }
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel { if let d = v.as(Double.self) { Text(formatRate(d)) } }
                            }
                        }
                        .chartLegend(position: .bottom)
                        .frame(height: 280)
                    }
                }
                Card(L10n.tr("Totals for the last %@", range.title), symbol: "sum") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        GridRow {
                            Text(L10n.tr("Interface")); Text(L10n.tr("Downloaded")); Text(L10n.tr("Uploaded")); Text(L10n.tr("Share"))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let totals = interfaces.map { ($0, total($0)) }
                        let sum = max(1, totals.reduce(0) { $0 + $1.1.rx + $1.1.tx })
                        ForEach(totals, id: \.0) { name, t in
                            GridRow {
                                HStack(spacing: 6) {
                                    Image(systemName: model.interface(name)?.kind.symbol ?? "network").foregroundStyle(.secondary).frame(width: 18)
                                    Text("\(model.displayName(name)) (\(name))")
                                }
                                Text(formatBytes(UInt64(t.rx))).monospacedDigit()
                                Text(formatBytes(UInt64(t.tx))).monospacedDigit()
                                Gauge(value: (t.rx + t.tx) / sum) { EmptyView() }
                                    .gaugeStyle(.accessoryLinearCapacity).frame(width: 140)
                            }
                        }
                    }
                    Text(L10n.tr("Measured while BlueIPRouter is running (including in the menu bar). The last 7 days are kept on this Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }
}
