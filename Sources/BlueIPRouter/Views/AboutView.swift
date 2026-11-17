import AppKit
import BlueIPRouterCore
import SwiftUI

enum AppInfo {
    static let author = "Ahora Zahedi"
    static let authorGitHub = URL(string: "https://github.com/ahorazahedi")!
    static let authorWebsite = URL(string: "https://ahora.bluedopmaine.io/")!
    static var repository: URL { URL(string: "https://github.com/\(UpdateChecker.repository)")! }
    static var issues: URL { repository.appendingPathComponent("issues") }
    static var license: URL { repository.appendingPathComponent("blob/main/LICENSE") }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BIR.version
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}

/// About page: shown in its own window (BlueIPRouter › About) and in the sidebar.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("BlueIPRouter").font(.largeTitle.weight(.semibold))
                Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            }
            Text("Per-destination routing, split tunneling and a pf kill switch for macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Created by").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Text(AppInfo.author).font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    LinkButton(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: AppInfo.authorGitHub)
                    LinkButton(title: "Website", symbol: "globe", url: AppInfo.authorWebsite)
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            HStack(spacing: 10) {
                Button {
                    Task { await model.checkForUpdates(manual: true) }
                } label: {
                    if model.checkingForUpdates { ProgressView().controlSize(.small) } else { Label("Check for Updates", systemImage: "arrow.down.circle") }
                }
                if let u = model.availableUpdate {
                    Button("Download \(u.version)") { NSWorkspace.shared.open(u.downloadURL ?? u.pageURL) }.buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 16) {
                Link("Source code", destination: AppInfo.repository)
                Link("Report an issue", destination: AppInfo.issues)
                Link("MIT License", destination: AppInfo.license)
            }
            .font(.callout)

            Text("© \(Calendar.current.component(.year, from: Date())) \(AppInfo.author). Released under the MIT License.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(compact ? 28 : 40)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
    }
}

struct LinkButton: View {
    var title: String
    var symbol: String
    var url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .help(url.absoluteString)
    }
}

/// Replaces the standard "About BlueIPRouter" menu item so it opens the custom page.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About BlueIPRouter") {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
