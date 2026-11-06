import SwiftUI

/// Where Foon's published policies live (docs/legal/README.md, After review). The pages are plain summaries until the
/// reviewed policies replace them (#67); the URLs stay.
enum FoonLinks {
    static let privacy = URL(string: "https://getfoon.com/privacy")!
    static let terms = URL(string: "https://getfoon.com/terms")!
}

/// Terms of Use and Privacy Policy, side by side, for the paywall and other places that ask someone to agree.
/// Borderless so each link works on its own inside a Form row.
struct PolicyLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            Link("Terms of Use", destination: FoonLinks.terms)
                .accessibilityHint("Opens Foon's terms on the web")
            Link("Privacy Policy", destination: FoonLinks.privacy)
                .accessibilityHint("Opens Foon's privacy policy on the web")
        }
        .buttonStyle(.borderless)
        .font(.footnote)
    }
}

#Preview {
    List { PolicyLinks() }
}
