import AppKit
import ClawPalCore
import SwiftUI

@main
struct ClawPalMacApp: App {
    @StateObject private var engine: CompanionEngine

    init() {
        // Keep app menu-bar-only unless Dashboard window is open.
        NSApplication.shared.setActivationPolicy(.accessory)
        let eng = CompanionEngine()
        _engine = StateObject(wrappedValue: eng)
        Task { @MainActor in
            eng.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(engine: engine)
                .onAppear {
                    if !engine.isPaused && engine.status == .stopped {
                        engine.start()
                    }
                }
        } label: {
            let waiting = engine.ampWaitingThreads.count
            HStack(spacing: 3) {
                Image(systemName: menuBarSymbol)
                    .symbolRenderingMode(.hierarchical)
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("ClawPal Dashboard", id: "dashboard") {
            DashboardView(engine: engine)
                .frame(minWidth: 680, minHeight: 500)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if !engine.isPaused && engine.status == .stopped {
                        engine.start()
                    }
                }
                .onDisappear {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 740, height: 540)
    }

    private var menuBarSymbol: String {
        switch engine.status {
        case .connected: return "display"
        case .searching: return "display.trianglebadge.exclamationmark"
        case .stopped, .error: return "display.slash"
        }
    }
}
