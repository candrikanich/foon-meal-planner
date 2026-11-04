import SwiftUI

/// "What Foon does for you" (#236): two cards, each optional to try, and one button on. Nothing here waits on the
/// network or saves anything. The tidy-up waits like a real share does (#256); a slow friendly line just leaves the
/// plain one showing.
struct ShowcaseStep: View {
    let model: ShowcaseModel
    let onNext: () -> Void
    @State private var recipeAsked = false
    @State private var rescueAsked = false

    var body: some View {
        List {
            Section {
                Text(OnboardingShowcase.intro).foregroundStyle(.secondary)
            }
            Section {
                RecipeCard(model: model) { recipeAsked = true }
            }
            Section {
                RescueCard(model: model) { rescueAsked = true }
            }
        }
        .navigationTitle(OnboardingShowcase.title)
        .safeAreaInset(edge: .bottom) {
            StepFooter(primary: OnboardingShowcase.continueTitle(tried: model.tried), onPrimary: onNext)
        }
        // Leaving the step cancels whatever's still running; the demo keeps nothing.
        .task(id: recipeAsked) { if recipeAsked { await model.showRecipe() } }
        .task(id: rescueAsked) { if rescueAsked { await model.showRescue() } }
    }
}

private struct CardHeader: View {
    let title: String
    let systemImage: String
    let body1: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
            Text(body1)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecipeCard: View {
    let model: ShowcaseModel
    let onTry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardHeader(title: OnboardingShowcase.recipeTitle, systemImage: "square.and.arrow.down",
                   body1: OnboardingShowcase.recipeBody,
                   detail: OnboardingShowcase.recipeDetail(model.variant))
        if model.recipeShown {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingShowcase.recipeShared).font(.foonCaption).foregroundStyle(.secondary)
                Text(model.recipe.post)
                    .font(.footnote.monospaced())
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.cardSurface))
            }
            .accessibilityElement(children: .combine)
            landed
            Text(OnboardingShowcase.recipeExample).font(.foonCaption).foregroundStyle(.secondary)
        } else {
            Button(OnboardingShowcase.showMe, systemImage: "play.circle", action: onTry)
                .tint(Palette.paprika)
                .accessibilityLabel(Text("Show a shared recipe landing in your ideas"))
                .accessibilityInputLabels([Text(OnboardingShowcase.showMe), Text("Show a shared recipe")])
        }
    }

    private var landed: some View {
        let shown = Landed(model.tidied, plain: model.recipe.plain)
        let caption = Text(OnboardingShowcase.recipeLands).font(.foonCaption).foregroundStyle(.secondary)
        return VStack(alignment: .leading, spacing: 6) {
            // The share sheet's own wait, so the demo is what sharing is really like.
            if model.isTidying {
                caption
                TidyProgressCard(startedAt: model.tidyStarted, limit: OnboardingShowcase.tidyTimeout)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    caption
                    if let note = model.tidyNote {
                        Text(note).font(.foonCaption).foregroundStyle(.secondary)
                    }
                    Text(shown.name).font(.foonBody.weight(.semibold))
                    ForEach(Array(shown.ingredients.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "circle.fill").labelStyle(Bullet())
                    }
                    ForEach(Array(shown.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)", comment: "Onboarding: a numbered recipe step").font(.callout)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .default, value: model.isTidying)
    }

    /// The tidy recipe when there is one, otherwise the plain read as it would land.
    private struct Landed {
        let name: String
        let ingredients: [String]
        let steps: [String]

        init(_ tidied: StructuredRecipe?, plain: RecipeTextParser.Capture) {
            if let tidied {
                (name, ingredients, steps) = (tidied.name, tidied.ingredients, tidied.steps)
            } else {
                name = plain.name ?? ""
                ingredients = plain.ingredients.map { [$0.quantity, $0.name].compactMap { $0 }.joined(separator: " ") }
                steps = plain.steps
            }
        }
    }
}

private struct Bullet: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title.font(.callout)
        }
    }
}

private struct RescueCard: View {
    let model: ShowcaseModel
    let onTry: () -> Void

    var body: some View {
        CardHeader(title: OnboardingShowcase.rescueTitle, systemImage: "lifepreserver",
                   body1: OnboardingShowcase.rescueBody,
                   detail: OnboardingShowcase.rescueDetail(model.variant))
        if let ideas = model.rescue {
            ForEach(ideas) { idea in row(idea) }
            Text(OnboardingShowcase.rescueExample).font(.foonCaption).foregroundStyle(.secondary)
        } else {
            Button(OnboardingShowcase.showMe, systemImage: "play.circle", action: onTry)
                .tint(Palette.paprika)
                .accessibilityLabel(Text("Show three ideas for tonight from your dinners"))
                .accessibilityInputLabels([Text(OnboardingShowcase.showMe), Text("Show ideas for tonight")])
        }
    }

    private func row(_ idea: TonightRescue.Idea) -> some View {
        let friendly = model.wording[idea.id]
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: RescueRow.systemImage(idea.kind))
                .foregroundStyle(Palette.paprika)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(idea.title).font(.foonBody).foregroundStyle(Palette.ink)
                if let friendly {
                    Text(friendly).font(.foonCaption).italic().foregroundStyle(Palette.ink)
                }
                Text(idea.why).font(.foonCaption).foregroundStyle(.secondary)
                AllergyChips(check: idea.allergies)
            }
        }
        .animation(.default, value: friendly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SwapRow.label(idea.title, allergies: idea.allergies,
                                          details: [friendly, idea.why].compactMap { $0 }))
    }
}

// MARK: - Previews

@MainActor private func previewModel(_ ai: AIService) -> ShowcaseModel {
    let library = LibraryMeal.sampleLibrary
    return ShowcaseModel(dish: library.first, library: library, allergies: [], settings: HouseholdSettings(),
                         today: CalendarDay(Date()), ai: ai, seed: 1)
}

#Preview("On a phone that can") {
    NavigationStack { ShowcaseStep(model: previewModel(.previewCapable), onNext: {}) }
}

#Preview("Tidying on a phone that can") {
    let model = previewModel(.previewTidying)
    NavigationStack { ShowcaseStep(model: model, onNext: {}) }
        .task { await model.showRecipe() }
}

#Preview("On any other phone") {
    NavigationStack { ShowcaseStep(model: previewModel(.none), onNext: {}) }
}

#Preview("Tried, with no dinners yet") {
    let model = ShowcaseModel(dish: nil, library: [], allergies: [], settings: HouseholdSettings(),
                              today: CalendarDay(Date()), ai: .none, seed: 1)
    NavigationStack { ShowcaseStep(model: model, onNext: {}) }
        .task {
            await model.showRecipe()
            await model.showRescue()
        }
}
