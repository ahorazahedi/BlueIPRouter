import BlueIPRouterCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Overview") { row(.dashboard) }
                Section("Routing") {
                    row(.rules, badge: model.pendingChanges.count)
                    row(.killSwitch, badge: model.killSwitchPending ? 1 : 0)
                    row(.routes)
                    row(.pathCheck)
                }
                Section("System") {
                    row(.adapters)
                    row(.service)
                    row(.backup)
                    row(.activity)
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            Group {
                switch model.selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .rules: RulesView()
                case .killSwitch: KillSwitchView()
                case .routes: RoutingTableView()
                case .pathCheck: PathCheckView()
                case .adapters: AdaptersView()
                case .service: ServiceView()
                case .backup: BackupView()
                case .activity: ActivityView()
                case .about: ScrollView { AboutView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let busy = model.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy.prefix(1).uppercased() + busy.dropFirst()).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await model.refresh() }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh network state (⌘R)")
                Button {
                    Task { await model.apply() }
                } label: {
                    Label(model.hasPending ? "Apply \(model.pendingCount) Change\(model.pendingCount == 1 ? "" : "s")" : "Applied",
                          systemImage: model.hasPending ? "checkmark.seal" : "checkmark.seal.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(model.hasPending ? .accentColor : .green)
                .disabled(!model.hasPending)
                .help("Write your rules to the system and update routes (⌘↩)")
            }
        }
        .sheet(isPresented: $model.showImport) { ImportRoutesSheet().environment(model) }
        .sheet(isPresented: $model.showSetup) { SetupAssistant().environment(model) }
        .sheet(item: $model.editingRule) { rule in
            RuleEditor(rule: rule).environment(model)
        }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
        .task { await model.start() }
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge)
            .tag(item)
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(serviceColor).frame(width: 8, height: 8)
                Text(serviceText).font(.caption)
            }
            if let route = model.net.internetRoute, let i = route.interface {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.caption)
                    Text("Internet via \(model.displayName(i)) (\(i))").font(.caption).lineLimit(1)
                }.foregroundStyle(.secondary)
            }
            if let ks = model.net.helperStatus?.killSwitch, ks.active {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.green)
                    Text("Kill switch armed").font(.caption)
                }
            }
            Text("Updated \(model.net.takenAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var serviceColor: Color {
        let s = model.net.service
        if s.daemonInstalled && s.loaded { return .green }
        if s.helperInstalled { return .yellow }
        return .secondary
    }

    private var serviceText: String {
        let s = model.net.service
        if s.daemonInstalled && s.loaded { return "Persistence on" }
        if s.helperInstalled { return "Persistence off" }
        return "Helper not installed"
    }
}
