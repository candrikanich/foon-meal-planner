import Foundation
import SwiftUI

extension MemoryLog {
    /// A few weeks of logged dinners ending on `through`: dishes most nights, leftovers and takeout now and then, and
    /// an eat-out night the timeline leaves out.
    static func samples(through: CalendarDay, nights: Int = 21) -> [MemoryLog] {
        let dishes = ["Taco night", "Sheet-pan chicken", "Pot roast", "Spaghetti and meatballs", "Veggie stir-fry"]
        return (0..<nights).map { offset in
            let pick: QuickPick? = switch offset % 7 {
            case 3: .leftovers
            case 5: .takeout
            case 6: .eatOut
            default: nil
            }
            return MemoryLog(nightID: UUID(), date: through.adding(days: -offset), dinnerTime: "18:00:00",
                             mealName: pick == nil ? dishes[offset % dishes.count] : nil, quickPick: pick,
                             hasMeal: pick == nil, approved: true)
        }
    }
}

extension PhotoLibrarySource {
    /// Placeholder pictures, a different number most nights and none on some, so previews never touch the library.
    static func preview(access: PhotoAccess = .full) -> PhotoLibrarySource {
        PhotoLibrarySource(
            access: { access },
            requestAccess: { .full },
            photos: { windows in
                windows.enumerated().flatMap { index, window in
                    (0..<[3, 0, 8, 1, 0, 2][index % 6]).map { shot in
                        PhotoStamp(id: "preview-\(index)-\(shot)",
                                   createdAt: window.start.addingTimeInterval(TimeInterval(1800 + shot * 300)))
                    }
                }
            },
            image: { id, _ in
                let symbols = ["fork.knife", "carrot", "takeoutbag.and.cup.and.straw", "birthday.cake",
                               "cup.and.saucer"]
                return Image(systemName: symbols[id.count % symbols.count])
            }
        )
    }
}
