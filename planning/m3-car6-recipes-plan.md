# M3 car 6, part 2: AI recipe capture and prep-step detection (#59)

Builds on #58's queue (`Core/AI`) and #39's capture path (`SharedItemSheet`, `RecipeTextParser`, `TextRecognizer`,
`PrepSuggestions`). Nothing in the non-AI path is replaced: AI only tidies a draft that's already showing.

## Shape

1. **Kind `recipe`.** `AIJobRequest.recipe(RecipeJobPayload)`: the captured text (OCR lines or a social caption) and the
   source link if there is one. Nothing else: no allergies, no members, no household size. `AIJobPayloadTests` walks it.
   The text is cut to 8,000 characters (and 24 KB of UTF-8), which fits the on-device model's 4K-token context with room
   for the instructions and the answer, and fits `ai_jobs`' 32 KB payload cap.
2. **Guided generation.** `GeneratedRecipe` (`@Generable`): name, servings (0 when it doesn't say), ingredients (lines, at
   most 60), steps (at most 50), prep steps (at most 10, each a short step and hours ahead, 1 to 48). The handler calls
   `AIService.generate`, then `StructuredRecipe.init(_:)` trims, drops blanks and enforces the meal's limits, and the
   result is a Codable `StructuredRecipe` (at most 30 KB). Instructions say to use only what the text says.
3. **When the job runs.**
   - The sheet shows the non-AI draft at once, as today, with a "Foon is tidying this up" row.
   - `AIQueueStore.submitRecipe` queues the job. A capable device then claims and runs it in a task the store owns, so
     closing the sheet doesn't cancel the model (which would fail the job). Anywhere else it waits for a family device.
   - Planners only (the same as reading a post's caption), only when there's a non-AI draft, and only for a photo, PDF or
     social caption. A link with a schema.org recipe card is already structured, so it isn't sent.
4. **Never overwriting a person's edit.** When the read draft is made, Foon takes a baseline: a SHA-256 digest of each field
   (name, ingredients, steps, prep steps), normalized the way a saved meal reads back (trimmed, lowercased, numbering
   dropped). When the result arrives, a field is replaced only if its digest still matches the baseline, so anything
   touched by hand, in the sheet or later in the editor or on another phone, stays. A name the person gave (the shared
   title, or typed) has no baseline and is never replaced. Digests mean no recipe text is kept on the device for this.
   - In the sheet: the result merges into the draft being reviewed.
   - Saved before the result came: the job is watched (`RecipeWatch`: job, meal, baseline, when) in UserDefaults. The
     submitting device applies it to the meal when the result arrives (on its own run, or on a foreground load), compared
     with the meal as the library has it now, and saves through `LibraryStore.save`. Only the submitting device applies
     it, so two devices never race to write it.
   - Allergy safety: an ingredient line from the plain read that names one of the nine allergens is kept if the AI's lines
     don't name that allergen, so a model that drops "peanuts" can't drop a flag.
5. **Fallback.** Failed, expired, or gone (not found 3 days and an hour after submitting): the watch is dropped, the mark
   clears, and the plain read stays. Keyword prep detection (`PrepSuggestions`) stays the non-AI path in the editor; it
   now also catches "overnight" (marinate overnight is 12 hours; any other overnight step is "Start the night before", a
   day ahead).
6. **Trimmed queue load.** `AIJobClient.recent` (50 full jobs with payloads, every foreground) becomes `statuses(ids)`:
   `id, kind, status, result, updated_at` for only the jobs this device is waiting on, and no call at all when it's
   waiting on none.
7. **Migration `20261104000000_ai_jobs_recipe`.** Adds `recipe` to the kind check. The guard now empties a job's payload
   (`{}`) when it's done, failed or expired, so the captured text is held only while a device needs it; existing finished
   rows are emptied too. pgTAP `68_ai_jobs_recipe`.

## Defaults chosen

- Text cut at 8,000 characters / 24 KB; result at most 30 KB (steps trimmed from the end to fit).
- Prep lead from the model clamped to 1 to 48 hours; at most 10 prep steps, 120 characters each.
- Planners only; only photo, PDF and caption reads; never a schema.org recipe.
- A watch is dropped 3 days and an hour after submitting if it's never seen finished.
- AI prep steps fill a dish only while its prep steps are as first read (empty from a plain read). They're on the review
  screen to delete before saving; once saved, they make reminders like any other step.

## Verification

Swift Testing first: `RecipeStructuringTests` (payload limits, output parsing and limits, the handler with a stubbed
`AIService`, timeouts), `RecipeMergeTests` (applying, not overwriting edits, a typed name, allergen lines kept),
`AIQueueStoreTests` (own run, watching a saved meal, failure and expiry clear the mark, no load when nothing's watched),
`PrepSuggestionsTests` (overnight), `AIJobPayloadTests` (the new kind). Then `scripts/test.sh`, the iOS simulator build,
`scripts/sync-strings.sh --check`, and pgTAP (CI's job if local Docker won't start).

## Needs a capable device

- A real `GeneratedRecipe` run through `AIService.live`: quality on an OCR'd screenshot and an Instagram caption, and time
  within 30 s.
- End to end on staging: share a photo from a phone that can't run the model, open Foon on a capable one, then reopen the
  first phone and see the meal tidied (and an edited field left alone).

## Open questions

- Ideas aren't retitled by a later result: an idea keeps the name it was saved with, since requests have no title edit
  (that needs a requests RPC change and a rule for whose idea it is).
- A caption the plain parser finds no recipe in isn't sent. AI might find one there; doing that needs a "looking" state
  on an idea.
- Custom allergy text (a parent's Other) isn't protected the way the nine allergens are in the ingredient merge.
