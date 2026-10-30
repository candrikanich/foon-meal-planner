import PhotosUI
import SwiftUI

/// One meal (docs/spec.md → Meal detail): photo, tags and allergy flags, history, ingredients with
/// Add to list, prep, recipe steps, and the source link. Planners edit, copy, and archive; everyone
/// can add ingredients to the list.
struct MealDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week: WeekStore?
    @Environment(SyncService.self) private var sync: SyncService?
    let mealID: UUID
    let canEdit: Bool

    @State private var editing: LibraryMeal?
    @State private var planning: LibraryMeal?
    @State private var bringingBack: LibraryMeal?
    @State private var editingNote: NoteTarget?
    @State private var cooking: LibraryMeal?
    @State private var photoItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var addedItemIDs: Set<UUID> = []
    @State private var photoURL: URL?
    @State private var openItem: ItemDetails?
    @Environment(\.itemClient) private var itemClient

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
                if !meal.steps.isEmpty {
                    Button { cooking = meal } label: {
                        Label("Start cooking", systemImage: "frying.pan").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.paprika)
                    .controlSize(.large)
                    .accessibilityHint("One step at a time, with timers")
                }
                verdicts(meal)
                comments(meal)
                servingNotes(meal)
                if let message = library.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                ingredients(meal)
                if !meal.sides.isEmpty { sides(meal) }
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
        .confirmationDialog("Bring back a dish the family voted out?", isPresented: Binding(
            get: { bringingBack != nil }, set: { if !$0 { bringingBack = nil } }
        ), titleVisibility: .visible, presenting: bringingBack) { meal in
            Button("Back in rotation") { Task { await library.setArchived(false, mealID: meal.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It'll still stay off nights when anyone who said Not for me is home, and another Not for me retires it again.")
        }
        .sheet(item: $planning) { meal in PlanItSheet(meal: meal) }
        .sheet(item: $editingNote) { target in ServingNoteEditor(target: target) }
        #if os(iOS)
        .fullScreenCover(item: $cooking) { meal in
            CookModeView(meal: meal, servingNotes: cookingNotes(meal), notesAreTonight: isTonight(meal))
        }
        #else
        .sheet(item: $cooking) { meal in
            CookModeView(meal: meal, servingNotes: cookingNotes(meal), notesAreTonight: isTonight(meal))
        }
        #endif
        .sheet(item: $editing) { meal in
            MealEditorView(meal: meal)
        }
        .sheet(item: $openItem) { item in
            ItemSheet(item: item, canRecategorize: canEdit, client: itemClient) { await library.reload() }
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

    /// Every family member's current verdict on the dish, visible to all (docs/spec.md → Meal detail).
    @ViewBuilder
    private func verdicts(_ meal: LibraryMeal) -> some View {
        let verdicts = library.reactions.verdicts(for: meal.id)
        let members = library.activeMembers.filter { member in verdicts.contains { $0.memberID == member.id } }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("What everyone thinks").font(.foonTitle).accessibilityAddTraits(.isHeader)
                ForEach(members) { member in
                    if let verdict = verdicts.first(where: { $0.memberID == member.id }) {
                        HStack(spacing: 10) {
                            MemberAvatar(member: member, size: 28)
                            Text(member.firstName).font(.foonBody)
                            Spacer()
                            Label(verdict.kind.title, systemImage: verdict.kind.systemImage)
                                .font(.foonCaption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// What people said about the dish. A hidden comment only reaches planners (the server's rule), who can bring it back.
    @ViewBuilder
    private func comments(_ meal: LibraryMeal) -> some View {
        let comments = library.comments(for: meal.id)
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Comments").font(.foonTitle).accessibilityAddTraits(.isHeader)
                ForEach(comments) { comment in
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: MealComment) -> some View {
        let member = household.members.first { $0.id == comment.memberID }
        let name = member?.firstName ?? String(localized: "Someone")
        return HStack(alignment: .top, spacing: 10) {
            if let member { MemberAvatar(member: member, size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.foonCaption).foregroundStyle(.secondary)
                Text(comment.text).font(.foonBody).foregroundStyle(comment.hidden ? .secondary : Palette.ink)
                if comment.hidden {
                    Label("Hidden from the family", systemImage: "eye.slash")
                        .font(.foonCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if canEdit {
                Button(comment.hidden ? "Show" : "Hide") {
                    Task { await library.setCommentHidden(comment, hidden: !comment.hidden) }
                }
                .font(.foonCaption)
                .buttonStyle(.borderless)
                .tint(Palette.paprika)
                .accessibilityLabel(comment.hidden ? String(localized: "Show \(name)'s comment")
                                                   : String(localized: "Hide \(name)'s comment"))
            }
        }
    }

    private func isTonight(_ meal: LibraryMeal) -> Bool {
        week?.layout?.tonight?.mealID == meal.id
    }

    /// Serving notes for cook mode: for who's home tonight when this is tonight's dish, else everyone's.
    private func cookingNotes(_ meal: LibraryMeal) -> [String] {
        let members = household.visibleMembers
        let tonight = week?.layout?.tonight.flatMap { $0.mealID == meal.id ? $0 : nil }
        let home = tonight.map { Set($0.attendance.filter(\.value).keys) } ?? Set(members.map(\.id))
        return ServingNotes.lines(library.servingNotes, mealID: meal.id, home: home, members: members)
    }

    /// Who writes whose note: themselves, or a parent for anyone (kids without phones included).
    private var writableMembers: [Member] {
        household.visibleMembers.filter {
            ServingNotes.canWrite(for: $0, me: household.me, isParent: household.canManagePeople)
        }
    }

    /// "Nora: keep everything separate before mixing": how each person likes this dish, visible to everyone.
    @ViewBuilder
    private func servingNotes(_ meal: LibraryMeal) -> some View {
        let notes = library.servingNotes(for: meal.id)
        let writable = writableMembers
        if !notes.isEmpty || !writable.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Serving notes").font(.foonTitle).accessibilityAddTraits(.isHeader)
                ForEach(household.visibleMembers) { member in
                    if let note = notes.first(where: { $0.memberID == member.id }) {
                        let row = HStack(alignment: .top, spacing: 10) {
                            MemberAvatar(member: member, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.firstName).font(.foonCaption).foregroundStyle(.secondary)
                                Text(note.note).font(.foonBody).foregroundStyle(Palette.ink)
                            }
                            Spacer(minLength: 0)
                        }
                        // Only a note you may change is a button; anyone else's reads as plain text.
                        if writable.contains(where: { $0.id == member.id }) {
                            Button { editingNote = NoteTarget(meal: meal, member: member, note: note.note) } label: { row }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edit the note")
                        } else {
                            row.accessibilityElement(children: .combine)
                        }
                    }
                }
                let without = writable.filter { member in !notes.contains { $0.memberID == member.id } }
                if !without.isEmpty {
                    Menu {
                        ForEach(without) { member in
                            Button(member.firstName) { editingNote = NoteTarget(meal: meal, member: member, note: "") }
                        }
                    } label: {
                        Label("Add a serving note", systemImage: "plus")
                    }
                    .tint(Palette.paprika)
                }
            }
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
                    Button { openItem = line.details } label: {
                        ItemLabel(name: line.name, note: line.note, quantity: line.quantityText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the item's note, aisle, and keep on hand")
                    Spacer(minLength: 8)
                    if sync != nil {
                        addButton(for: line)
                    }
                }
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

    private func sides(_ meal: LibraryMeal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goes with").font(.foonTitle)
            ForEach(meal.sides, id: \.self) { side in
                switch side {
                case .meal(let id):
                    if let sideMeal = library.meal(id), sideMeal.status != .retired {
                        NavigationLink(value: id) {
                            Label(sideMeal.name, systemImage: "fork.knife")
                        }
                        .tint(Palette.paprika)
                    }
                case .item(_, let name):
                    Label(name, systemImage: "basket").foregroundStyle(Palette.ink)
                }
            }
            .font(.foonBody)
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

    /// Back in rotation: right away for an archived dish; a retired one asks first, since the family voted it out.
    private func restore(_ meal: LibraryMeal) {
        if meal.status == .retired {
            bringingBack = meal
        } else {
            Task { await library.setArchived(false, mealID: meal.id) }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ meal: LibraryMeal) -> some ToolbarContent {
        if canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = meal }
            }
            if meal.status.isInRotation {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Plan it", systemImage: "calendar.badge.plus") { planning = meal }
                }
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
                    Button("Back in rotation", systemImage: "arrow.uturn.backward") { restore(meal) }
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

/// Whose note on which dish is being written.
struct NoteTarget: Identifiable {
    let meal: LibraryMeal
    let member: Member
    let note: String
    var id: String { "\(meal.id)-\(member.id)" }
}

/// Write, change, or clear one person's serving note on a dish.
struct ServingNoteEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let target: NoteTarget
    @State private var text = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How \(target.member.firstName) likes it", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    if let message = library.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shown on the day card when \(target.member.firstName) is home.")
                            Text("\(ServingNote.length(text)) of \(ServingNote.maxLength)")
                        }
                    }
                }
                if !target.note.isEmpty {
                    Section {
                        Button("Clear the note", role: .destructive) { save("") }
                    }
                }
            }
            .navigationTitle("\(target.member.firstName), \(target.meal.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(text) }
                        .disabled(isSaving || ServingNote.length(text) == 0 || ServingNote.length(text) > ServingNote.maxLength)
                }
            }
            .onAppear {
                text = target.note
                library.clearError()
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
    }

    private func save(_ note: String) {
        Task {
            isSaving = true
            defer { isSaving = false }
            if await library.setServingNote(note, mealID: target.meal.id, memberID: target.member.id) { dismiss() }
        }
    }
}

#Preview("Serving note") {
    ServingNoteEditor(target: NoteTarget(meal: LibraryMeal.sampleLibrary[0], member: Member.sampleFamily[4],
                                         note: "Keep everything separate before mixing"))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
}

#Preview("Planner") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    NavigationStack {
        MealDetailView(mealID: LibraryMeal.sampleLibrary[0].id, canEdit: true)
    }
    .environment(library)
    .environment(household)
    .task {
        await household.load()
        await library.load(members: Member.sampleFamily)
    }
}

#Preview("Member, flagged") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    NavigationStack {
        MealDetailView(mealID: LibraryMeal.sampleLibrary[1].id, canEdit: false)
    }
    .environment(library)
    .environment(household)
    .task {
        await household.load()
        await library.load(members: Member.sampleFamily)
    }
}
