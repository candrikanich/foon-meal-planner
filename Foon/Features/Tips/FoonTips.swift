import SwiftUI
import TipKit

/// TipKit's state lives on this device, for whoever uses it, and nothing syncs (docs/spec.md → Tips).
enum FoonTips {
    static func configure(_ defaults: UserDefaults = .standard) {
        // A failure only means no tips this launch; nothing else depends on them.
        if TipReset.takePending(defaults) { try? Tips.resetDatastore() }
        try? Tips.configure()
    }

    static var onMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// On Ideas, until the person first shares something to Foon.
struct ShareToFoonTip: Tip {
    var title: Text { Text("Share recipes to Foon") }
    var message: Text? {
        Text("Found a recipe in another app? Tap Share, then Foon, and it lands in your ideas.")
    }
    var image: Image? { Image(systemName: "square.and.arrow.up") }
}

/// On Lists → Shop, until store mode is first opened.
struct StoreModeTip: Tip {
    var title: Text { Text("Shop in store mode") }
    var message: Text? {
        Text("At the store, tap Shop: aisles in walking order, big rows, and the screen stays awake.")
    }
    var image: Image? { Image(systemName: "cart") }
}

/// Family → Show tips again, for everyone: tips are per device, so each person brings back their own.
struct ShowTipsAgainSection: View {
    @State private var pending = TipReset.isPending(.standard)

    var body: some View {
        Section {
            Button("Show tips again") {
                TipReset.request(.standard)
                pending = true
            }
            .disabled(pending)
        } footer: {
            if pending {
                Text("Tips come back after you close Foon and open it again.")
            } else {
                Text("The short notes that show where things are, each shown once.")
            }
        }
    }
}

#Preview("Show tips again") {
    List { ShowTipsAgainSection() }
}

#Preview("Tips") {
    List {
        TipView(ShareToFoonTip())
        TipView(StoreModeTip())
    }
    .task {
        Tips.showAllTipsForTesting()
        try? Tips.configure()
    }
}
