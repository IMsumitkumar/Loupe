import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var config: Config

    var body: some View {
        VStack(spacing: 0) {
            VerdictView()
            Divider()
            if !prefs.firstRunDone {
                OnboardingView()
            } else {
                if engine.moPath == nil { MoleMissingView(); Divider() }
                if engine.moleBelowFloor, let v = engine.moVersion {
                    Banner(text: "Mole \(v) is older than \(MoleAdapter.versionFloor). Update with brew upgrade mole.")
                }
                if let err = config.error {
                    Banner(text: "panels.toml could not be read (\(err)\(config.errorLine.map { ", line \($0)" } ?? "")). Showing the default panels.")
                }
                TabBar()
                // ScrollView's ideal height is its content's, so the hosting view's fittingSize
                // (read by PanelController) is the content height until the cap, then the cap.
                ScrollView(.vertical) { TabBodyView(tab: prefs.selectedTab) }
                    .frame(maxHeight: bodyCap)
                Divider()
                FooterView()
            }
        }
        .frame(width: PanelController.width)
        .animation(Palette.reduceMotion ? nil : .easeInOut(duration: 0.15), value: prefs.selectedTab)
    }

    private var bodyCap: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) * 0.7 - 210 }
}

struct TabBodyView: View {
    var tab: Int
    var body: some View {
        switch tab {
        case 1: AppsTab()
        case 2: StorageTab()
        case 3: HealthTab()
        default: OverviewTab()
        }
    }
}

/// A pure-SwiftUI segmented control for in-body choices; renders offscreen too.
struct Segments<ID: Hashable>: View {
    var items: [(ID, String)]
    @Binding var selection: ID
    var font: Font = .caption
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { id, label in
                Button {
                    selection = id
                } label: {
                    Text(label)
                        .font(font)
                        .fontWeight(selection == id ? .semibold : .regular)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(selection == id ? 0.14 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

struct TabBar: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        // Greyscale on purpose: the system segmented control paints the selection in the accent colour,
        // and colour in this panel means an alarm.
        Segments(items: [(0, "Overview"), (1, "Apps"), (2, "Storage"), (3, "Health")], selection: $prefs.selectedTab, font: .callout)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .help("⌘1 to ⌘4 switch tabs")
            .accessibilityLabel("Tabs")
    }
}

struct Banner: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

struct VerdictView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var ctx: PanelContext

    var body: some View {
        let snap = engine.snapshot
        let v = snap?.verdict
        let band = v?.band ?? "unknown"
        HStack(alignment: .top, spacing: 10) {
            StateDot(state: dotState(v)).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(machineName(snap)).font(.caption).foregroundStyle(.secondary)
                Text(v?.headline ?? "Checking your Mac…").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(v?.explanation ?? "The first reading takes a few seconds.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let c = v?.culprit, c.quitOk, let app = snap?.apps.first(where: { $0.key == c.key }) {
                        Button("Quit \(c.name)") { confirmQuit(app) }
                        Button("Show in Apps") { ctx.select(tab: 1) }
                    } else if v?.flagged == true, v?.driver == "disk" {
                        Button("Show Storage") { ctx.select(tab: 2) }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(freshness(snap)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button {
                prefs.pinned.toggle()
            } label: {
                Image(systemName: prefs.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(prefs.pinned ? "Unpin: close when clicking elsewhere" : "Pin: stay open when switching apps")
            .accessibilityLabel(prefs.pinned ? "Unpin panel" : "Pin panel")
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(v?.headline ?? "Checking")
        .accessibilityValue(v?.explanation ?? "")
        .accessibilityAddTraits(.isHeader)
    }

    /// Band colour, lifted to amber whenever a check is flagged so a warning headline never sits beside a grey dot.
    private func dotState(_ v: Verdict?) -> State3 {
        guard let v else { return .ok }
        let band = Palette.state(for: v.band)
        if band == .crit { return .crit }
        return v.flagged ? .warn : band
    }

    private func machineName(_ s: Snapshot?) -> String {
        guard let m = s?.mole else { return Host.current().localizedName ?? "This Mac" }
        let model = m.hardware.model.isEmpty ? (Host.current().localizedName ?? "This Mac") : m.hardware.model
        return m.hardware.cpuModel.isEmpty ? model : "\(model) · \(m.hardware.cpuModel)"
    }

    private func freshness(_ s: Snapshot?) -> String {
        guard let s, let last = engine.lastUpdate else { return "Waiting for the first reading" }
        let age = UInt64(max(0, Date().timeIntervalSince(last)) * 1000) + (s.moleStatus.live ? 0 : 0)
        switch s.moleStatus.state {
        case "running" where s.moleStatus.live:
            return "Last checked \(Fmt.age(age + (s.moleStatus.lastLineAgeMs ?? 0))) ago"
        case "running", "starting", "restarting":
            return "Starting the full check…"
        case "stalled":
            return "Feed dropped \(Fmt.age(s.moleStatus.lastLineAgeMs ?? age)) ago. Processor, memory and disk stay live."
        case "paused":
            return "Full check paused. Processor, memory and disk are live."
        case "missing":
            return "Mole is not installed. Showing approximate readings."
        case "failed":
            return "Mole stopped after \(s.moleStatus.failures) attempts. Showing approximate readings."
        default:
            return "Last checked \(Fmt.age(age)) ago"
        }
    }

    private func confirmQuit(_ app: App) {
        let alert = NSAlert()
        alert.messageText = "Quit \(app.name)?"
        alert.informativeText = "\(app.name) will be asked to quit normally and can save its work first."
        alert.addButton(withTitle: "Quit \(app.name)")
        alert.addButton(withTitle: "Cancel")
        if let w = ctx.window {
            alert.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { Actions.quit(app) } }
        }
    }
}

struct FooterView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        HStack {
            if engine.moPath != nil {
                Button("Clean up") { MoleAdapter.openInTerminal(["clean", "--dry-run"]) }
                    .help("Runs `mo clean --dry-run` in your terminal; Mole shows what it would remove and asks before deleting.")
            }
            Spacer()
            Button("Settings") { Actions.openSettings() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct MoleMissingView: View {
    @EnvironmentObject var engine: Engine
    var feature = "the full system check, disk scans and clean-up"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mole is not installed").font(.headline)
            Text("Loupe uses the free Mole command line tool for \(feature). Install it, then press Recheck.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(MoleAdapter.installCommand).font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                Button("Copy") { Actions.copy(MoleAdapter.installCommand) }
                Spacer()
                Link("Mole on GitHub", destination: MoleAdapter.repoURL)
                Button("Recheck") { engine.recheckMole() }
            }
            .controlSize(.small)
        }
        .padding(14)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var prefs: Prefs
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                switch page {
                case 0:
                    Text("The heartbeat in your menu bar").font(.headline)
                    HStack(spacing: 14) {
                        pulse([3, 4, 3, 5, 3, 4, 12, 3, 4, 3, 5, 3, 4, 3, 6, 3], "calm", "calm")
                        pulse([10, 40, 85, 30, 60, 95, 70, 90, 50, 88, 92, 60, 97, 80, 90, 85], "strained", "strained")
                    }
                    Text("The orange line is your processor over the last minute: flat when idle, spiky when busy. It turns red when your Mac is strained.")
                case 1:
                    Text("What amber means").font(.headline)
                    HStack(spacing: 14) {
                        HStack(spacing: 5) { StateDot(state: .ok); Text("Checked, fine") }
                        HStack(spacing: 5) { StateDot(state: .warn); Text("Worth a look") }
                        HStack(spacing: 5) { StateDot(state: .crit); Text("Needs action") }
                    }
                    .font(.callout)
                    Text("Everything is grey until a limit is crossed. Colour always comes with a word or shape, never alone.")
                default:
                    Text("Where things are").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("**Overview** · Is something wrong right now?")
                        Text("**Apps** · What is causing it?")
                        Text("**Storage** · Where did my disk go?")
                        Text("**Health** · Is my Mac in good shape?")
                    }
                    .font(.callout)
                    Text("Press ⌘1 to ⌘4 to jump between them. Escape closes the panel.")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip") { prefs.firstRunDone = true }
                Spacer()
                Text("\(page + 1) of 3").font(.caption2).foregroundStyle(.tertiary)
                if page < 2 { Button("Next") { page += 1 } } else { Button("Done") { prefs.firstRunDone = true } }
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private func pulse(_ values: [Float?], _ band: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: MenuImage.heartbeat(values: values, band: band)).frame(width: 96, height: 28)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
