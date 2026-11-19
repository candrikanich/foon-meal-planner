# Foon design system: Quiet Kitchen

The rules every screen follows. Code lives in `Foon/DesignSystem/` (`Theme.swift`, `Components.swift`); the Foon QA
app shows all of it on one screen: Family → **Design gallery** (Debug and Foon QA builds only, `DesignGallery.swift`).
Round 1 (2026-11) converts the whole app to these rules; round 2 tunes them from QA feedback. When a rule here
changes, change the code and the gallery in the same PR.

Quiet Kitchen in one line: **a calm cream page, white cards, one paprika action, weight (not color) for hierarchy.**

## Color

Use the role, never a raw color. Every pair below meets WCAG AA in light and dark (asset catalog has both).

| Token | Role | Never |
|---|---|---|
| `Palette.cream` | Screen background, behind every list, form and scroll view | Card or row fill |
| `Palette.cardSurface` | Cards, list rows, sheets' grouped content | Screen background |
| `Palette.ink` | Primary text and icons | |
| `.secondary` | Supporting text: subtitles, counts, footers | Anything tappable alone |
| `Palette.paprika` | The one main action, app tint, "Tonight", selection | Body text, decoration, warnings |
| `Palette.onPaprika` | Text/icons on a paprika fill | |
| `Palette.herb` | Reasons ("Nora's favorite"), success, "Home" | Buttons |
| `Palette.caution` | Allergy flags, warnings, needs-attention | Anything else, so it keeps meaning |
| `.red` (system) | Errors and destructive buttons only | |

Tints at 14% opacity (`tint.opacity(0.14)`) are the only background a colored label gets (chips, tinted pills).

## Type

SF Pro only; all styles are Dynamic Type text styles, so they scale.

| Token | Use |
|---|---|
| `.foonLargeTitle` | Screen titles (via the system large title) and the tonight hero's dish |
| `.foonTitle` | A card's main line, sheet titles |
| `.foonHeadline` | Section headers, row titles that need weight, buttons |
| `.foonBody` | Everything people read |
| `.foonCaption` | Chips, badges, metadata |

Hierarchy comes from weight and `.secondary`, not from extra sizes or colors. No all-caps text.

## Spacing and shape

Spacing steps (`Spacing`): **xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32**. Pick a step, never a number between.

- Inside a chip or pill, icon to label: `xs`. Items in a row (chips, buttons): `s`. Lines inside a card or row: `m`.
- Card padding and screen margins: `l`. Between cards and sections: `xl`. Around empty states: `xxl`.

Radii (`Radius`): **small 8** (thumbnails, swatches) · **medium 14** (chips that wrap, fields, inner panels,
reaction tiles) · **card 20** (cards, `.continuous`). Pills are capsules, avatars circles. Flat: no shadows, no
borders on cards.
Tap targets are at least 44 pt (`Metrics.minTapHeight`).

## Components

| Component | When | Rule |
|---|---|---|
| `foonGrouped()` + `foonRows()` | Every system `List`/`Form` | `foonGrouped()` on the list, `foonRows()` on a `Group` around its content. Both, always: in dark mode system rows vanish into cream. |
| `.foonCard()` | Custom content on a scroll view: tonight hero, recaps, prompts | One idea per card. Cards don't nest. |
| `.foonInset()` | A panel set into a card: quoted or shared text, a note | Cream fill, `Radius.medium`, `m` padding. Never a system gray (`.quaternary`): cold in light, invisible in dark |
| `.pill(.prominent)` | The one main action on a screen or card | At most one per card, one per screen above the fold. Two timers or two answers are tinted |
| `.pill(.tinted)` | Actions beside the main one | Up to 2 beside a prominent; more go behind **More** (a `Menu`) |
| `fullWidth: true` | A card's or step's closing action, an action alone on a clear row (Agree, Start cooking), or an equal pair (Back / Next) | Fills what its row leaves: the hero's View meal stretches beside a hugging Swap. Pills inside a card's body (Show me) hug their label |
| Plain/system buttons | Toolbar, rows, inline links | Toolbar items use SF Symbols with an accessibility label |
| `Chip` | Reasons, badges, effort, allergy flags | Text first, icon optional; caution tint only for allergies/warnings |
| `AllergyChips` | Wherever a dish is offered | Never hidden behind a tap |
| `EffortMenu` | A night's effort | A menu for planners, a plain pill for everyone else |
| `UnderlineTabs` | Two to four peer views of one thing (This week / Next week) | Not for navigation between screens; use the tab bar |
| `SectionHeader` | Section titles on scroll views | In lists, use the section `header:` (prominence comes from `foonRows()`) |
| `ContentUnavailableView` | Empty states | Icon, one-line title, one sentence, at most one pill action |
| `MemberAvatar` | People | Never a photo of a person (CLAUDE.md, minimal data) |

## Screen templates

1. **Main tab** (This Week, Library, Lists, Ideas, Family): system `NavigationStack` large title; the main action
   in the toolbar (`.primaryAction`), a subtitle via `navigationSubtitle` when there's a useful count; system
   floating tab bar. Don't hand-roll headers.
2. **Grouped list / settings** (Family, Kitchen, member screens, most sheets): system `List`/`Form` with
   `foonGrouped()` + `foonRows()`. Give a section a header when it groups different things, and a footer when a setting needs a sentence of why; a section that explains itself needs neither.
3. **Card feed** (This Week, recaps): `ScrollView` on cream, `Spacing.xl` between cards, `Spacing.l` margins.
4. **Sheet**: `NavigationStack` inside, inline title, Cancel (leading) and the action (trailing, bold); grouped
   content follows template 2. Show the grabber when the sheet has detents.

## Imagery

No meal photos (decided 2026-11-15; #346 takes them off every screen and updates the spec): dishes are text and chips. Dinner
memories (photos read on the device) are the one place photos appear.

## Motion

System animations only: `.snappy` for selection changes, default for navigation. Respect Reduce Motion; no
decorative animation.

## Accessibility (every screen)

- Dynamic Type through accessibility sizes: rows that sit side by side stack (`ViewThatFits` or
  `dynamicTypeSize.isAccessibilitySize`), text never truncates to one line where it matters.
- VoiceOver: every control has a label; combined rows read as one sentence; headers have `.isHeader`.
- Light and dark previews for every new view, plus one at an accessibility size.

## Copy

Short, warm, plain. Sentence case everywhere. Rate the dish, never the cook. Name the button for what it does
("Add to list", not "OK"). Footers explain why in a sentence; no exclamation marks.

## Round 2

Design tweaks found in QA go in one tracking issue and are applied here first, then in code and the gallery.

Round 2 (#357, 2026-11-19) settled round 1's open layout calls from the Figma screens made so far; Chris reviews them
against fuller Figma screens later:

- **Full-width pills** stay where Figma put them (the hero's View meal) and where a pill closes a card, a step or a
  clear row. Rule above.
- **Onboarding showcase** stays a card feed (template 3): each card is one thing to try, which is what cards are for.
- **Inner panels** use `.foonInset()` instead of `.quaternary`.
- **One prominent per screen:** Cook mode's timers went tinted; Next is the page's main action.
- **Reaction tiles** use the tokens (`s`/`xs` spacing, `Radius.medium`) and the effort pill's fill.
- **Previews:** This Week, Cook mode, meal detail, the showcase and onboarding each have dark and accessibility-size
  previews. The Tonight sheet's look waits on #335.
