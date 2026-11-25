import AppKit
import ClawPalCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var engine: CompanionEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header + Status
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClawPal")
                        .font(.headline)
                    Text(engine.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(engine.isPaused ? "Resume" : "Pause") {
                    engine.togglePause()
                }
                .controlSize(.small)
            }

            Divider()

            // Quick Screen Switcher
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Display Screen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let active = engine.activeApp {
                        Text(active.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach([DisplayApp.home, .monitor, .music, .codex, .claude, .clock], id: \.id) { app in
                        Button {
                            engine.selectDisplayApp(app)
                        } label: {
                            HStack(spacing: 4) {
                                if app == .codex {
                                    AmpPuckIcon(size: 13)
                                } else {
                                    Image(systemName: app.symbol)
                                        .font(.caption2)
                                }
                                Text(shortName(app))
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(engine.activeApp == app ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(!engine.status.isConnected)
                    }
                }
                if !engine.screenSwitchNote.isEmpty {
                    Text(engine.screenSwitchNote)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            // System + Now Playing
            HStack(spacing: 12) {
                Label(String(format: "CPU %.0f%%", engine.cpuUsage), systemImage: "cpu")
                    .font(.caption)
                Label(String(format: "RAM %.0f%%", engine.memoryUsage), systemImage: "memorychip")
                    .font(.caption)
                Spacer()
                if engine.nfcDetected {
                    Label("NFC", systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if engine.music.available {
                HStack(spacing: 10) {
                    if let data = engine.coverImageData, let nsImg = NSImage(data: data) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.music.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(engine.music.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Button { engine.mediaAction("previous") } label: { Image(systemName: "backward.fill") }
                        Button { engine.mediaAction("play_pause") } label: {
                            Image(systemName: engine.music.playing ? "pause.fill" : "play.fill")
                        }
                        Button { engine.mediaAction("next") } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Amp Need You quick list
            if !engine.ampWaitingThreads.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AmpPuckIcon(size: 16)
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                        Text("\(engine.ampWaitingThreads.count) Amp \(engine.ampWaitingThreads.count == 1 ? "thread needs" : "threads need") you")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button {
                            engine.refreshAmpNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.isRefreshingAmp)
                    }
                    ForEach(engine.ampWaitingThreads.prefix(3)) { thread in
                        Button {
                            engine.openAmpThread(thread.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(thread.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    if !thread.project.isEmpty {
                                        Text(thread.project)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                if !thread.statusMessage.isEmpty {
                                    Text(thread.statusMessage)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    if engine.ampWaitingThreads.count > 3 {
                        Button("View all \(engine.ampWaitingThreads.count) in Dashboard…") {
                            openWindow(id: "dashboard")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                    }
                }
            }

            // Activity summary
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    AmpPuckIcon(size: 13)
                    if let u = engine.ampUsage {
                        Text(String(format: "$%.2f left", u.agentRemainingDollars))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Amp: \(engine.ampThreads.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                let claudeText: String = {
                    if let c = engine.claudeStats, c.available {
                        let pAvail = c.primary?.available == true ? c.primary : nil
                        let sAvail = c.secondary?.available == true ? c.secondary : nil
                        if let p = pAvail, let s = sAvail {
                            return String(format: "Claude: %.0f%% / %.0f%%", p.remainingPercent, s.remainingPercent)
                        }
                        if let p = pAvail {
                            return String(format: "Claude: %.0f%% (5h)", p.remainingPercent)
                        }
                        if let s = sAvail {
                            return String(format: "Claude: %.0f%% (7d)", s.remainingPercent)
                        }
                    }
                    return "Claude: \(engine.claudeStats?.activity?.totalCount ?? 0)"
                }()
                Label(claudeText, systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !engine.lastNfcUid.isEmpty {
                    Text("Card: \(engine.lastNfcUid.suffix(6))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Open Dashboard…") {
                    openWindow(id: "dashboard")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    private var statusColor: Color {
        switch engine.status {
        case .connected: return .green
        case .searching: return .orange
        case .stopped: return .gray
        case .error: return .red
        }
    }

    private func shortName(_ app: DisplayApp) -> String {
        switch app {
        case .monitor: return "Stats"
        case .codex: return "Amp"
        case .claude: return "Claude"
        default: return app.label
        }
    }
}
