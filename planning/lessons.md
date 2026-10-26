# Lessons

## Core (Recurring)

_None yet._

## Patterns

### Stacked PRs merge into their stacked base, not main
**Times seen:** 1

**What happened (2026-10-26):** #70 targeted `feat/1-xcode-project` and #71 targeted `feat/3-supabase-setup`. #69 merged to `main` first, but its branch wasn't deleted, so GitHub never retargeted #70. Both later PRs merged into feature branches and never reached `main`. Recovery took an extra PR (#73).

**Rule:** In this repo, don't stack PRs. Branch the next ticket from `main` plus the unmerged branch it needs (`git merge origin/<branch>`), and open its PR against `main`. Until the earlier PR merges, the later one's diff shows those commits too. If you do stack, tell Chris the exact merge order, and say that each base branch must be deleted on merge for GitHub to retarget the next PR.
