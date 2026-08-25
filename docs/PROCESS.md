# Working process for this Loop fork

How work should be carried out on this repo in future requests. Follow these steps
every time so changes stay safe, consistent, and verifiable. This is a **personal
self-built fork** of Loop (an automated insulin-dosing app) — correctness and
non-regression matter more than speed.

## The loop to follow, every request

1. **Orient.** Read the relevant files fully before editing. Check `HANDOFF.md`,
   `docs/DESIGN_SYSTEM.md`, and this file. Skim `git status` so you know what other
   uncommitted work is in flight and don't step on it.
2. **Plan + track.** For anything non-trivial (3+ steps), create a task list and
   keep it updated (in_progress → completed as you go).
3. **Implement in small, reviewable edits.** Match surrounding style, comment
   density, and naming. Reuse the design-system primitives (never hardcode radii,
   tints, or the press animation — see `DESIGN_SYSTEM.md`).
4. **Build to verify.** ALWAYS build against a concrete simulator device, never the
   generic destination (see "Build gotcha" below). Zero errors before calling done.
5. **Document.** Update `docs/WORKLOG.md` with what changed and why, update
   `DESIGN_SYSTEM.md` if you introduced/altered a shared visual rule, and update
   `HANDOFF.md`'s status.
6. **Report honestly.** State what was verified (built? ran? just compiled?) and
   what wasn't. Don't claim runtime-tested if only compiled.

## Build gotcha (important)

Build with a concrete device:

```
xcodebuild -workspace LoopWorkspace.xcworkspace -scheme Loop \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

Use `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO`, **not**
`CODE_SIGNING_ALLOWED=NO`. The latter compiles fine but produces an app with no
entitlements, which aborts at launch in
`INPreferences.assertThisProcessHasSiriEntitlement` before any UI appears — so
you can build but never run it, and re-signing the built `.app` afterwards does
not fix it.

Do **not** use `-destination "generic/platform=iOS Simulator"`. It resolves to
x86_64, but this checkout's DerivedData holds an arm64-only `LoopKit.framework`
(and LoopKit isn't in the Loop scheme's build graph, so it's never rebuilt to
reconcile). The mismatch makes every LoopKit type fail with "cannot find type X in
scope" — a false failure unrelated to your change.

Builds take several minutes (large workspace, many submodules). Run them in the
background and keep working.

## Repo shape / conventions

- Submodules: the app is `Loop/`, shared UI/model is `LoopKit/` (both already carry
  local fork edits — editing either is expected here).
- Project files ARE explicitly listed in `Loop.xcodeproj/project.pbxproj`. Adding a
  NEW source/resource file requires registering it (there's a `pbxproj` Python
  helper approach documented in `HANDOFF.md`). Editing existing files needs nothing.
  Prefer adding to an already-compiled file over creating a new one when reasonable.
- Localize every user-facing string.
- New features: additive, opt-in, with a kill-switch; off must equal today's behavior.
- Secrets → Keychain, never UserDefaults.
- Before any destructive git op, `git status` first and stash/commit; only commit or
  push when explicitly asked.

## Where things live

- Design system: `Loop/AICarbEstimation/UI/GlassStyles.swift`,
  `LoopKit/LoopKitUI/Views/ActionButtonStyle.swift`.
- AI carb estimation feature: `Loop/AICarbEstimation/**`.
- Custom alert sounds: `Loop/Managers/Alerts/LoopSoundVendor.swift`,
  `Loop/CustomAlertSounds/*.caf`.
- Meal entry screen + flow: `Loop/AICarbEstimation/MealEntry/**`.
- Toolbar pass-through hit-testing: `PassthroughToolbar` in
  `Loop/View Controllers/RootNavigationController.swift` (installed via `customClass`
  on the toolbar in `Main.storyboard`).

## Knowledge graph (graphify)

The graph lives at **`BuildLoop/graphify-out/`** (the repo's parent), and its scan root is
the `Loop/` app directory — see `graphify-out/.graphify_root`. Query it from `BuildLoop`,
where `graphify-out/graph.json` is the tool's default path.

Refresh after meaningful code changes:

```
cd <BuildLoop>
graphify update Loop-260609-1904/LoopWorkspace/Loop
```

**Quirk worth knowing:** `graphify update <path>` writes its output to
`<path>/graphify-out` — i.e. *inside* the scan root — not to the directory you ran it
from. After a refresh, move `graph.json`, `GRAPH_REPORT.md`, `.graphify_labels.json` and
`cache/` up to `BuildLoop/graphify-out/` and delete the copy inside `Loop/`, so there is
exactly one graph and it isn't sitting in its own corpus.

`graphify update` is AST-only and needs no LLM or API key. `graph.html` is not generated
above 5,000 nodes (the graph is ~6k), so there is no HTML view — use
`graphify explain "X"` / `graphify path "A" "B"` instead.
