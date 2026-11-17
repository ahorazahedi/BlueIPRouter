import BlueIPRouterCore
import Charts
import SwiftUI

// MARK: - Units

enum SpeedUnit: String, CaseIterable, Identifiable {
    case mbps, mBps
    var id: String { rawValue }
    var label: String { self == .mbps ? "Mbps" : "MB/s" }
    var other: SpeedUnit { self == .mbps ? .mBps : .mbps }

    /// Converts megabits per second into this unit (1 MB/s = 8 Mbps).
    func value(_ megabits: Double) -> Double { self == .mbps ? megabits : megabits / 8 }

    func format(_ megabits: Double) -> String {
        let v = value(megabits)
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

/// speedtest.net-style test that can run over one chosen interface (e.g. Wi-Fi directly, bypassing the VPN).
struct SpeedTestView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speedTestEngine") private var engineRaw = SpeedEngine.cloudflare.rawValue
    @AppStorage("speedTestPath") private var pathID = "direct"
    @AppStorage("speedTestLibreServer") private var libreServerID = "auto"
    @AppStorage("speedTestSkipDataWarning") private var skipWarning = false
    @AppStorage("speedTestUnit") private var unitRaw = SpeedUnit.mbps.rawValue
    @State private var paths: [SpeedPath] = []
    @State private var showDataAlert = false

    private var runner: SpeedTestRunner { model.speedTest }
    private var engine: SpeedEngine { SpeedEngine(rawValue: engineRaw) ?? .cloudflare }
    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .mbps }
    private var selectedPath: SpeedPath? { paths.first { $0.id == pathID } ?? paths.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Speed Test", subtitle: "Download, upload, ping and jitter — on the connection you choose") {
                    Picker("Unit", selection: $unitRaw) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Megabits per second (what ISPs advertise) or megabytes per second (what file downloads show). 1 MB/s = 8 Mbps.")
                }
                controls
                HStack(alignment: .top, spacing: 16) {
                    dialCard
                    resultsCard
                }
                historyCard
            }
            .padding(24)
        }
        .task {
            paths = await model.speedTestPaths()
            if engine == .libreSpeed { await runner.loadLibreServers() }
        }
        .onChange(of: engineRaw) { _, _ in
            if engine == .libreSpeed { Task { await runner.loadLibreServers() } }
        }
        .alert("This test uses a lot of data", isPresented: $showDataAlert) {
            Button("Start Test") { begin() }
            Button("Start and Don't Ask Again") { skipWarning = true; begin() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A speed test uses roughly 100–300 MB of data (more on very fast connections). If \(selectedPath?.title ?? "this connection") is metered or goes through a VPN with a data limit, that usage counts against it.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Connection", selection: $pathID) {
                        ForEach(paths) { p in Text(p.title).tag(p.id) }
                    }
                    .frame(maxWidth: 520)
                    if let p = selectedPath {
                        Text(p.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Picker("Server", selection: $engineRaw) {
                            ForEach(SpeedEngine.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        if engine == .libreSpeed {
                            Picker("", selection: $libreServerID) {
                                Text("Fastest server (automatic)").tag("auto")
                                ForEach(runner.libreServers) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 320)
                            if runner.libreServers.isEmpty { ProgressView().controlSize(.small) }
                        }
                    }
                    Label("Uses roughly 100–300 MB of data per test.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                .disabled(runner.isRunning)
                Spacer()
                if runner.isRunning {
                    Button(role: .destructive) { runner.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(width: 140, height: 34)
                    }
                    .controlSize(.large)
                } else {
                    Button { requestStart() } label: {
                        Label(runner.phase == .done ? "Test Again" : "Start Test", systemImage: "speedometer").frame(width: 150, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedPath == nil)
                }
            }
        }
    }

    private func requestStart() {
        if skipWarning { begin() } else { showDataAlert = true }
    }

    private func begin() {
        guard let p = selectedPath else { return }
        runner.start(engine: engine, libreServerID: libreServerID == "auto" ? nil : libreServerID, path: p,
                     geo: model.workspace.settings.geoProvider)
        model.log("Speed test started", ok: true, "\(engine.title) on \(p.title)")
    }

    // MARK: Dial

    private var dialStyle: SpeedDial.Style {
        switch runner.phase {
        case .upload: return .upload
        case .done: return .done
        case .failed, .cancelled: return .idle
        default: return .download
        }
    }

    private var dialValue: Double {
        switch runner.phase {
        case .download, .upload: return runner.liveMbps
        case .done: return runner.downloadMbps ?? 0
        default: return 0
        }
    }

    private var statusText: String {
        switch runner.phase {
        case .idle: return "Ready when you are"
        case .server: return "Finding a server…"
        case .ping: return "Measuring ping…"
        case .download: return "Testing download…"
        case .upload: return "Testing upload…"
        case .done: return "Download result"
        case .failed: return "Test failed"
        case .cancelled: return "Stopped"
        }
    }

    private var dialCard: some View {
        let live = runner.phase == .download || runner.phase == .upload
        let spark: [Double] = live ? runner.samples : (runner.phase == .done ? runner.downloadSamples : [])
        return Card {
            VStack(spacing: 14) {
                PhaseSteps(phase: runner.phase)
                SpeedDial(mbps: dialValue, unit: unit, style: dialStyle, active: runner.isRunning)
                    .frame(width: 320, height: 300)
                VStack(spacing: 4) {
                    Text(statusText)
                        .font(.headline)
                        .foregroundStyle(runner.phase == .failed ? Color.red : (runner.isRunning ? dialStyle.color : Color.secondary))
                    if let s = runner.serverName {
                        Label(s, systemImage: "server.rack").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !spark.isEmpty {
                    Sparkline(values: spark, color: runner.phase == .upload ? SpeedDial.Style.upload.color : SpeedDial.Style.download.color)
                        .frame(height: 46)
                }
                if runner.isRunning {
                    ProgressView(value: runner.progress).tint(dialStyle.color)
                }
                if let e = runner.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 400)
    }

    // MARK: Results

    private var resultsCard: some View {
        Card("Result", symbol: "gauge.with.needle") {
            HStack(spacing: 12) {
                speedTile("arrow.down", "Download", runner.downloadMbps, SpeedDial.Style.download.color, highlight: runner.phase == .download)
                speedTile("arrow.up", "Upload", runner.uploadMbps, SpeedDial.Style.upload.color, highlight: runner.phase == .upload)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                metric("timer", "Ping", runner.pingMs.map { String(format: "%.0f", $0) } ?? "—", "ms", .orange)
                metric("waveform.path", "Jitter", runner.jitterMs.map { String(format: "%.1f", $0) } ?? "—", "ms", .purple)
                metric("hourglass", "Ping under load", runner.loadedPingMs.map { String(format: "%.0f", $0) } ?? "—", "ms", .pink)
                metric("chart.bar.fill", "Bufferbloat", bufferbloat, "", bufferbloatColor)
            }
            Divider()
            if let id = runner.identity {
                HStack(spacing: 10) {
                    if let f = id.flag { Text(f).font(.system(size: 30)) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id.ip).font(.body.monospaced().weight(.medium)).textSelection(.enabled)
                        Text([id.location, id.org ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(runner.isRunning ? "Looking up the public IP of this connection…" : "The public IP of the tested connection appears here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func speedTile(_ symbol: String, _ title: String, _ megabits: Double?, _ tint: Color, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tint))
                Text(title).font(.callout.weight(.medium)).foregroundStyle(tint)
                if highlight { ProgressView().controlSize(.mini) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(megabits.map { unit.format($0) } ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit.label).font(.callout).foregroundStyle(.secondary)
            }
            Text(megabits.map { "\(unit.other.format($0)) \(unit.other.label)" } ?? " ")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(highlight ? 0.7 : 0.2), lineWidth: highlight ? 1.5 : 1))
    }

    private var bufferbloat: String {
        guard let idle = runner.pingMs, let loaded = runner.loadedPingMs else { return "—" }
        let extra = max(0, loaded - idle)
        let grade = extra < 30 ? "A" : (extra < 100 ? "B" : (extra < 300 ? "C" : "D"))
        return "\(grade)  +\(Int(extra)) ms"
    }

    private var bufferbloatColor: Color {
        guard let idle = runner.pingMs, let loaded = runner.loadedPingMs else { return .secondary }
        let extra = loaded - idle
        return extra < 30 ? .green : (extra < 100 ? .yellow : .red)
    }

    private func metric(_ symbol: String, _ title: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
    }

    // MARK: History

    private var historyCard: some View {
        Card("History", symbol: "clock.arrow.circlepath",
             trailing: AnyView(Button("Clear") {
                 runner.history.removeAll()
                 SpeedHistoryStore.save([])
             }.disabled(runner.history.isEmpty))) {
            if runner.history.isEmpty {
                Text("Past results appear here, so you can compare the VPN and the direct connection over time.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(runner.history.suffix(40)) { r in
                    PointMark(x: .value("Date", r.date), y: .value(unit.label, unit.value(r.downloadMbps)))
                        .foregroundStyle(by: .value("Connection", r.pathTitle))
                        .symbol(by: .value("Connection", r.pathTitle))
                    LineMark(x: .value("Date", r.date), y: .value(unit.label, unit.value(r.downloadMbps)))
                        .foregroundStyle(by: .value("Connection", r.pathTitle))
                }
                .chartYAxisLabel("Download (\(unit.label))")
                .chartLegend(position: .bottom)
                .frame(height: 200)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("When"); Text("Connection"); Text("Server"); Text("Down"); Text("Up"); Text("Ping"); Text("IP")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(runner.history.suffix(15).reversed()) { r in
                        GridRow {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            Text(r.pathTitle).font(.caption).lineLimit(1)
                            Text(r.engine.title).font(.caption).foregroundStyle(.secondary)
                            Text("\(unit.format(r.downloadMbps)) \(unit.label)").monospacedDigit()
                            Text("\(unit.format(r.uploadMbps)) \(unit.label)").monospacedDigit()
                            Text("\(Int(r.pingMs)) ms").monospacedDigit()
                            Text("\(r.flag ?? "") \(r.publicIP ?? "—")").font(.caption.monospaced())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Phase steps

struct PhaseSteps: View {
    var phase: SpeedTestRunner.Phase

    private let steps: [(SpeedTestRunner.Phase, String, String)] = [
        (.ping, "Ping", "timer"), (.download, "Download", "arrow.down"), (.upload, "Upload", "arrow.up"),
    ]

    private func state(_ step: SpeedTestRunner.Phase) -> Int {
        let order: [SpeedTestRunner.Phase] = [.server, .ping, .download, .upload, .done]
        guard let current = order.firstIndex(of: phase), let s = order.firstIndex(of: step) else { return 0 }
        if phase == .done || current > s { return 2 }
        return current == s ? 1 : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let st = state(step.0)
                HStack(spacing: 5) {
                    Image(systemName: st == 2 ? "checkmark.circle.fill" : step.2)
                        .foregroundStyle(st == 0 ? Color.secondary : (st == 2 ? Color.green : Color.accentColor))
                    Text(step.1).font(.caption.weight(.medium))
                        .foregroundStyle(st == 0 ? Color.secondary : Color.primary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(st == 1 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                if index < steps.count - 1 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 14, height: 1)
                }
            }
        }
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", v))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("t", i), y: .value("v", v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(10, values.count - 1))
    }
}

// MARK: - Gauge

/// Speedometer gauge: 270° arc on a logarithmic scale to 1 Gbps, gradient fill with glow, tick marks and a needle.
struct SpeedDial: View {
    enum Style {
        case idle, download, upload, done
        var colors: [Color] {
            switch self {
            case .idle: return [.gray.opacity(0.5), .gray]
            case .download: return [Color(red: 0.20, green: 0.80, blue: 0.95), Color(red: 0.25, green: 0.45, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 1.0)]
            case .upload: return [Color(red: 0.55, green: 0.95, blue: 0.55), Color(red: 0.15, green: 0.80, blue: 0.55), Color(red: 0.05, green: 0.65, blue: 0.70)]
            case .done: return [Color(red: 0.20, green: 0.80, blue: 0.95), Color(red: 0.25, green: 0.45, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 1.0)]
            }
        }
        var color: Color { colors[colors.count / 2] }
    }

    var mbps: Double
    var unit: SpeedUnit
    var style: Style
    var active: Bool

    /// Scale marks in Mbps, chosen so each unit shows round numbers.
    static let mbpsMarks: [Double] = [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]
    static let mBpsMarks: [Double] = [0, 0.1, 0.5, 1, 2.5, 5, 10, 25, 50, 125].map { $0 * 8 }
    private var marks: [Double] { unit == .mbps ? Self.mbpsMarks : Self.mBpsMarks }
    private static let start = 135.0
    private static let sweep = 270.0

    static func fraction(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        return min(1, log10(1 + v) / log10(1001))
    }

    private func label(_ mark: Double) -> String {
        let v = unit.value(mark)
        if unit == .mbps { return mark >= 1000 ? "1G" : "\(Int(mark))" }
        if v > 0 && v < 1 { return String(format: "%.1f", v) }
        return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - 22
            let f = Self.fraction(mbps)
            ZStack {
                // Soft backdrop
                Circle()
                    .fill(RadialGradient(colors: [style.color.opacity(active ? 0.16 : 0.07), .clear],
                                         center: .center, startRadius: 0, endRadius: size / 2))

                // Track
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(Self.start))
                    .frame(width: radius * 2, height: radius * 2)

                // Glow + value arc
                Circle()
                    .trim(from: 0, to: 0.75 * f)
                    .stroke(AngularGradient(colors: style.colors, center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(Self.start))
                    .frame(width: radius * 2, height: radius * 2)
                    .blur(radius: 10)
                    .opacity(active ? 0.8 : 0.4)
                Circle()
                    .trim(from: 0, to: 0.75 * f)
                    .stroke(AngularGradient(colors: style.colors, center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(Self.start))
                    .frame(width: radius * 2, height: radius * 2)

                // Ticks: fine ticks all round, long ticks exactly at the labelled values.
                Canvas { ctx, sz in
                    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                    func tick(_ t: Double, major: Bool) {
                        let a = Angle.degrees(Self.start + Self.sweep * t).radians
                        let r1 = radius - 16, r2 = radius - (major ? 27 : 21)
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
                        let lit = t <= f + 0.0001 && f > 0
                        ctx.stroke(p, with: .color(lit ? style.color.opacity(major ? 1 : 0.8) : Color.primary.opacity(major ? 0.4 : 0.14)),
                                   lineWidth: major ? 2.2 : 1)
                    }
                    for i in 0...60 { tick(Double(i) / 60, major: false) }
                    for m in marks { tick(Self.fraction(m), major: true) }
                }

                // Scale labels
                ForEach(marks, id: \.self) { mark in
                    let a = Angle.degrees(Self.start + Self.sweep * Self.fraction(mark)).radians
                    Text(label(mark))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Self.fraction(mark) <= f ? Color.primary : Color.secondary)
                        .offset(x: cos(a) * (radius - 42), y: sin(a) * (radius - 42))
                }

                // Needle
                Needle()
                    .fill(LinearGradient(colors: [style.color, style.color.opacity(0.2)], startPoint: .trailing, endPoint: .leading))
                    .frame(width: radius - 30, height: 10)
                    .offset(x: (radius - 30) / 2)
                    .rotationEffect(.degrees(Self.start + Self.sweep * f))
                    .shadow(color: style.color.opacity(0.6), radius: 6)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: f)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(style.color, lineWidth: 3))

                // Readout
                VStack(spacing: 2) {
                    Text(unit.format(mbps))
                        .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: mbps))
                        .animation(.easeOut(duration: 0.25), value: mbps)
                    Text(unit.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(unit.other.format(mbps)) \(unit.other.label)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .offset(y: radius * 0.62)
                .opacity(active || mbps > 0 ? 1 : 0.45)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Tapered needle pointing right; rotated into place by the gauge.
struct Needle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY - rect.height / 2))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - 1))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + 1))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY + rect.height / 2))
        p.closeSubpath()
        return p
    }
}
