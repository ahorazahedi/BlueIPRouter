import BlueIPRouterCore
import Charts
import SwiftUI

/// speedtest.net-style test that can run over one chosen interface (e.g. Wi-Fi directly, bypassing the VPN).
struct SpeedTestView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speedTestEngine") private var engineRaw = SpeedEngine.cloudflare.rawValue
    @AppStorage("speedTestPath") private var pathID = "direct"
    @AppStorage("speedTestLibreServer") private var libreServerID = "auto"
    @AppStorage("speedTestSkipDataWarning") private var skipWarning = false
    @State private var paths: [SpeedPath] = []
    @State private var showDataAlert = false

    private var runner: SpeedTestRunner { model.speedTest }
    private var engine: SpeedEngine { SpeedEngine(rawValue: engineRaw) ?? .cloudflare }
    private var selectedPath: SpeedPath? { paths.first { $0.id == pathID } ?? paths.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Speed Test", subtitle: "Download, upload, ping and jitter — on the connection you choose")
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
                }
                Spacer()
                if runner.isRunning {
                    Button(role: .destructive) { runner.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(width: 120, height: 34)
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
            Label("Uses roughly 100–300 MB of data per test.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
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

    private var phaseLabel: String {
        switch runner.phase {
        case .idle: return "Ready"
        case .server: return "Finding a server…"
        case .ping: return "Measuring ping…"
        case .download: return "Download"
        case .upload: return "Upload"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    private var dialCard: some View {
        let tint: Color = runner.phase == .upload ? .green : .blue
        let value: Double = {
            switch runner.phase {
            case .download, .upload: return runner.liveMbps
            case .done: return runner.downloadMbps ?? 0
            default: return 0
            }
        }()
        return Card {
            VStack(spacing: 10) {
                SpeedDial(mbps: value, tint: tint, active: runner.isRunning)
                    .frame(width: 260, height: 220)
                Text(phaseLabel).font(.headline).foregroundStyle(runner.phase == .failed ? .red : .secondary)
                if runner.isRunning {
                    ProgressView(value: runner.progress).frame(width: 220)
                }
                if let s = runner.serverName { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let e = runner.error {
                    Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 280)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 360)
    }

    // MARK: Results

    private var resultsCard: some View {
        Card("Result", symbol: "gauge.with.needle") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                metric("arrow.down.circle.fill", "Download", runner.downloadMbps.map(mbps) ?? "—", "Mbps", .blue)
                metric("arrow.up.circle.fill", "Upload", runner.uploadMbps.map(mbps) ?? "—", "Mbps", .green)
                metric("timer", "Ping", runner.pingMs.map { String(format: "%.0f", $0) } ?? "—", "ms", .orange)
                metric("waveform.path", "Jitter", runner.jitterMs.map { String(format: "%.1f", $0) } ?? "—", "ms", .purple)
                metric("hourglass", "Ping under load", runner.loadedPingMs.map { String(format: "%.0f", $0) } ?? "—", "ms", .pink)
                metric("chart.bar", "Bufferbloat", bufferbloat, "", bufferbloatColor)
            }
            Divider()
            if let id = runner.identity {
                HStack(spacing: 8) {
                    if let f = id.flag { Text(f).font(.title2) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id.ip).font(.body.monospaced()).textSelection(.enabled)
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

    private func mbps(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }

    private var bufferbloat: String {
        guard let idle = runner.pingMs, let loaded = runner.loadedPingMs else { return "—" }
        let extra = loaded - idle
        switch extra {
        case ..<30: return "A  +\(Int(extra)) ms"
        case ..<100: return "B  +\(Int(extra)) ms"
        case ..<300: return "C  +\(Int(extra)) ms"
        default: return "D  +\(Int(extra)) ms"
        }
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
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
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
                    PointMark(x: .value("Date", r.date), y: .value("Mbps", r.downloadMbps))
                        .foregroundStyle(by: .value("Connection", r.pathTitle))
                        .symbol(by: .value("Connection", r.pathTitle))
                    LineMark(x: .value("Date", r.date), y: .value("Mbps", r.downloadMbps))
                        .foregroundStyle(by: .value("Connection", r.pathTitle))
                }
                .chartYAxisLabel("Download (Mbps)")
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
                            Text("\(r.engine.title)").font(.caption).foregroundStyle(.secondary)
                            Text("\(mbps(r.downloadMbps)) Mbps").monospacedDigit()
                            Text("\(mbps(r.uploadMbps)) Mbps").monospacedDigit()
                            Text("\(Int(r.pingMs)) ms").monospacedDigit()
                            Text("\(r.flag ?? "") \(r.publicIP ?? "—")").font(.caption.monospaced())
                        }
                    }
                }
            }
        }
    }
}

/// Arc gauge on a logarithmic scale up to 1 Gbps.
struct SpeedDial: View {
    var mbps: Double
    var tint: Color
    var active: Bool

    private var fraction: Double {
        guard mbps > 0 else { return 0 }
        return min(1, log10(1 + mbps) / log10(1001))
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(AngularGradient(colors: [tint.opacity(0.6), tint], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.3), value: fraction)
            ForEach([1.0, 10, 100, 1000], id: \.self) { mark in
                let f = log10(1 + mark) / log10(1001)
                let angle = Angle.degrees(135 + 270 * f)
                Text(mark >= 1000 ? "1G" : "\(Int(mark))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .offset(x: cos(angle.radians) * 82, y: sin(angle.radians) * 82)
            }
            VStack(spacing: 0) {
                Text(mbps >= 100 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps))
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("Mbps").font(.callout).foregroundStyle(.secondary)
            }
            .opacity(active || mbps > 0 ? 1 : 0.4)
        }
        .padding(12)
    }
}
