import ClawPalCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var engine: CompanionEngine

    var body: some View {
        TabView {
            DisplayControlTab(engine: engine)
                .tabItem { Label("Display", systemImage: "display") }
            NfcJukeboxTab(engine: engine)
                .tabItem { Label("NFC Jukebox", systemImage: "wave.3.right.circle") }
            ActivityTab(engine: engine)
                .tabItem { Label("Activity", systemImage: "sparkles") }
            LogsTab(engine: engine)
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
        }
        .padding(14)
    }
}

// MARK: - 1. Display Control Tab

private struct DisplayControlTab: View {
    @ObservedObject var engine: CompanionEngine

    var body: some View {
        Form {
            Section("Live Screen") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(DisplayApp.allCases) { app in
                        Button {
                            engine.selectDisplayApp(app)
                        } label: {
                            HStack(spacing: 6) {
                                if app == .codex {
                                    AmpPuckIcon(size: 16)
                                } else {
                                    Image(systemName: app.symbol)
                                }
                                Text(app.label)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(engine.activeApp == app ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(!engine.status.isConnected)
                    }
                }
                if !engine.screenSwitchNote.isEmpty {
                    Text(engine.screenSwitchNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Enabled Pages & Home Carousel (up to 5 pinned)") {
                ForEach(DisplayApp.configurable) { app in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { engine.deviceSettings.isEnabled(app) },
                            set: { engine.deviceSettings.setEnabled(app, $0) }
                        )) {
                            if app == .codex {
                                HStack(spacing: 6) {
                                    AmpPuckIcon(size: 16)
                                    Text(app.label)
                                }
                            } else {
                                Label(app.label, systemImage: app.symbol)
                            }
                        }
                        Spacer()
                        let pinned = engine.deviceSettings.homeOrder.contains(app.rawValue)
                        Button {
                            engine.deviceSettings.toggleHomeSlot(app)
                        } label: {
                            Image(systemName: pinned ? "star.fill" : "star")
                                .foregroundStyle(pinned ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!engine.deviceSettings.isEnabled(app) || (!pinned && engine.deviceSettings.homeOrder.count >= 5))
                        .help("Pin to Home screen carousel (max 5)")
                    }
                }
            }

            Section("Look & Clock") {
                Picker("Theme", selection: $engine.deviceSettings.theme) {
                    ForEach(DeviceSettings.themes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Accent", selection: $engine.deviceSettings.accent) {
                    ForEach(DeviceSettings.accents, id: \.self) { Text($0).tag($0) }
                }
                Toggle("24-hour clock", isOn: $engine.deviceSettings.use24h)
                Toggle("Weather enabled", isOn: $engine.deviceSettings.weatherEnabled)
                Toggle("Fahrenheit", isOn: $engine.deviceSettings.weatherFahrenheit)
                TextField("Weather city", text: $engine.deviceSettings.city)
            }

            Section("Dimming & Night Mode") {
                Picker("Dim screen", selection: $engine.deviceSettings.dimBehavior) {
                    Text("Never").tag(0)
                    Text("When Mac is offline").tag(1)
                    Text("Always after idle").tag(2)
                }
                Stepper("Dim after \(engine.deviceSettings.dimAfterSeconds)s", value: $engine.deviceSettings.dimAfterSeconds, in: 15...3600, step: 15)
                Stepper("Dim brightness \(engine.deviceSettings.dimBrightness)%", value: $engine.deviceSettings.dimBrightness, in: 5...90, step: 5)
                Toggle("Night hours", isOn: $engine.deviceSettings.nightEnabled)
                HStack {
                    Stepper("Start \(engine.deviceSettings.nightStart):00", value: $engine.deviceSettings.nightStart, in: 0...23)
                    Spacer()
                    Stepper("End \(engine.deviceSettings.nightEnd):00", value: $engine.deviceSettings.nightEnd, in: 0...23)
                }
            }

            Section {
                HStack {
                    Button("Reload from Display") { engine.refreshDisplaySettings() }
                        .disabled(!engine.status.isConnected)
                    Spacer()
                    if !engine.settingsStatus.isEmpty {
                        Text(engine.settingsStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Save to Display") { engine.saveDisplaySettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!engine.status.isConnected || engine.isSavingSettings)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 2. NFC Jukebox Tab

private final class NfcFormModel: ObservableObject {
    @Published var uidInput = ""
    @Published var targetInput = ""
    @Published var labelInput = ""
    @Published var formMessage = ""
}

private struct NfcJukeboxTab: View {
    @ObservedObject var engine: CompanionEngine
    @StateObject private var form = NfcFormModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Reader + Last Tap Banner
            HStack(spacing: 12) {
                Image(systemName: engine.nfcDetected ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                    .font(.title2)
                    .foregroundStyle(engine.nfcDetected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.nfcDetected
                         ? String(format: "WS1850S Reader Online (0x%02x)", engine.nfcVersion)
                         : "NFC Reader status pending")
                        .font(.headline)
                    Text(engine.lastNfcUid.isEmpty
                         ? "Tap any NTAG215/216 card on the display to capture its UID."
                         : "Last tapped UID: \(engine.lastNfcUid)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !engine.lastNfcUid.isEmpty {
                    Button("Use Last UID") {
                        form.uidInput = engine.lastNfcUid
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if !engine.accessibilityTrusted {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Grant Accessibility to ClawPalMac so un-added Apple Music catalog links auto-play.")
                        .font(.caption)
                    Spacer()
                    Button("Grant Access…") {
                        engine.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                    Button("Recheck") {
                        engine.refreshAccessibilityStatus()
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Jukebox Output Speaker Routing (AirPlay for Sonos / CoreAudio for Bluetooth Echo)
            GroupBox("Jukebox Output Speaker") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Routing", selection: Binding(
                            get: { engine.jukeboxRoute.mode },
                            set: { newMode in
                                var r = engine.jukeboxRoute
                                r.mode = newMode
                                if newMode == .airplay && r.deviceName.isEmpty {
                                    r.deviceName = engine.airPlayDevices.first(where: { $0.kind != "computer" })?.name
                                        ?? engine.airPlayDevices.first?.name ?? ""
                                } else if newMode == .coreaudio && r.deviceName.isEmpty {
                                    r.deviceName = engine.coreAudioOutputs.first?.name ?? ""
                                }
                                engine.saveJukeboxRoute(r)
                            }
                        )) {
                            ForEach(AudioRouteMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Button { engine.refreshAudioDevices() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh AirPlay & Bluetooth speakers")
                    }

                    if engine.jukeboxRoute.mode == .airplay {
                        HStack {
                            Picker("AirPlay Speaker", selection: Binding(
                                get: { engine.jukeboxRoute.deviceName },
                                set: { engine.saveJukeboxRoute(JukeboxAudioRoute(mode: .airplay, deviceName: $0)) }
                            )) {
                                ForEach(engine.airPlayDevices) { dev in
                                    Text("\(dev.name)\(dev.kind == "computer" ? " (Mac)" : "")").tag(dev.name)
                                }
                            }
                            Button("Switch Now") { engine.applyJukeboxRouteNow() }
                                .controlSize(.small)
                        }
                    } else if engine.jukeboxRoute.mode == .coreaudio {
                        HStack {
                            Picker("Mac / Bluetooth Speaker", selection: Binding(
                                get: { engine.jukeboxRoute.deviceName },
                                set: { engine.saveJukeboxRoute(JukeboxAudioRoute(mode: .coreaudio, deviceName: $0)) }
                            )) {
                                ForEach(engine.coreAudioOutputs) { dev in
                                    Text("\(dev.name)\(dev.isBluetooth ? " (Bluetooth)" : "")").tag(dev.name)
                                }
                            }
                            Button("Switch Now") { engine.applyJukeboxRouteNow() }
                                .controlSize(.small)
                        }
                        Text("Pair your Amazon Echo in macOS Bluetooth Settings and click Refresh to select it here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !engine.routeStatus.isEmpty {
                        Text(engine.routeStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            // Add / Update Card Form
            GroupBox("Map NFC Card to Album or Playlist") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Card UID (tap a card, then click Use Last UID)", text: $form.uidInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        TextField("Label (optional)", text: $form.labelInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    HStack {
                        TextField("Spotify URL/URI, Apple Music URL, or Library playlist/album name", text: $form.targetInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save Card") {
                            if let err = engine.addNfcCard(uid: form.uidInput, target: form.targetInput, label: form.labelInput) {
                                form.formMessage = err
                            } else {
                                form.formMessage = "Saved!"
                                form.targetInput = ""
                                form.labelInput = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(form.uidInput.isEmpty || form.targetInput.isEmpty)
                    }
                    if !form.formMessage.isEmpty {
                        Text(form.formMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            // Mapped Cards List
            List {
                ForEach(engine.nfcCards) { card in
                    HStack(spacing: 10) {
                        Image(systemName: card.service == "spotify" ? "music.note.list" : "music.quarternote.3")
                            .foregroundStyle(card.service == "spotify" ? .green : .pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.label).font(.body.weight(.medium))
                            Text("\(card.uid) · \(card.url ?? card.uri)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Play") { engine.testPlayNfcCard(card) }
                            .controlSize(.small)
                        Button(role: .destructive) { engine.removeNfcCard(uid: card.uid) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if engine.nfcCards.isEmpty {
                    ContentUnavailableView("No NFC Cards Mapped", systemImage: "wave.3.right", description: Text("Tap a card on your ClawPal display, click Use Last UID, and paste a Spotify or Apple Music link."))
                }
            }
        }
    }
}

// MARK: - 3. Activity Tab

private final class ActivityUiModel: ObservableObject {
    @Published var expandedThreadIds: Set<String> = []
    @Published var showOtherThreads: Bool = false

    func toggleExpanded(_ id: String) {
        if expandedThreadIds.contains(id) {
            expandedThreadIds.remove(id)
        } else {
            expandedThreadIds.insert(id)
        }
    }
}

private struct ActivityTab: View {
    @ObservedObject var engine: CompanionEngine
    @StateObject private var ui = ActivityUiModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Amp Usage + Need You
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            HStack(spacing: 6) {
                                AmpPuckIcon(size: 22)
                                Text("Amp")
                                    .font(.headline)
                            }
                            if let u = engine.ampUsage {
                                Text("\(u.tier) Tier")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16))
                                    .clipShape(Capsule())
                            }
                            if !engine.ampWaitingThreads.isEmpty {
                                Text("\(engine.ampWaitingThreads.count) Need You")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.16))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            if let u = engine.ampUsage, let days = u.resetsInDays {
                                Text("Renews in \(days)d (\(u.periodEnd))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                engine.refreshAmpNow()
                            } label: {
                                Label(engine.isRefreshingAmp ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .disabled(engine.isRefreshingAmp)
                        }

                        if let u = engine.ampUsage {
                            QuotaBar(
                                title: "Agent usage",
                                detail: String(format: "$%.2f of $%.2f remaining", u.agentRemainingDollars, u.agentTotalDollars),
                                remaining: u.agentPercent
                            )
                            if let orbRem = u.orbRemainingHours, let orbTot = u.orbTotalHours, let orbPct = u.orbPercent {
                                QuotaBar(
                                    title: "Orb hours",
                                    detail: String(format: "%.1fh of %.0fh remaining", orbRem, orbTot),
                                    remaining: orbPct
                                )
                            }
                        } else {
                            Text("Waiting for `amp usage` data…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        if engine.ampWaitingThreads.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("No Amp threads waiting on you right now.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Need You (\(engine.ampWaitingThreads.count))")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(engine.ampWaitingThreads) { thread in
                                    AmpThreadRow(
                                        thread: thread,
                                        expanded: ui.expandedThreadIds.contains(thread.id),
                                        onToggle: { ui.toggleExpanded(thread.id) },
                                        onOpen: { engine.openAmpThread(thread.id) }
                                    )
                                }
                            }
                        }

                        let otherThreads = engine.ampThreads.filter { !$0.waitingOnInput }
                        if !otherThreads.isEmpty {
                            HStack {
                                Button(ui.showOtherThreads ? "Hide Other Threads" : "Show Other Threads (\(otherThreads.count))") {
                                    ui.showOtherThreads.toggle()
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                                Spacer()
                            }
                            if ui.showOtherThreads {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(otherThreads.prefix(12)) { thread in
                                        AmpThreadRow(
                                            thread: thread,
                                            expanded: ui.expandedThreadIds.contains(thread.id),
                                            onToggle: { ui.toggleExpanded(thread.id) },
                                            onOpen: { engine.openAmpThread(thread.id) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                // Claude Code
                GroupBox("Claude Code") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Toggle("Live account limits (5h / 7d)", isOn: Binding(
                                get: { engine.claudeLiveLimitsEnabled },
                                set: { engine.setClaudeLiveLimitsEnabled($0) }
                            ))
                            Spacer()
                            if let plan = engine.claudeStats?.plan, !plan.isEmpty {
                                Text("\(plan) Plan")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.16))
                                    .clipShape(Capsule())
                            }
                            Button {
                                engine.refreshClaudeNow()
                            } label: {
                                Label(engine.isRefreshingClaude ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .disabled(engine.isRefreshingClaude)
                        }
                        if !engine.claudeStatusDetail.isEmpty {
                            Text(engine.claudeStatusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let claude = engine.claudeStats {
                            if let p = claude.primary, p.available {
                                QuotaBar(title: "5-hour window", detail: nil, remaining: p.remainingPercent)
                            }
                            if let s = claude.secondary, s.available {
                                QuotaBar(title: "7-day window", detail: nil, remaining: s.remainingPercent)
                            }
                            if let items = claude.activity?.items, !items.isEmpty {
                                Divider()
                                ForEach(items) { item in
                                    TaskRow(item: item)
                                }
                            } else {
                                Text("No recent Claude Code sessions.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Claude Code hooks not active.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        }
    }
}

private struct AmpThreadRow: View {
    let thread: AmpThreadDetail
    let expanded: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if thread.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(thread.title)
                            .font(.body.weight(.medium))
                            .lineLimit(expanded ? nil : 1)
                        if !thread.project.isEmpty {
                            Text(thread.project)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    if !thread.statusMessage.isEmpty {
                        Text(thread.statusMessage)
                            .font(.caption)
                            .foregroundStyle(thread.waitingOnInput ? .orange : .secondary)
                            .lineLimit(expanded ? nil : 2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

                Spacer(minLength: 8)

                Text(Self.relativeAge(thread.attentionTimestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Open") { onOpen() }
                    .controlSize(.small)

                Button {
                    onToggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !thread.lastSnippet.isEmpty {
                        Text(thread.lastSnippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        if !thread.model.isEmpty {
                            Label(thread.model, systemImage: "cpu")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(thread.messageCount) msgs", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(thread.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(thread.waitingOnInput ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(thread.waitingOnInput ? Color.orange.opacity(0.28) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dotColor: Color {
        if thread.isWorking { return .blue }
        if thread.waitingOnInput { return .orange }
        return .secondary
    }

    private static func relativeAge(_ ts: TimeInterval) -> String {
        let diff = max(0, Int(Date().timeIntervalSince1970 - ts))
        if diff < 60 { return "\(diff)s" }
        if diff < 3600 { return "\(diff / 60)m" }
        if diff < 86_400 { return "\(diff / 3600)h" }
        return "\(diff / 86_400)d"
    }
}

private struct QuotaBar: View {
    let title: String
    let detail: String?
    let remaining: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text("· \(detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.0f%% left", remaining)).font(.caption.monospacedDigit())
            }
            ProgressView(value: remaining, total: 100)
        }
    }
}

private struct TaskRow: View {
    let item: ProviderTaskItem

    var body: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? (item.project.isEmpty ? "Session" : item.project) : item.title)
                    .font(.body)
                    .lineLimit(1)
                if !item.project.isEmpty {
                    Text(item.project)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.state)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateColor: Color {
        switch item.state {
        case "working": return .blue
        case "waiting", "interrupted": return .orange
        case "completed": return .green
        default: return .secondary
        }
    }
}

// MARK: - 4. Logs Tab

private struct LogsTab: View {
    @ObservedObject var engine: CompanionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device: \(engine.deviceId.isEmpty ? "—" : engine.deviceId) · Firmware: \(engine.firmwareVersion.isEmpty ? "—" : engine.firmwareVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { engine.logs.removeAll() }
                    .controlSize(.small)
            }
            List(engine.logs.reversed()) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.time)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}
