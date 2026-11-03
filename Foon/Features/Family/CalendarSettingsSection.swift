import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Family, for planners: calendar awareness on this device (#64). Off until turned on here; turning it on is what asks
/// for calendar access, and turning it off stops reading at once.
struct CalendarSettingsSection: View {
    @Environment(CalendarBusyStore.self) private var calendarBusy: CalendarBusyStore?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let calendarBusy {
            section(calendarBusy)
                .task { calendarBusy.checkAccess() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { calendarBusy.checkAccess() }
                }
                #if os(macOS)
                // A Mac app stays active while System Settings is in front, so its return is noticed here instead.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    calendarBusy.checkAccess()
                }
                #endif
        }
    }

    private func section(_ store: CalendarBusyStore) -> some View {
        Section {
            if store.access == .refused {
                Link(destination: Self.settingsURL) {
                    Label("Foon can't see your calendar. Allow it in Settings.",
                          systemImage: "calendar.badge.exclamationmark")
                }
            } else {
                Toggle("Spot busy evenings", systemImage: "calendar.badge.clock", isOn: Binding(
                    get: { store.isOn },
                    set: { on in
                        if on { Task { await store.turnOn() } } else { store.turnOff() }
                    }
                ))
            }
        } footer: {
            Text("Looks at this device's calendar for plans around dinner and suggests marking those nights rushed. Nothing from your calendar leaves this device or is saved.")
        }
    }

    static let settingsURL: URL = {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        #endif
    }()
}

#Preview {
    List { CalendarSettingsSection() }
        .environment(CalendarBusyStore(source: .none))
}
