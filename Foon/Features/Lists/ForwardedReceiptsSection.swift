import SwiftUI

/// Lists' forwarded receipts to review, one row each with the day it came. Shown only while some are waiting.
struct ForwardedReceiptsSection: View {
    let receipts: [ForwardedReceipt]
    /// Reviewing is blocked while the household has lapsed, as a photo scan is.
    let canReview: Bool
    let open: (ForwardedReceipt) -> Void

    var body: some View {
        if !receipts.isEmpty {
            Section {
                ForEach(receipts) { receipt in
                    Button { open(receipt) } label: {
                        Label("Forwarded receipt from \(day(receipt.receivedAt))", systemImage: "envelope.open")
                    }
                    .disabled(!canReview)
                    .accessibilityHint(Text("Check what Foon found before anything changes"))
                }
            } header: {
                Text("^[\(receipts.count) forwarded receipt](inflect: true) to review")
            }
        }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

#Preview {
    List {
        ForwardedReceiptsSection(receipts: ReceiptFixtures.forwarded, canReview: true) { _ in }
    }
}
