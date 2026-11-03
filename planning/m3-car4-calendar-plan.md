# M3 car 4: calendar awareness (#64)

On-device, read-only, off by default. A busy evening gets a suggestion to mark the night rushed. Nothing changes until a planner taps it.

## Pieces
1. `Core/Planning/CalendarBusy.swift` is a pure function. `BusyEvent` holds start, end, all-day, free and declined, with no titles. The dinner window runs from 90 minutes before dinner to 60 after, on the household's clock (constants). `suggestions(events, nights, settings, now, dismissed) -> Set<nightID>`, and `readRange` gives the stretch to read (nil means don't read). Tests: `FoonTests/CalendarBusyTests.swift`.
2. `Features/Week/CalendarSource.swift` puts EventKit behind closures (the `ReminderCenter` pattern): access, `requestFullAccessToEvents`, and events in a range mapped straight to `BusyEvent`.
3. `Features/Week/CalendarBusyStore.swift` keeps the per-device switch and the dismissed night ids in UserDefaults. Events live in memory only, and turning it off drops them. Tests: `FoonTests/CalendarBusyStoreTests.swift` with a stub source.
4. UI:
   - Family → "Spot busy evenings" (planners only), with a Settings link when access is refused.
   - On the DayCard, a "Busy evening? Mark it rushed" chip plus a dismiss button.
   - In night detail, the same in the Effort section.
   - Accepting goes through `WeekStore.setEffort`.
5. Reads happen on This Week's load, on coming back to the foreground, when the switch changes, and when the week changes. Build my week never reads.
6. Permissions:
   - `NSCalendarsFullAccessUsageDescription` in project.yml, regenerated into Info.plist by XcodeGen.
   - `ENABLE_RESOURCE_ACCESS_CALENDARS` for the Mac sandbox.
   - No privacy manifest change: EventKit isn't a required-reason API, and no data is collected.
7. Docs: the spec's "Calendar awareness (#64)", the roadmap tick, App Store privacy notes, and a line in the What Foon keeps screen.

## Unresolved
- Per-calendar choice isn't built (all event calendars count).
- The window isn't a setting.
- The permission string isn't localized: the project has no InfoPlist.xcstrings yet.
