# M3 car 3: one-time tips and "Show tips again" (#63, second half)

The recap half merged as #242. This branch (`feat/63-tips`) adds the tips.

## Approach

- **Apple's TipKit**, a system framework, not a package. `Tips.configure()` runs once, in `FoonApp.init`, with the
  default datastore and `.immediate` display frequency. Tip state stays on the device for whoever is using it, and
  nothing syncs: no CloudKit option, and nothing goes to Supabase.
- **Tips** (`Foon/Features/Tips/FoonTips.swift`). Each shows at most once, before first use:
  - `ShareToFoonTip`: an inline `TipView` at the top of Ideas. It's invalidated (`.actionPerformed`) as soon as the
    app sees anything waiting in `SharedInbox` (`RootTabView.refreshShared`). It doesn't show on the Mac, which has
    no share extension.
  - `StoreModeTip`: a popover on Lists → Shop, only while Shop can open. It's invalidated when store mode opens.
  - **AI pick (car 6):** there's no tip yet. Car 6 adds `case aiPick` to `FoonTip` and a `TipRules` line, plus an
    `AIPickTip` that shows only when `SystemLanguageModel.default.availability == .available`.
- **Rules in Core** (`Foon/Core/Tips/TipRules.swift`). Both are pure and unit-tested:
  - `TipRules.eligible(onMac:canShop:)` decides which tips a screen may offer.
  - `TipReset` holds the pending-reset flag.
- **"Show tips again":** in Family, for everyone. TipKit can only clear its datastore before `configure`, and
  calling it afterwards throws. So the button sets a flag in `UserDefaults`, and the next launch clears the store
  and then configures it. The footer confirms: "Tips come back after you close Foon and open it again."
- **Previews:** the app's previews don't call `configure`, so they show no tips. That's deliberate: screen previews
  look the way they do after the tips are gone. A separate "Tips" preview shows both with `showAllTipsForTesting`.

## Verification

- Swift Testing: `TipRulesTests` covers eligibility, and the reset flag's request, take, and clear.
- `scripts/test.sh`, the iOS simulator build, and `scripts/sync-strings.sh` followed by `--check`.

## Unresolved

- Tips show in every build, TestFlight included: TipKit has no build-type switch. Tips stay hidden until
  `configure` runs, and Foon runs it at every launch.
- Anyone who shared to Foon before this build still sees the share tip once, until their next share. TipKit can't
  tell that they've shared before.
