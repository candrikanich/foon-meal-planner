# M3 car 6, part 2: AI recipe capture and prep-step detection (#59)

Builds on #58's queue (`Core/AI`) and #39's capture path (`SharedItemSheet`, `RecipeTextParser`, `TextRecognizer`,
`PrepSuggestions`). Nothing in the non-AI path is replaced: AI only tidies a draft that's already showing. Revised after
the PR #247 review (local first, fresh conditional save, bounded retries, planner-only jobs, prep offered, parsed lines).

## Shape

1. **What the model reads.** `RecipeJobPayload(capture)`: the parsed recipe lines only (title, servings, ingredient lines as
   read, step lines) and the source link. Never the raw OCR or caption text with the screen around it; nothing parsed means
   nothing to tidy. No allergies, members or household size. Cut at 8,000 characters / 24 KB.
2. **Guided generation.** `GeneratedRecipe` (`@Generable`): name, servings (0 when unknown), ingredients (≤ 60), steps
   (≤ 50), prep steps (≤ 10, step and hours ahead 1 to 48), through `AIService.generate`. `StructuredRecipe` trims to a
   meal's limits in its only initializer, which decoding goes through too, so a result read back from the queue is held to
   the same limits.
3. **Here first.** A capable device runs the model itself (`AIQueueStore.tidyHere`, a store-owned task) and uploads
   nothing; the result merges into the review screen. A device that can't queues a `recipe` job only when the planner adds
   the dish (`AIQueueStore.saved`), never on read, Discard, or Add to the quick list.
4. **Never over an edit.** Per-field SHA-256 digests (name, ingredients, steps) of the plain read, normalized the way a saved
   meal reads back. A field takes the result only if its digest still matches. A name the person gave has no baseline.
   Allergen lines the model dropped are kept.
5. **A dish saved first.** A `RecipeWatch` (`.here(token)` or `.job(id)`, meal, baseline, time) in UserDefaults; ids,
   dates and digests only. `RecipeApplier` reads the meal fresh (`LibraryClient.freshMeal`, with `updated_at`), merges,
   and saves through `save_meal_if_unchanged` (40001 when it changed since the read: read and merge again, up to 3 reads).
   A refusal or a gone dish finishes the watch; offline retries; every watch ends 3 days and an hour after the save,
   whatever its state. A result that came during the save but wasn't merged is applied on the next settle. Settling is one
   pass at a time.
6. **Prep steps offered, never applied.** `RecipePrep.offered`: the result's prep steps first, then `PrepSuggestions`'
   keyword ones of kinds not covered; the review screen's Prep ahead adds one per tap. Keywords now also catch "overnight".
7. **Planners only.** The guard refuses a claim, complete or fail of a `recipe` job by a non-planner (42501), and
   `claim_ai_job` skips recipe jobs for one. The client drains without `recipe` unless this member plans.
8. **Trimmed load.** `AIJobClient.statuses(ids)`: `id, kind, status, result, updated_at` for only the jobs a device waits
   on, no call when none.
9. **Migration `20261104000000_ai_jobs_recipe`.** `recipe` kind; payload emptied on done, failed, expired; planner-only
   recipe jobs; `save_meal_if_unchanged`. pgTAP `68_ai_jobs_recipe`.

## Defaults chosen

- Text 8,000 characters / 24 KB; result ≤ 30 KB (steps trimmed from the end).
- Prep leads clamped 1 to 48 h; ≤ 10 prep steps, 120 characters.
- Planners only; photo, PDF and caption reads only; never a schema.org recipe.
- Watches end 3 days and an hour after the save; up to 3 fresh reads per apply.

## Verification

Swift Testing first (`RecipeStructuringTests`, `RecipeMergeTests`, `RecipePrepTests`, `RecipeApplierTests`,
`AIQueueStoreTests`, `PrepSuggestionsTests`, `AIJobPayloadTests`), then `scripts/test.sh`, the iOS simulator build,
`scripts/sync-strings.sh --check`, and pgTAP (CI's job while local Docker won't start).

## Needs a capable device

- A real `GeneratedRecipe` run through `AIService.live`: quality and time within 30 s.
- End to end on staging: add a dish from a photo on a device that can't run the model, open Foon on a planner's capable
  device, reopen the first and see the dish tidied, with an edited field left alone.

## Open questions

- AI prep steps from a result that lands after the dish is saved aren't offered anywhere (only the editor's keywords are).
- Ideas aren't retitled by a result. A caption the plain parser finds nothing in isn't tidied.
- Custom (Other) allergy text isn't protected in the ingredient merge the way the nine allergens are.
