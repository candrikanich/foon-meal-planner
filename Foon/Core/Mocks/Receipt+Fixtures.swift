import Foundation

/// Receipt text as Vision reads it, one observation per line, modelled on real US grocery receipts. For the matcher's
/// tests and the review screen's previews.
enum ReceiptFixtures {
    static let walmart = [
        "Walmart",
        "Save money. Live better.",
        "( 555 ) 555 - 0123",
        "MANAGER JANE DOE",
        "1234 MAIN ST",
        "SPRINGFIELD OH 45501",
        "ST# 01234 OP# 009012 TE# 12 TR# 04512",
        "BANANAS 000000004011KF 1.23 N",
        "2.04 lb @ 1 lb /0.58",
        "GV WHL MILK 007874235187F 3.48 N",
        "BNLS CHKN BRST 026080000000 9.97 N",
        "GV LG EGGS 18CT 007874213512 4.12 N",
        "ORG BANANAS 000000094011KF 0.88 N",
        "KRAFT MAC CHS 002100065883 1.12 N",
        "BOUNTY PPR TWL 003700074620 15.97 X",
        "SUBTOTAL 36.77",
        "TAX 1 6.750 % 1.08",
        "TOTAL 37.85",
        "VISA TEND 37.85",
        "VISA **** **** **** 4821",
        "APPROVAL # 08233B",
        "REF # 330300445566",
        "CHANGE DUE 0.00",
        "# ITEMS SOLD 7",
        "10/28/26 14:32:07",
        "TC# 2218 9940 1254 6631 8890"
    ]

    static let kroger = [
        "KROGER",
        "Kroger Plus Customer ****1234",
        "2 @ 2.50",
        "CHOBANI YGRT 5.00 B",
        "KRO SHRD CHDR 2.79 B",
        "STRWBRY 1LB 3.99 B",
        "AVOCADOS HASS 1.25 B",
        "1.52 lb @ 1.99 /lb",
        "WT YEL ONIONS 3.02 B",
        "KRO BTR SALTED 4.49 B",
        "SC KROGER SAVINGS 1.00-",
        "BALANCE 20.54",
        "MASTERCARD 20.54",
        "TOTAL SAVINGS 1.00",
        "THANK YOU FOR SHOPPING KROGER"
    ]

    static let target = [
        "TARGET",
        "Springfield - 555-555-0188",
        "GROCERY",
        "212040003 GG SHRD MOZZ NF $3.19",
        "212040117 GG BAGELS PLAIN NF $2.99",
        "071020008 APPLES HONEYCRISP NF $4.49",
        "HOME",
        "081030045 UP&UP DISH SOAP T $2.79",
        "SUBTOTAL $13.46",
        "T = OH TAX 7.25000 on $2.79 $0.20",
        "TOTAL $13.66",
        "*4821 DEBIT TOTAL PAYMENT $13.66",
        "AID: A0000000980840",
        "REDcard Save 5%"
    ]

    static let costco = [
        "COSTCO",
        "WHOLESALE",
        "Member 111222333444",
        "E 1234567 KS ORG EGGS 24 8.99",
        "E 98765 KS PB CRMY 2PK 10.49",
        "E 512345 CHERRY TOMATO 5.99",
        "E 4455 ROTISSERIE CHKN 4.99",
        "SUBTOTAL 30.46",
        "TAX 0.00",
        "**** TOTAL 30.46",
        "XXXXXXXXXXXX4821 CHIP read",
        "AID: A0000000031010",
        "INSTANT SAVINGS 0.00",
        "TOTAL NUMBER OF ITEMS SOLD = 4"
    ]

    static let traderJoes = [
        "TRADER JOE'S",
        "1500 Elm Ave",
        "Store #555 - (555) 555-0199",
        "OPEN 8:00AM TO 9:00PM DAILY",
        "BANANA EACH 0.29",
        "3 @ 0.29",
        "SPAGHETTI ORGANIC 1.49",
        "MARINARA SAUCE 2.49",
        "BABY SPINACH 2.29",
        "BAGGED SALAD 2.99",
        "Items in Transaction:4",
        "Balance to pay $9.26",
        "Visa $9.26",
        "PAYMENT CARD PURCHASE TRANSACTION"
    ]

    static let safeway = [
        "SAFEWAY",
        "Store 1234 Dir Jane Doe",
        "Main: (555) 555-0144",
        "REG 12 ID 45",
        "PRODUCE",
        "LEMONS 0.79 S",
        "MEAT",
        "GRND BF 80/20 1.31 lb @ 5.99 /lb",
        "7.85 S",
        "FROZEN",
        "DIGIORNO PZA 6.99 S",
        "Card Savings 2.00-",
        "TAX 0.00",
        "**** BALANCE 15.63",
        "Your club card savings 2.00"
    ]

    /// A household's items, named as people type them.
    static let items: [ReceiptItem] = [
        "Bananas", "Milk", "Chicken breasts", "Eggs", "Box mac and cheese", "Paper towels", "Yogurt",
        "Shredded cheddar", "Strawberries", "Avocados", "Onions", "Butter", "Shredded mozzarella", "Bagels", "Apples",
        "Dish soap", "Peanut butter", "Cherry tomatoes", "Spaghetti", "Marinara sauce", "Spinach", "Lemons",
        "Ground beef", "Frozen pizza", "Chicken thighs", "Cheese", "Cereal"
    ].enumerated().map { index, name in
        ReceiptItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, name: name)
    }

    static func item(_ name: String) -> ReceiptItem {
        items.first { $0.name == name }!
    }
}
