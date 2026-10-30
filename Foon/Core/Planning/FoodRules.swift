import Foundation

/// A recurring rule the household keeps about what's for dinner (docs/spec.md → Food rules). It belongs to the household
/// and says nothing about why: no religion or diet is recorded about anyone.
struct FoodRule: Codable, Hashable, Sendable {
    /// What a rule can recognize. Kosher and halal aren't here: they turn on how food was prepared, and no dish name can
    /// honestly promise that.
    enum Avoid: String, Codable, CaseIterable, Hashable, Sendable {
        case meat, pork, shellfish

        var title: String {
            switch self {
            case .meat: String(localized: "Meat", comment: "Food rule: what the household skips. Fish doesn't count")
            case .pork: String(localized: "Pork", comment: "Food rule: what the household skips")
            case .shellfish: String(localized: "Shellfish", comment: "Food rule: what the household skips")
            }
        }
    }

    enum Nights: String, Codable, CaseIterable, Hashable, Sendable {
        case lentFridays = "lent_fridays"
        case fridays
        case everyNight = "every_night"

        var title: String {
            switch self {
            case .lentFridays: String(localized: "Fridays in Lent", comment: "Food rule: which nights it applies")
            case .fridays: String(localized: "Fridays", comment: "Food rule: which nights it applies")
            case .everyNight: String(localized: "Every night", comment: "Food rule: which nights it applies")
            }
        }

        func include(_ day: CalendarDay) -> Bool {
            switch self {
            case .lentFridays: Lent.isFridayInLent(day)
            case .fridays: day.isoWeekday == 5
            case .everyNight: true
            }
        }
    }

    let avoid: Avoid
    let nights: Nights

    private enum CodingKeys: String, CodingKey {
        case avoid
        case nights = "when"
    }

    func applies(on day: CalendarDay) -> Bool {
        nights.include(day)
    }

    /// On a card or in Swap. "Looks like": Foon only has the name and ingredients to go on, so this is a guess, and the
    /// planner decides. Nothing ever says a dish is free of anything.
    var looksLikeText: String {
        switch (avoid, nights) {
        case (.meat, .lentFridays): String(localized: "Looks like it has meat: Fridays in Lent", comment: "Food rule badge")
        case (.meat, .fridays): String(localized: "Looks like it has meat: Fridays", comment: "Food rule badge")
        case (.meat, .everyNight): String(localized: "Looks like it has meat", comment: "Food rule badge")
        case (.pork, .lentFridays): String(localized: "Looks like it has pork: Fridays in Lent", comment: "Food rule badge")
        case (.pork, .fridays): String(localized: "Looks like it has pork: Fridays", comment: "Food rule badge")
        case (.pork, .everyNight): String(localized: "Looks like it has pork", comment: "Food rule badge")
        case (.shellfish, .lentFridays):
            String(localized: "Looks like it has shellfish: Fridays in Lent", comment: "Food rule badge")
        case (.shellfish, .fridays): String(localized: "Looks like it has shellfish: Fridays", comment: "Food rule badge")
        case (.shellfish, .everyNight): String(localized: "Looks like it has shellfish", comment: "Food rule badge")
        }
    }

    /// Reads the list leniently: a rule from a newer app is skipped here, and left alone on the server.
    struct Lenient: Decodable {
        let rule: FoodRule?

        init(from decoder: Decoder) throws {
            rule = try? FoodRule(from: decoder)
        }
    }
}

/// Lent's dates, worked out from Easter (Western, Gregorian), so nothing needs updating each year. Orthodox Lent runs on a
/// different calendar and isn't offered.
enum Lent {
    /// Easter Sunday: the anonymous Gregorian algorithm (Meeus/Jones/Butcher). Pure and exact for every year on that
    /// calendar.
    static func easter(year: Int) -> CalendarDay {
        let golden = year % 19
        let (century, yearOfCentury) = (year / 100, year % 100)
        let correction = (century - century / 4 - (century - (century + 8) / 25 + 1) / 3 + 19 * golden + 15) % 30
        let weekdayShift = (32 + 2 * (century % 4) + 2 * (yearOfCentury / 4) - correction - yearOfCentury % 4) % 7
        let offset = (golden + 11 * correction + 22 * weekdayShift) / 451
        let monthAndDay = correction + weekdayShift - 7 * offset + 114
        return CalendarDay(year: year, month: monthAndDay / 31, day: monthAndDay % 31 + 1)
    }

    /// Ash Wednesday is 46 days before Easter; Good Friday, two.
    static func isFridayInLent(_ day: CalendarDay) -> Bool {
        guard day.isoWeekday == 5 else { return false }
        return (-46)...(-2) ~= day.days(since: easter(year: day.year))
    }
}

/// Reads a dish's name and ingredients for what a food rule cares about, by keyword, never by AI, as allergy flags do. It
/// can miss what it can't read (a family's "Sunday special"), and can over-match, which only holds a dish back from
/// what Foon picks on its own. So it may say a dish looks like it has meat, and never that it doesn't.
enum FoodRuleMatcher {
    /// A dish's name, its ingredients and its sides: what's served, as allergy flags count it.
    static func looksLikeIt(_ avoid: FoodRule.Avoid, meal: LibraryMeal, library: [LibraryMeal]) -> Bool {
        let lines = [meal.name] + ShoppingLines.lines(for: meal, library: library).map(\.name)
        return lines.contains { line in
            let words = Words(line)
            return switch avoid {
            case .meat: meat.isFound(in: words)
            case .pork: pork.isFound(in: words)
            case .shellfish: AllergyMatcher.allergens(in: line).contains(.shellfish)
            }
        }
    }

    /// The rules this dish looks to break on that night.
    static func broken(by meal: LibraryMeal, on day: CalendarDay, rules: [FoodRule], library: [LibraryMeal]) -> [FoodRule] {
        rules.filter { $0.applies(on: day) && looksLikeIt($0.avoid, meal: meal, library: library) }
    }

    /// What Swap lists apart, for the planner to pick anyway: in rotation, not in the week already (tonight's own dish
    /// included, like the suggestions), and looking to break a rule that night.
    static func heldBack(on night: WeekNight, week: [WeekNight], meals: [LibraryMeal],
                         rules: [FoodRule]) -> [(meal: LibraryMeal, rules: [FoodRule])] {
        let planned = Set(week.compactMap(\.mealID))
        return meals.filter { $0.status.isInRotation && !planned.contains($0.id) }.sorted { $0.name < $1.name }
            .compactMap { meal in
                let broken = broken(by: meal, on: night.date, rules: rules, library: meals)
                return broken.isEmpty ? nil : (meal, broken)
            }
    }

    /// "Veggie burger" isn't a burger; "beef and veggie stir fry" is still beef. Only the word right after one of these.
    private static func notReally(_ words: [String]) -> [String] {
        let standIns = ["vegan", "vegetarian", "veggie", "meatless", "plant based", "soy", "tofu", "impossible",
                        "beyond", "mock", "faux"]
        return standIns.flatMap { standIn in words.map { "\(standIn) \($0)" } }
    }

    /// Generous on purpose: hot dogs, meatballs and ribs are often something else, but a false positive only holds a dish
    /// back, and Swap still offers it.
    private static let porkWords = [
        "pork", "ham", "bacon", "pancetta", "prosciutto", "sausage", "brat", "bratwurst", "kielbasa", "chorizo",
        "salami", "pepperoni", "carnitas", "lard", "spam", "blt", "rib", "hot dog", "hotdog", "meatball",
    ]

    private static let otherMeatWords = [
        "meat", "beef", "steak", "burger", "hamburger", "cheeseburger", "meatloaf", "pot roast", "brisket",
        "sloppy joe", "shepherds pie", "cottage pie", "french dip", "sirloin", "ribeye", "chuck roast",
        "veal", "lamb", "mutton", "goat", "venison", "bison", "pastrami", "carne asada", "barbacoa",
        "bolognese", "gyro", "shawarma", "kebab", "kabob", "chicken", "turkey", "duck", "goose", "wings", "drumstick",
    ]

    private static let pork = DishTraits.Keywords(
        porkWords,
        except: notReally(porkWords) + [
            "chicken sausage", "turkey sausage", "beef sausage", "turkey bacon", "turkey ham", "turkey pepperoni",
            "beef bacon", "beef pepperoni", "ham radio", "turkey meatball", "chicken meatball", "beef meatball",
            "beef hot dog", "turkey hot dog", "chicken hot dog", "beef rib", "short rib", "celery rib",
            "hot dog bun", "hotdog bun", "hot dog roll",
        ]
    )

    private static let meat = DishTraits.Keywords(
        porkWords + otherMeatWords,
        except: notReally(porkWords + otherMeatWords) + [
            // Fish and shellfish aren't meat here, which is the point of a Lent Friday.
            "crab meat", "lobster meat", "tuna steak", "salmon steak", "fish steak", "swordfish steak", "halibut steak",
            "salmon burger", "fish burger", "tuna burger", "shrimp burger",
            "black bean burger", "bean burger", "mushroom burger", "portobello burger", "cauliflower steak",
            "cabbage steak", "coconut meat", "nut meat", "meat free",
            // Buns, sauces and seasonings named after what they go with.
            "hamburger bun", "burger bun", "hot dog bun", "hotdog bun", "hot dog roll", "steak sauce", "steak seasoning",
            "chicken seasoning", "turkey seasoning", "poultry seasoning", "sausage seasoning", "duck sauce",
            "beef tomato", "goat cheese", "goat milk", "lambs lettuce", "celery rib", "chicken of the woods",
        ]
    )
}
