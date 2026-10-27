import PhotosUI
import SwiftUI

/// One meal (docs/spec.md → Meal detail): photo, tags and allergy flags, history, ingredients with
/// Add to list, prep, recipe steps, and the source link. Planners edit, copy, and archive; everyone
/// can add ingredients to the list.
struct MealDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SyncService.self) private var sync: SyncService?
    let mealID: UUID
    let canEdit: Bool

    @State private var editing: LibraryMeal?
    @State private var photoItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var addedItemIDs: Set<UUID> = []
    @State private var photoURL: URL?

    var body: some View {
        if let entry = library.entry(mealID) {
            content(entry)
        } else {
            ContentUnavailableView("Meal not found", systemImage: "fork.knife",
                                   description: Text("It may have been removed on another device."))
        }
    }

    private func content(_ entry: LibraryEntry) -> some View {
        let meal = entry.meal
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(meal)
                header(entry)
                if let message = library.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                ingredients(meal)
                if !meal.prepSteps.isEmpty { prep(meal.prepSteps) }
                if !meal.steps.isEmpty { steps(meal.steps) }
                if let url = meal.sourceURL {
                    Link(destination: url) {
                        Label("View the original recipe", systemImage: "safari")
                    }
                    .tint(Palette.paprika)
                }
            }
            .padding()
        }
        .background(Palette.cream)
        .navigationTitle(meal.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar(meal) }
        .sheet(item: $editing) { meal in
            MealEditorView(meal: meal)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await upload(item, for: meal) }
        }
        .task(id: meal.photoPath) {
            guard let path = meal.photoPath else { photoURL = nil; return }
            photoURL = try? await library.photoURL(for: path)
        }
        .onAppear { library.clearError() }
    }

    // MARK: - Sections

    private func hero(_ meal: LibraryMeal) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let photoURL {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                } else {
                    Palette.herb.opacity(0.14)
                        .overlay(Image(systemName: "fork.knife").font(.system(size: 48)).foregroundStyle(Palette.herb))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if canEdit {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(meal.photoPath == nil ? "Add your photo" : "Replace with yours",
                              systemImage: "camera")
                            .font(.foonCaption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .disabled(isUploading)
                    .padding(10)
                }
            }
            .overlay {
                if isUploading { ProgressView() }
            }
            .accessibilityElement(children: .contain)
    }

    private func header(_ entry: LibraryEntry) -> some View {
        let meal = entry.meal
        return VStack(alignment: .leading, spacing: 10) {
            Text(meal.name).font(.foonLargeTitle).foregroundStyle(Palette.ink)
            if let cook = library.member(meal.madeByMemberID) {
                Text("Made by \(cook.firstName)").font(.foonCaption).foregroundStyle(.secondary)
            }
            ChipFlow(spacing: 6) {
                if meal.status == .trial { Chip(text: String(localized: "Trying"), tint: Palette.paprika) }
                if meal.status == .archived { Chip(text: String(localized: "Archived"), tint: .secondary) }
                ForEach(meal.tags, id: \.self) { tag in
                    Chip(text: tag.title)
                }
                ForEach(entry.flags, id: \.self) { flag in
                    Chip(text: flag.summary, systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
                }
            }
            Label(MealText.history(entry.history), systemImage: "clock.arrow.circlepath")
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            Text("Serves \(meal.servings)").font(.foonCaption).foregroundStyle(.secondary)
        }
    }

    private func ingredients(_ meal: LibraryMeal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ingredients").font(.foonTitle)
                Spacer()
                if !meal.ingredients.isEmpty, sync != nil {
                    Button("Add all to list") {
                        Task { for line in meal.ingredients { await addToList(line) } }
                    }
                    .font(.foonCaption)
                    .tint(Palette.paprika)
                    .disabled(meal.ingredients.allSatisfy { addedItemIDs.contains($0.itemID) })
                }
            }
            if meal.ingredients.isEmpty {
                Text(canEdit ? "No ingredients yet. Tap Edit to add them." : "No ingredients yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(meal.ingredients.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let quantity = line.quantityText {
                        Text(quantity).foregroundStyle(.secondary)
                    }
                    Text(line.name).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    if sync != nil {
                        addButton(for: line)
                    }
                }
                .font(.foonBody)
            }
        }
    }

    @ViewBuilder
    private func addButton(for line: MealIngredient) -> some View {
        if addedItemIDs.contains(line.itemID) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.herb)
                .accessibilityLabel("\(line.name) is on the list")
        } else {
            Button {
                Task { await addToList(line) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .tint(Palette.paprika)
            .accessibilityLabel("Add \(line.name) to the list")
        }
    }

    private func prep(_ prepSteps: [PrepStep]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prep ahead").font(.foonTitle)
            ForEach(Array(prepSteps.enumerated()), id: \.offset) { _, prep in
                VStack(alignment: .leading, spacing: 2) {
                    Text(prep.step).font(.foonBody)
                    if let lead = MealText.leadTime(hours: prep.leadHours) {
                        Text(lead).font(.foonCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func steps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps").font(.foonTitle)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1).").font(.foonHeadline).foregroundStyle(Palette.paprika)
                    Text(step).font(.foonBody)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ meal: LibraryMeal) -> some ToolbarContent {
        if canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = meal }
            }
            if LibraryStore.canCopy(meal) {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy and tweak", systemImage: "doc.on.doc") {
                        Task {
                            if let id = await library.copy(meal) { editing = library.meal(id) }
                        }
                    }
                    .disabled(library.isCopying(meal))
                }
            }
            if meal.status.isInRotation {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Archive", systemImage: "archivebox") {
                        Task { await library.setArchived(true, mealID: meal.id) }
                    }
                }
            } else if LibraryStore.canRestore(meal) {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Back in rotation", systemImage: "arrow.uturn.backward") {
                        Task { await library.setArchived(false, mealID: meal.id) }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func addToList(_ line: MealIngredient) async {
        guard let sync, !addedItemIDs.contains(line.itemID) else { return }
        addedItemIDs.insert(line.itemID)
        await sync.addToList(itemID: line.itemID, list: .quick)
    }

    private func upload(_ item: PhotosPickerItem, for meal: LibraryMeal) async {
        isUploading = true
        defer {
            isUploading = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            library.reportPhotoLoadFailure()
            return
        }
        _ = await library.setPhoto(data, for: meal)
    }
}

/// Chips that wrap onto as many lines as they need.
struct ChipFlow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: spacing) { content }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        guard let proposed = proposal.width, proposed.isFinite else { return CGSize(width: width, height: height) }
        return CGSize(width: proposed, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Its natural size, but never wider than the row: a long chip wraps its text instead of running off.
    private static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], within: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Planner") {
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    NavigationStack {
        MealDetailView(mealID: LibraryMeal.sampleLibrary[0].id, canEdit: true)
    }
    .environment(library)
    .task { await library.load(members: Member.sampleFamily) }
}

#Preview("Member, flagged") {
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    NavigationStack {
        MealDetailView(mealID: LibraryMeal.sampleLibrary[1].id, canEdit: false)
    }
    .environment(library)
    .task { await library.load(members: Member.sampleFamily) }
}
