import SwiftUI
import WidgetKit

/// Tonight's dinner on the home and lock screens (#62), from the snapshot the app last wrote. A dish is something the family
/// typed, so it's private: a locked phone (the lock screen, StandBy) hides it and shows the time alone.
struct TonightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TonightSnapshot.widgetKind, provider: TonightProvider()) { entry in
            TonightWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("Tonight's dinner"))
        .description(Text("What's for dinner tonight, from your family's plan."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TonightEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written one: never opened, or signed out.
    let snapshot: TonightSnapshot?

    var tonight: TonightSnapshot.Night? { night(daysAhead: 0) }
    var tomorrow: TonightSnapshot.Night? { night(daysAhead: 1) }

    private func night(daysAhead: Int) -> TonightSnapshot.Night? {
        guard let snapshot else { return nil }
        let calendar = snapshot.calendar
        return snapshot.night(on: CalendarDay(date, calendar: calendar).adding(days: daysAhead, calendar: calendar))
    }
}

struct TonightProvider: TimelineProvider {
    func placeholder(in context: Context) -> TonightEntry {
        TonightEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TonightEntry) -> Void) {
        completion(TonightEntry(date: .now, snapshot: context.isPreview ? .preview : TonightFile.shared?.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TonightEntry>) -> Void) {
        let snapshot = TonightFile.shared?.load()
        let dates = snapshot?.refreshDates(from: .now) ?? [.now]
        // The app reloads the timeline whenever it writes; past the last night it has, there's nothing to change to.
        completion(Timeline(entries: dates.map { TonightEntry(date: $0, snapshot: snapshot) }, policy: .never))
    }
}

struct TonightWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TonightEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Tonight").font(.headline).widgetAccentable()
                NightTitle(night: entry.tonight, hasSnapshot: entry.snapshot != nil)
                    .font(.body)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                NightColumn(label: Text("Tonight"), night: entry.tonight, hasSnapshot: entry.snapshot != nil)
                Divider()
                NightColumn(label: Text("Tomorrow"), night: entry.tomorrow, hasSnapshot: entry.snapshot != nil)
            }
        default:
            NightColumn(label: Text("Tonight"), night: entry.tonight, hasSnapshot: entry.snapshot != nil)
        }
    }

    @ViewBuilder private var inline: some View {
        if entry.snapshot == nil {
            Text("Open Foon to see the plan")
        } else if let night = entry.tonight, let title = night.title {
            if night.isDish {
                Text("Tonight: \(title)").privacySensitive()
            } else {
                Text("Tonight: \(title)")
            }
        } else if entry.tonight?.isAway == true {
            Text("Tonight: away")
        } else {
            Text("Tonight: nothing planned yet")
        }
    }
}

private struct NightColumn: View {
    let label: Text
    let night: TonightSnapshot.Night?
    let hasSnapshot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            NightTitle(night: night, hasSnapshot: hasSnapshot)
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let time = night.flatMap(\.dinnerTime).flatMap(DinnerTimeText.init) {
                Label(time.text, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NightTitle: View {
    let night: TonightSnapshot.Night?
    let hasSnapshot: Bool

    var body: some View {
        if let night, let title = night.title {
            if night.isDish {
                Text(title).privacySensitive()
            } else {
                Text(title)
            }
        } else if night?.isAway == true {
            Text("Away")
        } else if hasSnapshot {
            Text("Nothing planned yet")
        } else {
            Text("Open Foon to see the plan")
        }
    }
}

/// "18:30" from the plan, in the phone's own time style ("6:30 PM").
private struct DinnerTimeText {
    let text: String

    init?(_ time: String) {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, let date = Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1]))
        else { return nil }
        text = date.formatted(date: .omitted, time: .shortened)
    }
}

extension TonightSnapshot {
    /// For the widget gallery and previews.
    static var preview: TonightSnapshot {
        let calendar = Calendar.current
        let today = CalendarDay(.now, calendar: calendar)
        return TonightSnapshot(householdID: UUID(), timeZone: calendar.timeZone.identifier, nights: [
            Night(date: today, title: String(localized: "Sheet-pan chicken fajitas"), isDish: true, dinnerTime: "18:30"),
            Night(date: today.adding(days: 1, calendar: calendar), title: String(localized: "Takeout"),
                  dinnerTime: "18:00"),
        ])
    }
}

#Preview("Small", as: .systemSmall) {
    TonightWidget()
} timeline: {
    TonightEntry(date: .now, snapshot: .preview)
    TonightEntry(date: .now, snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    TonightWidget()
} timeline: {
    TonightEntry(date: .now, snapshot: .preview)
}

#Preview("Lock screen", as: .accessoryRectangular) {
    TonightWidget()
} timeline: {
    TonightEntry(date: .now, snapshot: .preview)
}

#Preview("Inline", as: .accessoryInline) {
    TonightWidget()
} timeline: {
    TonightEntry(date: .now, snapshot: .preview)
}
