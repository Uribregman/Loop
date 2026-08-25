# Handoff — Loop fork, custom alert sounds

Written 2026-07-08, updated 2026-08-16. Verify against current `git status` before
trusting details below if time has passed.

**See also (added 2026-07-16):** `docs/DESIGN_SYSTEM.md` (roundness/tints/animation
spec — read before touching UI), `docs/PROCESS.md` (how to work on this repo),
`docs/WORKLOG.md` (chronological change history).

## There is now a second app: Loop Follow (2026-08-15)

A read-only follower app lives at `<repo root>/../../loop follow/` — outside this
workspace, its own Xcode project, its own bundle id
(`com.bregmanuri.LF.loop-follow`). **It has its own handoff:
`loop follow/HANDOFF.md`. Read that before touching it.** The design it
implements is `Loop-Follower-App-Plan-2026-08-13.md`.

Three things about it that matter *from this side of the fence*:

1. **This app HAS now been modified for it** (2026-08-16) — see item 3. Before
   that, files were only COPIED out — the whole
   `LoopUI` HUD (views + nibs), `CustomAlertMonitor` + `CustomAlertsView` + the
   Dexcom `.caf` tones, the `Managers/History` statistics engine, the statistics
   and history-log screens, `GlassStyles.swift`, and the colour sets. Nothing was
   edited in place, and nothing here depends on that app existing.
2. **⚠️ Those copies are now a drift risk** — the "two apps drift" problem §9 of
   the plan warned about, made concrete. Every copied file over there keeps its
   original header plus a `── PORT NOTE ──` wherever something had to change, so
   a diff against the original is meaningful. **If you change a HUD view, an
   alert type, or anything in `Managers/History`, the follower has a copy that
   should probably change too.** The follower's handoff lists every copied file
   and where it came from.
3. **The risky half is NOW PARTLY BUILT — read this before touching it.**

   §15.3 items 1 and 2 have landed IN THIS APP (2026-08-16):

   - `Managers/History/HistoryRecord.swift` gains `StatusHistoryRecord` and
     `SettingsHistoryRecord`. Purely additive to the `v`/`t` schema.
   - `Managers/History/HistoryLogger.swift` gains `record(status:loopCompletedAt:)`
     and `isFollowerFeedEnabled`.
   - `Managers/LoopDataManager.swift` — **one line** in `loopDidComplete`.

   ⚠️ **That one line is the only place the follower project touches the loop
   cycle.** It is shaped so the loop cannot notice: it takes a
   `StoredDosingDecision` the cycle has already finished with, hops off the
   caller's queue immediately, cannot throw back, and returns at once unless BOTH
   the history log and the follower feed are on. **`isFollowerFeedEnabled`
   defaults to FALSE** — nothing is written until it is turned on (§15.2 rule 4).
   It must never grow: no waiting on it, no reading its result, no second call.

   Built AND run in the iOS 26.5 simulator; the status screen behaves normally.
   But per §15.3 this should **run for several days with the flag ON** before
   anything else is built on top — that item "deserves patience".

   Known gaps in the status record, all deliberate rather than faked:
   - IOB and COB are SINGLE POINTS, not curves. `StoredDosingDecision` carries
     only the current values; real timelines need the effect series, which that
     seam does not have. A one-point timeline is honest; an interpolated one
     would not be.
   - `glucoseTrend` / `glucoseTrendRate` are nil — a dosing decision has no trend
     arrow. The follower falls back to the `glucose` records, which do.
   - Pod lifecycle and sensor session are nil. They live on the pump/CGM manager
     state, and this seam deliberately does not reach into the device managers.

   **The publisher landed too (2026-08-16)** — `FollowerPublisher` at the bottom
   of `Managers/Follow/FollowerShareManager.swift`, kicked off from
   `HistoryLogger`'s own queue (never from the loop), rate-limited to one publish
   every 4 minutes, writing ONE overwritten CloudKit record holding a
   24-hour JSON window. `FollowerPayloadAudit` runs §3.1's denied-key scan before
   anything is sent. `DeviceDataManager` gained one wiring line giving it a weak
   settings provider.

   ⚠️ **It publishes a WINDOW, not full history.** §10.4 wants the follower to
   eventually receive everything; a first-sync backfill is a separate job.

   ⚠️ **`FollowerShareManager` never actually granted participants `.readOnly`.**
   The file's header had always claimed it did; the code only set
   `publicPermission`, which governs NON-participants. Every invited follower was
   getting CloudKit's default `.readWrite`. Fixed, and re-pinned on every status
   refresh since participants added later do not inherit it. The app-level
   guarantee always held — the follower links no write path — but the second,
   independent layer did not exist, and the comment stopped anyone looking.

4. **⚠️ THERE IS NO CLEAN BASELINE.** `git status` shows ~67 modified files and
   the last commit is upstream LoopKit history — none of this fork's work is
   committed, including the follower-feed changes above. §15.2 rule 3 says to
   ship main-app changes SEPARATELY from follower work, and right now they
   cannot even be told apart. **Commit or tag a baseline before going further**;
   this is a dosing app and there is currently nothing to revert to.

   Pre-change copies of the three touched files were left at
   `/tmp/HistoryRecord.swift.before`, `/tmp/HistoryLogger.swift.before` and
   `/tmp/LoopDataManager.swift.before` — session-scoped, so they will not
   survive a restart.

## What's done: meal entry, bottom bar, alert labels (2026-08-11)

Three threads on top of the Liquid Glass pass. Full detail in `docs/WORKLOG.md`.

- **Meal entry rebuilt on native iOS 26 controls.** The universal offset-time control is
  gone — the meal time IS the start time and propagates to every carb box. Time and meal
  identity are two floating glass bubbles at the top; every value editor (offset time,
  absorption time) is now a chip + `.popover` wheel that **dismisses itself**. That was the
  point of the rewrite: the old version tracked "which picker is open" by hand and inlined
  wheels that shoved the trigger out from under your finger, leaving no way out.
  Presentation only — `MealEntryViewModel` untouched, so AI prefill still works.
- **Bottom bar restored to native `UIBarButtonItem`s** after a change had converted them to
  custom-view buttons and silently broke the shared Liquid Glass capsule. New
  `PassthroughToolbar` (`Loop/View Controllers/RootNavigationController.swift`, wired via
  `customClass` in `Main.storyboard`) lets touches beside/below the capsule reach the charts.
  **The rule is now in `DESIGN_SYSTEM.md` → Conventions** — it had been buried in a worklog
  entry and got broken anyway.
- **Alert sound labels now name the actual sound** ("Dexcom High Tone", "iOS Default Tone
  (default)"). **Low Insulin (Pod) is pump-beep-only** — fixed row, no picker.
  **Caveat that matters:** the app cannot make the pod beep. The pod beeps from its own
  hardware reminder value; these custom thresholds only produce a silent phone notification.
  For one alarm at one threshold, use the pod's own Low Reservoir Reminder instead.

## What's done: home screen on iOS 26 Liquid Glass (2026-07-28)

The status screen's chrome now uses the real iOS 26 Liquid Glass infrastructure.
Two findings matter more than the code:

1. **`UIDesignRequiresCompatibility` in `Loop/Info.plist` was `true`** — the iOS 26
   opt-out, forcing all system chrome to the legacy look. It is now `false`, which
   is an **app-wide** appearance change (every bar, sheet and system control), not
   just this screen. Do not add custom `UIToolbarAppearance` code; that re-imposes
   the legacy background and undoes the glass.
2. **Glass is refractive — it needs content moving behind it**, or it renders as a
   flat white blob. So the status bar (CGM/loop/pump) is no longer a table row:
   it's `floatingHUDView`, hosted on the navigation controller's view, with the
   charts sized to the full viewport so they scroll underneath it.

Also: the action island (`ActionIslandView`) now uses `GlassEffectContainer` +
`glassEffectID` instead of its old opaque fill, and the hairline under it is gone.
Deferred by request: the AI/meal interface behind the meal button.

Built and **run** in the iOS 26.5 simulator; appearance confirmed on screen.

**Build gotcha (supersedes the command in `docs/PROCESS.md` when you need to RUN
it):** `CODE_SIGNING_ALLOWED=NO` yields an app with no entitlements that aborts at
launch in `INPreferences.assertThisProcessHasSiriEntitlement`. Use
`CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO` instead to get a runnable
simulator build. Full detail in `docs/WORKLOG.md`.

## What's done: UI polish pass (2026-07-16)

- **Universal press animation:** buttons now fluidly EXPAND on press instead of
  dimming, app-wide via the shared `LoopKit/LoopKitUI/Views/ActionButtonStyle.swift`
  plus the AI feature's `PillActionButtonStyle` / new `PressExpandButtonStyle`.
  Spec in `docs/DESIGN_SYSTEM.md`.
  - **CAVEAT:** the Loop scheme consumes a *prebuilt* `LoopKit.framework`, so a
    plain `-scheme Loop` command-line build does NOT recompile the LoopKitUI
    `ActionButtonStyle` change — it only takes effect after LoopKit is rebuilt
    (a normal Xcode workspace build does this; command-line, build the
    "Shared (LoopKit project)" scheme). The Loop-target changes build clean on their own.
- **Bug fixed — edit meal now reaches the bolus screen** (`MealEntryViewModel.submitEdits`).
- **Bug fixed — floating Continue pill now clearly floats** (elevation + safe-area lift).
- Design system consolidated into `GlassStyles.swift` and documented.

Prior work (sounds, AI web search) re-verified as complete this pass: the alert-sound
picker + preview in `CustomAlertsView` is fully wired to `AlertSoundChoice` /
`AlertSoundPreviewPlayer`. Still runtime-unverified: actual audio playback, live AI
provider calls, and the Apple on-device provider stub (SDK-gated).

## What's done: AI carb estimation — web search / nutrition lookup

Added an opt-in web-search capability to the AI carb-estimation providers, so the
model can look up published nutrition facts for branded/packaged foods and named
restaurant items instead of estimating from the photo alone. Additive and off by
default; gated behind the existing master AI toggle plus its own second toggle.

API syntax was confirmed against current provider docs (July 2026), not assumed:
- **Claude** (`ClaudeCarbProvider.swift`): adds `tools: [{type:
  "web_search_20250305", name: "web_search", max_uses: 3}]` when enabled. Also
  **fixed a latent bug**: the response text extractor grabbed only the *first*
  `text` block, which with web search is the "let me search…" preamble, not the
  answer — now concatenates all `text` blocks so the final JSON is always parsed.
- **Gemini** (`GeminiCarbProvider.swift`): adds `tools: [{google_search: {}}]`.
  Gemini can't combine `google_search` with `response_mime_type=application/json`,
  so JSON mode is dropped when search is on and we rely on the prompt + the
  tolerant JSON extractor. Extractor also now concatenates all text parts.
- **OpenAI** (`OpenAICarbProvider.swift`): switches to a search-capable model
  (`gpt-4o-search-preview`, flagged as confirm-at-build-time) + `web_search_options:
  {}`; those models reject `response_format: json_object`, so it's dropped when
  search is on.
- **Apple On-Device / Custom**: intentionally NOT offered web search
  (`supportsWebSearch == false`) — Apple stays private/offline, Custom is the
  user's own server.

Plumbing:
- `CarbEstimationProviderType.supportsWebSearch` (new, in `CarbEstimationSettings.swift`).
- `CarbEstimationSettings.isWebSearchEnabled` (new UserDefaults flag, defaults OFF).
- `CarbEstimationInput.webSearch` (new field) carries the per-request decision.
- `CarbEstimationCoordinator` sets it to `isWebSearchEnabled && provider.supportsWebSearch`.
- `CarbEstimateWireFormat.prompt(...)` gained a `webSearchAvailable` arg that appends
  a line telling the model it may look up branded/restaurant nutrition facts.
- `AICarbSettingsView` shows a "Look Up Nutrition Facts" toggle, only for providers
  whose `supportsWebSearch` is true, with a footer explaining the privacy/latency cost.

Not verified: live calls to any provider with search on (needs real API keys); only
compile-verified. Model names for OpenAI's search-preview and the Claude/Gemini
model strings still carry the codebase's standing "confirm at build time" note.

## What's done: Dexcom-tone custom alert sounds

Goal: let the "Custom Alerts" feature (glucose rate/trend, low reservoir — see
`CustomAlertMonitor.swift`) play Dexcom's own alert tones instead of Loop's defaults.

Completed and registered in `Loop.xcodeproj/project.pbxproj`:
- 6 `.caf` tone files added at `Loop/Loop/CustomAlertSounds/`:
  `high_alert.caf`, `low_alert.caf`, `rise_rate.caf`, `signal_loss_alert.caf`,
  `urgent_low.caf`, `urgent_low_soon.caf` — plus `DEXCOM_SOUNDS_LICENSE.md`.
- `Loop/Managers/Alerts/LoopSoundVendor.swift` — new file, added to the Loop target.
  Implements `AlertSoundVendor` (`getSoundBaseURL`/`getSounds`) so `AlertManager`
  can copy these `.caf`s into its sounds directory as `Loop-<filename>`. Also hosts
  `AlertSoundPreviewPlayer` for in-app preview playback in the settings picker.
- `Loop/Managers/DeviceDataManager.swift` — wires it up:
  `alertManager.addAlertSoundVendor(managerIdentifier: CustomAlertMonitor.managerIdentifier, soundVendor: LoopSoundVendor())`
- Project file registration was done via a one-off script,
  `register_alerts_sounds.py` (in scratchpad, not in repo), using the `pbxproj`
  Python library with two workarounds:
  - `.caf` isn't a known type in pbxproj 4.3 → monkeypatched into
    `ProjectFiles._FILE_TYPES` as a Copy-Bundle-Resources file.
  - A patched `_filter_targets_without_path` to handle Swift-package build files
    that have `productRef` but no `fileRef`.
  A pre-change backup of the pbxproj is at
  `/private/tmp/.../scratchpad/project.pbxproj.before-alerts-sounds` (session-scoped
  temp dir — may not survive past this session). The repo itself also has
  `Loop.xcodeproj/project.pbxproj.orig` as an untracked backup.
- Raw source tones (`.wav`/`.mp3`, pre-`.caf`-conversion) are sitting in scratchpad
  under `dexcom_raw/` along with a `dexcom/` folder (looks like a cloned reference
  repo with its own `README.md`/`LICENSE.md` — likely the source the license note
  refers to). Not part of the Xcode project; scratchpad-only.

**Verified state**: diffing the pre-change pbxproj backup against the live one shows
exactly the expected additions (file refs, build-file entries, group membership,
Resources build phase) — the registration script completed successfully and nothing
looks partial.

**Update 2026-07-08 (later session)**: verified and built.
- `afinfo` on all 6 `.caf` files confirms valid Core Audio Format (`caff`, PCM
  44.1kHz mono, 1.8–3.8s each) — not renamed `.wav`/`.mp3` copies.
- `xcodebuild -scheme Loop build` **succeeded** for a concrete simulator device
  (`platform=iOS Simulator,name=iPhone 17`, arm64), with `LoopSoundVendor.swift`
  and `CustomAlertMonitor.swift` compiling cleanly and the 6 `.caf` files landing
  at the bundle root of the built `Loop.app` (confirmed via `find` in DerivedData
  Build Products), matching `LoopSoundVendor.getSoundBaseURL()`'s expectation of
  `Bundle.main.resourceURL`.
- Gotcha hit along the way: building with `-destination "generic/platform=iOS
  Simulator"` resolves to **x86_64**, but this machine's DerivedData had a
  stale `LoopKit.framework` built arm64-only (from a prior IDE build) — and
  `LoopKit` isn't even in the `Loop` scheme's target dependency graph (it's
  consumed as a prebuilt framework, not rebuilt from source), so the mismatch
  never gets reconciled and every LoopKit-derived type in `LoopCore` fails to
  resolve ("cannot find type 'X' in scope"). This is a pre-existing environment
  quirk, unrelated to the sound-registration work — **always build against a
  concrete simulator device (e.g. `-destination "platform=iOS
  Simulator,name=iPhone 17"`), never the generic destination**, on this checkout.

**Still not verified**: whether `AlertManagementView`/`CustomAlertsView` correctly
surface these sounds in the picker at runtime, and whether `AlertSoundPreviewPlayer`
actually plays them — needs running the app in the simulator, not just building.

## Also present in the working tree (pre-existing, not from this session)

The repo has substantial other uncommitted work unrelated to the sounds task above —
I have no session context for these, so treat this as an inventory, not a status
report:
- `Loop/AICarbEstimation/` (untracked) — a sizeable subsystem: multiple carb-estimation
  providers (Claude, OpenAI, Gemini, Apple on-device, custom HTTP), a meal-entry flow
  with photo capture, LiDAR volume estimation, keychain storage for API keys, and
  settings UI.
- `Loop/Models/Preferences.swift` (untracked) — a basal-lock threshold preference,
  by a different original author (Jonas Björkert per the file header) than this
  session's work.
- `Loop/Managers/Alerts/CustomAlertMonitor.swift` and `Loop/Views/CustomAlertsView.swift`
  (untracked) — the custom-alerts feature that `LoopSoundVendor` hooks into. Existed
  before this session's changes.
- Modified but unrelated: `Loop/Managers/LoopDataManager.swift`, `Loop/Views/SettingsView.swift`
  (both also have `.orig` backups sitting alongside, untracked), plus ~25 other
  modified files (widgets, live activity, storyboard, localization, view models).
- `git log` shows the last real commit is upstream LoopKit history — none of this
  fork's local changes have been committed yet.

## Suggested next steps

1. ~~Confirm the `.caf` files are valid Core Audio Format.~~ Done — verified via `afinfo`.
2. ~~Build the Loop target to confirm the pbxproj edits are structurally correct.~~
   Done — builds clean against a concrete simulator device (see update above).
3. Manually exercise Settings → Alert Management → Custom Alerts → sound picker in
   the simulator to confirm the Dexcom tones appear and preview-play correctly.
   (Not yet done — needs actually running/tapping through the app, not just a build.)
4. Decide whether to commit — right now there's a large uncommitted diff spanning
   at least two unrelated features (AI carb estimation, alert sounds) plus stray
   `.orig` files that should probably be deleted or gitignored before any commit.

## Roadmap (agreed 2026-08-11, not started)

Four staged features. Full plan, with verified file/line references, in
`~/.claude/plans/now-the-plan-is-ticklish-kazoo.md`.

**Two constraints drive the ordering — both verified, both worth re-reading before
starting:**

- **Loop keeps only ~7 days.** `Loop.xcconfig:26` sets `LOOP_LOCAL_CACHE_DURATION_DAYS = 7`,
  which feeds every store's `cacheLength`. `GlucoseStore`/`CarbStore`/`DoseStore` `get*`
  methods read the Core Data cache only, and `DoseStore.purgePumpEventObjects(before:)`
  actively deletes older pump events.
- **Past pod sessions are not retained anywhere.** `OmniPumpManagerState` holds `podState`
  plus exactly ONE `previousPodState`; `OmniPumpManager.prepForNewPod()` copies
  current→previous and overwrites the older one.

Together these mean **every day without a durable log is history permanently lost**, and
that no meaningful backfill is possible beyond ~7 days. Stage 2 is therefore the
time-critical one, ahead of the more visible Stage 1.

1. **High/low glucose alerts** with per-alarm customisable snooze. Loop has none today —
   `suspendThreshold` is a *dosing* limit that never alerts, and the 55/80/200 values in
   `DeviceDataManager.swift:901-903` are display colouring only. Extends
   `CustomAlertMonitor` + `CustomAlertsView`; no new files, so no pbxproj work. Reuses the
   `dexHigh`/`dexLow`/`dexUrgentLow` tones that are already bundled but unused.
2. **Durable history log** — append-only JSON Lines, monthly-rotated, in an iCloud Drive
   container (needs an iCloud entitlement, which the app does not currently have), covering
   glucose / meals / doses / **pod sessions incl. stop reason + fault code + insulin left**.
   Plus a plain-language `HISTORY_FORMAT.md`.
3. **Statistics page** built from that file — TIR, GMI, pod longevity/failure rate, meal
   patterns — with **advisory-only** recommendations: surface the evidence, never auto-apply,
   never suggest specific basal/ISF/carb-ratio numbers.
4. **Follower feed** — deliberately *not* built now; Stages 2–3 just keep records immutable
   and timestamped behind a writer protocol so it can be added later without rework.
