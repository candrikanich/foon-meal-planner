import SwiftUI

/// Cook mode (docs/spec.md → Cook mode): one step per screen in big type, one-tap timers found in the step, the
/// screen kept awake, and tonight's serving notes up front. For beginner cooks as much as anyone.
struct CookModeView: View {
    @Environment(\.dismiss) private var dismiss
    let meal: LibraryMeal
    /// "Nora: keep everything separate", for whoever is home tonight (or everyone's, when it isn't tonight's dish).
    let servingNotes: [String]
    /// Whether the notes are tonight's (who's home), which titles them "Tonight".
    let notesAreTonight: Bool
    @State private var timers: CookTimers
    @State private var page = 0
    #if os(macOS)
    /// Keeps the Mac's display from sleeping mid-step.
    @State private var awake: NSObjectProtocol?
    #endif

    init(meal: LibraryMeal, servingNotes: [String], notesAreTonight: Bool = false, timers: CookTimers = CookTimers()) {
        self.meal = meal
        self.servingNotes = servingNotes
        self.notesAreTonight = notesAreTonight
        _timers = State(initialValue: timers)
    }

    /// Page 0 is "Before you start"; then one page per step.
    private var pageCount: Int { meal.steps.count + 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(iOS)
                // Swipe between steps as well as the buttons.
                TabView(selection: $page) {
                    beforeYouStart.tag(0)
                    ForEach(Array(meal.steps.enumerated()), id: \.offset) { index, step in
                        stepPage(step, number: index + 1).tag(index + 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                #else
                Group {
                    if page == 0 { beforeYouStart } else { stepPage(meal.steps[page - 1], number: page) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                #endif
                if !timers.running.isEmpty { runningTimers }
                controls
            }
            .background(Palette.cream)
            .navigationTitle(meal.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { keepAwake(true) }
        .onDisappear {
            keepAwake(false)
            timers.stopAll()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    // MARK: - Pages

    private var beforeYouStart: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Before you start").font(.foonLargeTitle).foregroundStyle(Palette.ink)
                if !servingNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notesAreTonight ? String(localized: "Tonight") : String(localized: "Serving notes"))
                            .font(.foonHeadline)
                        ForEach(servingNotes, id: \.self) { note in
                            Label(note, systemImage: "fork.knife").font(.foonBody)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
                }
                if !meal.ingredients.isEmpty {
                    Text("You'll need").font(.foonHeadline)
                    ForEach(Array(meal.ingredients.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.name).font(.foonBody)
                            Spacer()
                            if let quantity = line.quantityText { Text(quantity).font(.foonBody).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if meal.steps.isEmpty {
                    Text("This dish has no steps yet. Add them on the meal to cook along here.")
                        .font(.foonBody)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private func stepPage(_ step: String, number: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Step \(number) of \(meal.steps.count)").font(.foonHeadline).foregroundStyle(.secondary)
                Text(step).font(.system(.title, design: .rounded)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(CookSteps.timers(in: step).enumerated()), id: \.offset) { _, timer in
                    Button {
                        timers.start(timer, dish: meal.name)
                    } label: {
                        Label("Timer: \(timer.label)", systemImage: "timer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.paprika)
                    .controlSize(.large)
                    .accessibilityHint("Starts a timer; an alert goes off when it's done, even with the phone locked")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Timers and controls

    private var runningTimers: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                if timers.alertsOff {
                    Link(destination: Self.notificationSettings) {
                        Label("Alerts are off, so keep Foon open. Turn them on in Settings.", systemImage: "bell.slash")
                            .font(.foonCaption)
                    }
                    .tint(Palette.paprika)
                }
                ForEach(timers.running) { timer in
                    let remaining = timer.remaining(at: context.date)
                    HStack {
                        Image(systemName: remaining == 0 ? "bell.fill" : "timer")
                            .foregroundStyle(remaining == 0 ? Palette.paprika : .secondary)
                        Text(timer.label).font(.foonBody)
                        Spacer()
                        Text(remaining == 0 ? String(localized: "cook.timer.finished", defaultValue: "Done", comment: "Cook mode: a timer that has finished")
                                            : CookSteps.clock(remaining))
                            .font(.system(.title3, design: .rounded).monospacedDigit())
                            .accessibilityLabel(remaining == 0 ? String(localized: "cook.timer.finished", defaultValue: "Done", comment: "Cook mode: a timer that has finished")
                                                               : String(localized: "\(CookSteps.spoken(remaining)) left"))
                        Button("Stop", systemImage: "xmark.circle.fill") { timers.stop(timer.id) }
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop the \(timer.label) timer")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                withAnimation { page = max(page - 1, 0) }
            } label: {
                Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(page == 0)
            if page < pageCount - 1 {
                Button {
                    withAnimation { page += 1 }
                } label: {
                    Label(page == 0 ? "Start cooking" : "Next", systemImage: "chevron.right").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(Palette.paprika)
            } else {
                Button { dismiss() } label: {
                    Label("All done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.herb)
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    /// The steps stay on screen with flour on your hands.
    private func keepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #elseif os(macOS)
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Cook mode")
        } else if !on, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
        #endif
    }

    private static let notificationSettings: URL = {
        #if canImport(UIKit)
        URL(string: UIApplication.openNotificationSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #endif
    }()
}

#Preview("Cook mode") {
    var meal = LibraryMeal.sampleLibrary[0]
    meal.steps = ["Brown the beef in a big pot.", "Add the beans and tomatoes. Simmer 30 minutes.",
                  "Rest 5-10 minutes, then serve."]
    return CookModeView(meal: meal, servingNotes: ["Nora: keep everything separate before mixing"],
                        timers: CookTimers(notifier: .none))
}
