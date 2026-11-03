# M3 car 5: receipt scanning, photo half (#61)

Forwarded email receipts are #237 (External TestFlight, needs #48's domain). Not in scope.

## Shape

1. **Lists → Scan a receipt** (anyone in the family, kids too: checking off is open to everyone). Camera (iOS document
   scanner) or a photo pick. The image goes to `TextRecognizer` and is dropped: never uploaded, stored or cached.
2. **`Core/Receipts/ReceiptMatcher`** (pure): receipt text lines → candidate lines (prices, totals, tax, card, store,
   address, quantity and weight lines dropped) → normalized key → learned alias first, else abbreviation table plus token
   and subsequence similarity against the household's item names → best item and a confidence.
3. **`receipt_aliases`** (household, normalized raw text, item, created_by, updated_at; unique on household + raw text).
   RLS through `is_household_member`, read and write for members, no delete grant. Written through
   `teach_receipt_alias` (security invoker upsert, like `ensure_item`), queued in the offline sync queue as
   `OfflineChange.teachReceiptAlias`. pgTAP proves another household can't read or write.
4. **Review before anything changes** (`ReceiptReview`, pure): matched lines with their item (change it or skip it),
   "Didn't recognize" lines skipped by default (assign to an item, or type a new one through `ensure_item`).
   Confirm → `ReceiptApply.changes`: check off each item's open lines (`ListBoard.gotIt`, which restocks a staple) or, for
   a staple not on a list, a restock; then an alias for each corrected line. All through `SyncService.perform`.
5. **Staple suggestions** (`ReceiptStaples`, pure): an item bought on this receipt that isn't keep-on-hand and was checked
   off a list between 30 days and 1 day ago (a different trip), at most 3, in receipt order. "Keep apples on hand?" Yes
   / Not now. The history comes from `list_items` when online; offline there are no suggestions.
6. No `receipts` / `receipt_lines` tables: nothing in the criteria needs them, and minimal data wins. Spec updated.

## Verification

Unit tests first (matcher with Walmart, Kroger, Target, Costco, Trader Joe's, Safeway fixtures; review; apply;
staples), pgTAP for the table and RPC, `scripts/test.sh`, iOS build, sync-strings, `supabase db reset` + `test db`.

## Open questions

- Should "Not now" be remembered so the same staple isn't offered on every receipt? v1: per scan only.
- Learned aliases are fetched when the scan starts; offline, only the built-in matcher runs.
