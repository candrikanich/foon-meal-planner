# Lessons

## Core (Recurring)

_None yet._

## Patterns

### A default that lands earlier breaks rules written for an answer
**Times seen:** 1

**What happened (2026-10-30):** On #152, a claim filled in who cooked on the first rating. On main, a cook only existed after the follow-up was saved, and "a thanks locks the cook" assumed that. So a thanks could lock a guess, the follow-up failed with a false connection error, and the wrongly credited person had no way to fix it. The tests asserted the silent no-op as correct.

**Rule (derived data):** When a value that used to come from a person starts being filled in by a default, list everything that reads or locks it, and ask of each: "is this still true of a guess?" Give the person it names a way to correct it. Read the extra paths with a stale phone in mind too.

### Read the checks before merging; never chain the merge after them
**Times seen:** 1

**What happened (2026-10-29):** I ran `gh pr checks 124 && gh pr merge 124 --merge`. The Apple job had failed (a test hung until the 30-minute timeout), but the merge still ran, and #124 landed on main with red CI. The hang was a race in a part-2 test (`anOlderLoadFinishingLastIsIgnored`), fixed in the next PR.

**Rule (merging):** Run `gh pr checks <n>` on its own and read every line. Merge in a separate command, only when every check says `pass`. A `fail` or `cancelled` line stops the merge, whatever the exit code says.

### Async tests with gates: wait for the parked signal, don't yield and hope
**Times seen:** 1

**What happened:** `Task { await slowLoad() }; await Task.yield(); await fastLoad()` assumed the slow task started first. On a busy CI runner it didn't, so the "fast" load took the stalling path and the test hung forever.

**Rule (async tests):** When one task must be inside a gate before the next step, have it signal (`AsyncStream` yield) once it's parked, and `for await` that signal. `finish()` the gate stream at the end, so nothing can wait on it forever.

### Stacked PRs merge into their stacked base, not main
**Times seen:** 1

**What happened (2026-10-26):** #70 targeted `feat/1-xcode-project` and #71 targeted `feat/3-supabase-setup`. #69 merged to `main` first, but its branch wasn't deleted, so GitHub never retargeted #70. Both later PRs merged into feature branches and never reached `main`. Recovery took an extra PR (#73).

**Rule (stacking):** In this repo, don't stack PRs. Branch the next ticket from `main` plus the unmerged branch it needs (`git merge origin/<branch>`), and open its PR against `main`. Until the earlier PR merges, the later one's diff shows those commits too. If you do stack, tell Chris the exact merge order, and say that each base branch must be deleted on merge for GitHub to retarget the next PR.

### The spec in this repo is the source of truth
**Times seen:** 1

**What happened (2026-10-26):** On #75 I treated `docs/spec.md` as a read-only export and asked Chris to update a "living doc" elsewhere. Chris: "the spec doc in this repo is the source of truth... you have complete access to maintain that source of truth."

**Rule:** When a decision changes product behavior (roles, permissions, flows), update `docs/spec.md` in the same PR. Never point Chris at another copy.
