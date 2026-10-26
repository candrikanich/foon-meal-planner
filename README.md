# Foon

Family dinner planner for iOS. Different tastes. Same table.

Foon takes the weight of dinner off one person and shares it with the whole family: plan the week together, build the shopping list automatically, and log what everyone thought.

- Project rules and stack: [CLAUDE.md](CLAUDE.md)
- Backlog: GitHub Issues, grouped into milestones M0 to M4. `scripts/create_issues.py` files them (`python3 scripts/create_issues.py candrikanich/foon-meal-planner --apply`).

## Development

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The Xcode project is generated from `project.yml` and not committed:

```sh
xcodegen generate      # after cloning, pulling, or adding files
open Foon.xcodeproj
```

Run unit tests (macOS destination, no simulator needed):

```sh
scripts/test.sh
```
