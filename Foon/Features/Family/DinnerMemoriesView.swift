import SwiftUI

/// Dinner memories (#65, part 3): this device's photos from around dinner on logged nights, newest first. Per device
/// and per person, kids included, since it's only their own library. Nothing read here leaves the screen.
struct DinnerMemoriesView: View {
    @Environment(HouseholdStore.self) private var household
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: DinnerMemoriesStore
    @State private var opened: OpenedPhoto?

    init(source: PhotoLibrarySource = .system, defaults: UserDefaults = .standard) {
        _store = State(initialValue: DinnerMemoriesStore(source: source, defaults: defaults))
    }

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }
    private var today: CalendarDay { settings.today() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.cream)
        .navigationTitle("Dinner memories")
        .task { store.checkAccess() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.checkAccess() }
        }
        #if os(macOS)
        // A Mac app stays active while System Settings is in front, so its return is noticed here instead.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkAccess()
        }
        #endif
        .sheet(item: $opened) { photo in
            OpenedPhotoView(photo: photo, source: store.source)
        }
    }

    @ViewBuilder private var content: some View {
        if store.access == .refused {
            intro
            Link(destination: Self.settingsURL) {
                Label("Foon can't see your photos. Allow it in Settings.", systemImage: "photo.badge.exclamationmark")
                    .font(.foonBody)
            }
        } else if !store.isShowing {
            intro
            Button {
                Task { await store.turnOn() }
            } label: {
                Label("Show my dinner photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            switchCard
            ForEach(store.dinners) { dinner in
                MemoryDinnerCard(dinner: dinner, today: today, calendar: settings.dayCalendar, source: store.source) {
                    opened = OpenedPhoto(id: $0, label: DinnerMemories.photoLabel(for: dinner.night,
                                                                                 calendar: settings.dayCalendar))
                }
            }
            footer
        }
    }

    private var intro: some View {
        Text("See the photos on this device that were taken around dinner on the nights your family logged. They show only here, on this device. Foon never uploads or saves them.")
            .font(.foonBody)
            .foregroundStyle(Palette.ink)
    }

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show dinner photos", systemImage: "photo.on.rectangle", isOn: Binding(
                get: { store.isOn },
                set: { on in
                    if on { Task { await store.turnOn() } } else { store.turnOff() }
                }
            ))
            .font(.foonBody)
            if store.access == .limited {
                Link("Only the photos you chose for Foon show here. Change that in Settings.",
                     destination: Self.settingsURL)
                    .font(.foonCaption)
            } else {
                Text("Shown only on this device. Foon never uploads or saves them.")
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    @ViewBuilder private var footer: some View {
        if store.failed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load your dinners. Check your connection and try again.")
                    .font(.foonBody)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await loadMore() } }
            }
        } else if store.isEmpty {
            ContentUnavailableView {
                Label("No dinner photos yet", systemImage: "camera")
            } description: {
                Text("Snap a picture at the table some night. Once that dinner is logged, it shows up here.")
            }
        } else if !store.reachedEnd {
            // Reaching the bottom reads the next few months back, never the whole library at once.
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
                .task(id: store.nextRead) { await loadMore() }
        }
    }

    private func loadMore() async {
        guard let id = household.household?.id else { return }
        let client = household.client
        await store.loadMore(logs: { from, through in try await client.dinnerMemories(id, from, through) },
                             settings: settings, today: today)
    }

    static let settingsURL: URL = {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
        #endif
    }()
}

/// One night: its date, what was eaten, and up to six photos with a "+N".
private struct MemoryDinnerCard: View {
    let dinner: MemoryDinner
    let today: CalendarDay
    let calendar: Calendar
    let source: PhotoLibrarySource
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DinnerMemories.dateLabel(for: dinner.night, today: today, calendar: calendar))
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
                Text(dinner.night.title)
                    .font(.foonHeadline)
                    .foregroundStyle(Palette.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dinner.shownPhotoIDs, id: \.self) { id in
                        Button { open(id) } label: {
                            MemoryThumbnail(id: id, source: source)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(DinnerMemories.photoLabel(for: dinner.night, calendar: calendar))
                        .accessibilityHint("Shows the photo larger")
                    }
                    if dinner.morePhotos > 0 {
                        Text("+\(dinner.morePhotos)")
                            .font(.foonHeadline)
                            .foregroundStyle(.secondary)
                            .frame(width: MemoryThumbnail.side, height: MemoryThumbnail.side)
                            .accessibilityLabel(dinner.morePhotos == 1
                                ? Text("1 more photo", comment: "Dinner memories: a photo from that night not shown")
                                : Text("\(dinner.morePhotos) more photos",
                                       comment: "Dinner memories: photos from that night not shown"))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        .accessibilityElement(children: .contain)
    }
}

/// A square thumbnail, read when it scrolls into view and dropped with the screen.
private struct MemoryThumbnail: View {
    static let side: CGFloat = 76
    let id: String
    let source: PhotoLibrarySource
    @State private var image: Image?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Palette.cream)
            .frame(width: Self.side, height: Self.side)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: id) { image = await source.image(id, CGSize(width: Self.side, height: Self.side)) }
    }
}

struct OpenedPhoto: Identifiable {
    let id: String
    let label: String
}

/// The photo, larger. Read again at this size and dropped when it closes.
private struct OpenedPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: OpenedPhoto
    let source: PhotoLibrarySource
    @State private var image: Image?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                        .accessibilityLabel(photo.label)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 320)
        .task(id: photo.id) { image = await source.image(photo.id, CGSize(width: 420, height: 420)) }
    }
}

#Preview("Photos on") {
    DinnerMemoriesPreview(on: true)
}

#Preview("Not on yet") {
    DinnerMemoriesPreview(on: false)
}

#Preview("Access refused") {
    NavigationStack { DinnerMemoriesView(source: .preview(access: .refused)) }
        .environment(HouseholdStore.preview())
}

private struct DinnerMemoriesPreview: View {
    let on: Bool
    @State private var store = HouseholdStore.preview()

    private var defaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "preview.dinnerMemories") ?? .standard
        defaults.set(on, forKey: DinnerMemoriesStore.onKey)
        return defaults
    }

    var body: some View {
        NavigationStack { DinnerMemoriesView(source: .preview(access: on ? .full : .notAsked), defaults: defaults) }
            .environment(store)
            .task { await store.load() }
    }
}
