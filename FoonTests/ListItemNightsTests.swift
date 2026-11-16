import Foundation
import SwiftData
import Testing
@testable import Foon

@MainActor
struct ListItemNightsTests {
    private let household = UUID()

    private func decode(_ json: String) throws -> ListItemRow {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ListItemRow.self, from: Data(json.utf8))
    }

    private func row(embed: String?) -> String {
        let extra = embed.map { ", " + $0 } ?? ""
        return """
        {"id": "00000000-0000-0000-0000-0000000000a1", "household_id": "00000000-0000-0000-0000-0000000000a0",
         "item_id": "00000000-0000-0000-0000-0000000000a2", "list": "weekly", "urgency": "whenever", "source": "plan",
         "note": null, "quantity": "2 cups", "plan_id": null, "checked_at": null, "created_at": null\(extra)}
        """
    }

    @Test func theApproveCallSendsEachLinesNights() throws {
        let (first, second) = (UUID(), UUID())
        let line = WeeklyList.Line(itemID: UUID(), name: "cheese", quantity: "1 cup", forMeals: ["Tacos"], note: nil,
                                   isStaple: false, nightIDs: [second, first])
        let staple = WeeklyList.Line(itemID: UUID(), name: "milk", quantity: nil, forMeals: [], note: nil,
                                     isStaple: true)
        let params = ApproveParams(targetPlan: UUID(), lines: [line, staple])
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        let lines = try #require(body["lines"] as? [[String: Any]])
        #expect(lines[0]["night_ids"] as? [String] == [first, second].map(\.uuidString).sorted())
        #expect(lines[1]["night_ids"] as? [String] == [])
    }

    @Test func theNightsEmbedDecodes() throws {
        let embed = """
        "list_item_nights": [
          {"plan_nights": {"date": "2026-11-06", "meals": {"name": "Tacos"}}},
          {"plan_nights": {"date": "2026-11-03", "meals": {"name": "Chili"}}}
        ]
        """
        let nights = try decode(row(embed: embed)).nights
        #expect(nights == [ListNightRef(date: "2026-11-06", mealName: "Tacos"),
                           ListNightRef(date: "2026-11-03", mealName: "Chili")])
    }

    @Test func aNightWithNoMealStillDecodes() throws {
        let embed = """
        "list_item_nights": [{"plan_nights": {"date": "2026-11-04", "meals": null}}]
        """
        #expect(try decode(row(embed: embed)).nights == [ListNightRef(date: "2026-11-04", mealName: nil)])
    }

    @Test func aLineWithoutTheEmbedHasNoNights() throws {
        #expect(try decode(row(embed: nil)).nights.isEmpty)
        #expect(try decode(row(embed: "\"list_item_nights\": []")).nights.isEmpty)
    }

    @Test func theCacheKeepsNightsSoonestFirst() throws {
        let line = CachedListItem(id: UUID(), householdID: household, itemID: UUID(), itemName: "Cheese", list: .weekly,
                                  urgency: .whenever, source: .plan, note: nil, checkedAt: nil,
                                  nights: [ListNightRef(date: "2026-11-06", mealName: "Tacos"),
                                           ListNightRef(date: "2026-11-03", mealName: nil)])
        #expect(line.nights.map(\.date) == ["2026-11-03", "2026-11-06"])
    }

    @Test func aPullStoresEachLinesNights() async throws {
        let container = try SyncService.inMemoryContainer()
        let item = UUID()
        let nights = [ListNightRef(date: "2026-11-06", mealName: "Tacos"),
                      ListNightRef(date: "2026-11-03", mealName: "Chili")]
        let snapshot = SyncSnapshot(
            plan: nil, nights: [],
            listItems: [ListItemRow(id: UUID(), householdID: household, itemID: item, list: .weekly, urgency: .whenever,
                                    source: .plan, note: nil, checkedAt: nil, nights: nights)],
            items: [ItemRow(id: item, householdID: household, canonicalName: "Cheese", category: .dairyEggs,
                            keepOnHand: false, stockState: nil)]
        )
        let service = SyncService(householdID: household, context: container.mainContext,
                                  client: .fake(snapshot: { snapshot }),
                                  today: { CalendarDay(year: 2026, month: 11, day: 3) })
        await service.pull()
        let stored = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        #expect(stored.first?.nights.map(\.date) == ["2026-11-03", "2026-11-06"])
        #expect(stored.first?.nights.map(\.mealName) == ["Chili", "Tacos"])
    }
}
