import SwiftUI

/// Shown in place of a shared recipe's rough draft while this device tidies it (#256), and on onboarding's example.
/// The message moves on as time passes (`TidyProgress`), so a wait of 10 or 20 seconds never looks stuck.
struct TidyProgressCard: View {
    let startedAt: Date
    let limit: Duration
    /// "Don't wait": shows the draft now. Nil where there's nothing to finish by hand, like onboarding's example.
    var onSkip: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var stage: TidyProgress.Stage

    init(startedAt: Date, limit: Duration, onSkip: (() -> Void)? = nil) {
        self.startedAt = startedAt
        self.limit = limit
        self.onSkip = onSkip
        _stage = State(initialValue: TidyProgress.stage(after: .seconds(Date.now.timeIntervalSince(startedAt)),
                                                        limit: limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageLayout {
                Image(systemName: "frying.pan")
                    .font(.title2)
                    .foregroundStyle(Palette.paprika)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(TidyProgress.message(stage))
                        .font(.foonHeadline)
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.opacity)
                    Text(TidyProgress.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let onSkip {
                Button(TidyProgress.skip, action: onSkip)
                    .font(.callout)
                    .buttonStyle(.borderless)
                    .tint(Palette.paprika)
                    .accessibilityHint(
                        Text("Shows the recipe as it was read. Foon keeps tidying what you don't change."))
            }
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: stage)
        .task(id: startedAt) { await follow() }
        .onChange(of: stage) { _, stage in Self.announce(TidyProgress.message(stage)) }
    }

    private var messageLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }

    /// Wakes only when the message is due to change.
    private func follow() async {
        while !Task.isCancelled {
            let elapsed = Duration.seconds(Date.now.timeIntervalSince(startedAt))
            stage = TidyProgress.stage(after: elapsed, limit: limit)
            guard let wait = TidyProgress.nextChange(after: elapsed, limit: limit) else { return }
            try? await Task.sleep(for: wait)
        }
    }

    /// Low priority, so it waits for whatever VoiceOver is saying and never cuts in.
    static func announce(_ text: String) {
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
    }
}

// MARK: - Previews

@MainActor
private func previewCard(after seconds: TimeInterval, canSkip: Bool = true) -> some View {
    List {
        Section {
            TidyProgressCard(startedAt: .now.addingTimeInterval(-seconds), limit: RecipeStructuring.timeLimit,
                             onSkip: canSkip ? {} : nil)
        }
    }
}

#Preview("Reading the recipe") { previewCard(after: 0) }
#Preview("Sorting out the ingredients") { previewCard(after: 6) }
#Preview("A lot going on") { previewCard(after: 13) }
#Preview("Almost there") { previewCard(after: 40) }
#Preview("Onboarding, nothing to skip") { previewCard(after: 0, canSkip: false) }
#Preview("Largest text") {
    previewCard(after: 13).dynamicTypeSize(.accessibility3)
}
