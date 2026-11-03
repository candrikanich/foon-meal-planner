import Observation
import SwiftUI

@Observable @MainActor
final class DinnerCard {
    var saved = false
}

/// "How was dinner?", the four reactions, then Wasn't home and We had something else. Fixed words: like the lock screen, it
/// never names the dish (docs/spec.md → Words).
struct DinnerCardView: View {
    let card: DinnerCard
    let answer: (DinnerAnswer.Answer) -> Void
    let somethingElse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How was dinner?", comment: "Reminder title")
                .font(.headline)
            if card.saved {
                Label(String(localized: "Saved.", comment: "After-dinner card, once answered"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(spacing: 8) {
                    ForEach(ReactionKind.allCases, id: \.self) { kind in
                        Button { answer(.reaction(kind)) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.systemImage)
                                    .font(.title2)
                                Text(kind.title)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 8) {
                    Button(String(localized: "We had something else", comment: "After-dinner action"),
                           action: somethingElse)
                        .frame(maxWidth: .infinity)
                    // One tap, like the notification's button, and red like it: it marks them out for good.
                    Button(String(localized: "Wasn't home", comment: "After-dinner action"), role: .destructive) {
                        answer(.wasntHome)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

#Preview("Asking") {
    DinnerCardView(card: DinnerCard(), answer: { _ in }, somethingElse: {})
}

#Preview("Saved") {
    let card = DinnerCard()
    card.saved = true
    return DinnerCardView(card: card, answer: { _ in }, somethingElse: {})
}

#Preview("Large text") {
    DinnerCardView(card: DinnerCard(), answer: { _ in }, somethingElse: {})
        .environment(\.dynamicTypeSize, .accessibility2)
}
