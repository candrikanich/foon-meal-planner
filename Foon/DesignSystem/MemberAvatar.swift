import SwiftUI

/// A member's emoji avatar, or their first initial when they haven't picked one.
struct MemberAvatar: View {
    let member: Member
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(.fill.tertiary)
            if let avatar = member.avatar {
                Text(avatar).font(.system(size: size * 0.55))
            } else {
                Text(member.firstName.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Emoji avatars: animals and friendly things, never photos of people (minimal data).
struct AvatarPicker: View {
    static let choices = ["🦊", "🐻", "🐢", "🦉", "🐰", "🐼", "🦁", "🐸", "🐙", "🦄", "🌻", "⭐️"]

    @Binding var selection: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
            ForEach(Self.choices, id: \.self) { choice in
                Button {
                    selection = selection == choice ? nil : choice
                } label: {
                    Text(choice)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(selection == choice ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Avatar \(choice)")
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    @Previewable @State var selection: String? = "🦊"
    VStack(spacing: 24) {
        HStack {
            MemberAvatar(member: .fixture(firstName: "Nora", avatar: "🐢"))
            MemberAvatar(member: .fixture(firstName: "Owen"))
        }
        AvatarPicker(selection: $selection)
    }
    .padding()
}
