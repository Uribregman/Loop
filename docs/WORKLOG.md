# Worklog

Chronological record of changes made to this fork, newest first. Each entry says
what changed, why, and how far it was verified. Keep appending here so future
sessions have the full "every step" history. See `HANDOFF.md` for current status
and `docs/DESIGN_SYSTEM.md` / `docs/PROCESS.md` for the standing rules.

---

## 2026-08-23 — The statistics were counting the log twice

The user said insulin per day and carbs per day "aren't real stats and show
false information". They were right. Full detail in `Loop-AI-Carb-StepLog.md`,
STEP AY.

**The history log legitimately contains repeats and nothing collapsed them.**
LoopKit re-reports pump events once they reconcile — `replacePendingEvents` tells
the DoseStore to replace them, but the log is append-only and kept both. A third
of the dose records in a real container were duplicates, so every insulin total
read about a third high. `HistoryLineDeduplicator` now collapses repeats on the
read side, for both the statistics and the therapy review.

**"Per day" divided by the wrong number of days.** It used the elapsed span, so
days the app never ran counted as days with no insulin and no food. It is now the
count of days that actually have data, and a day needs six hours of CGM or at
least one dose/meal to count at all. The same "a partial thing is not a whole
thing" fix was applied to ADRR, to nights with a low, and to bedtime outcomes.

**Every number was then checked against a dataset with known answers**
(`BuildLoop/verify_stats.py`, `BuildLoop/verify_insights.py`) rather than by eye —
including the published formulas (Kovatchev, Klonoff's GRI, J-index in mg/dL).
Time in range, average, GMI, CV, MAGE, CONGA, MODD, GRI, LBGI, HBGI, ADRR,
insulin/carbs per day, low events and the whole Settings Review all match their
hand-computed values.

**The Settings Review works, carb ratio included** — verified with 40 days of
bolused meals carrying a designed +30 mg/dL five-hour excursion: 9 g/U observed
against a 15 g/U setting, correctly capped to 12 and flagged as a bigger gap than
the page will suggest moving.

**Which tiles follow the period picker is now stated.** A caption under the picker
says what the numbers cover and how many of those days have data, and the two
tiles that deliberately span everything (Compare Periods, Settings Review) carry
an "All history" badge.

**Verified:** all of the above on screen, against known-answer datasets.

---

## 2026-08-20 — Eight reported bugs: island, statistics, alerts, keyboard, scroll edges

A user bug list, fixed in one pass. Step-by-step detail (including what was and
was not runtime-verified) is in `Loop-AI-Carb-StepLog.md`, STEP AV.

**The action island stopped flashing dark** (`Views/ActionIslandView.swift`,
`View Controllers/StatusTableViewController.swift`). A `.shadow` around the
`GlassEffectContainer` and a UIView alpha fade on the hosting view were both
forcing the glass to composite offscreen, where it has no backdrop to sample.
Both are gone; the reveal is the header stack's height change alone. The island
also now receives its bottom gap from the view controller, so the space above it
(the stack's spacing) and below it are the same number instead of 14pt vs 8pt.

**The Settings Review works on real data again**
(`Managers/History/TherapyInsights.swift`). It counted automatic boluses as
contamination, and on Automatic Bolus dosing there is one every five minutes —
so every fasting night, every correction and every meal was disqualified and the
screen reported "not enough data" no matter how much data there was. Only manual
boluses count now. The fasting window is also a fixed 00:00–07:00 rather than
HealthKit sleep times, which were a different length every night and put the
whole review behind a Health permission; `SleepWindowProvider.swift` is now
unused and says so at the top.

**The average-day (AGP) chart was drawing a wedge**
(`Views/HistoryStatisticsView.swift`). Swift Charts merges same-type marks into
one series unless told otherwise, so the two percentile bands were rendered as a
single area that swept diagonally back across the day. Every mark now carries an
explicit `series:`, and the profile is split into runs of consecutive hours so a
gap in the evidence renders as a gap rather than being interpolated through.
`worstHour` ranks by median — what the chart actually draws.

**Alerts: one per direction, spaced, prioritised, and audible**
(`Managers/Alerts/CustomAlertMonitor.swift`, `LoopSoundVendor.swift`,
`InAppModalAlertScheduler.swift`, `Managers/LoopAppManager.swift`). Only the most
extreme triggered high/low fires; everything is released through one queue at a
minimum of 5 s apart, ordered by urgency then kind; all shared state is behind a
lock, because the entry points are documented as callable from any queue and were
not synchronised. Foreground alerts now play their own tone through an
`AVAudioSession` in `.playback`, so a custom alarm is audible with the ringer
off; `willPresent` drops `.sound` for exactly those alerts so nothing doubles.

**Keyboard clearance** (`Views/BolusEntryView.swift`,
`Views/ManualEntryDoseView.swift`, `AICarbEstimation/MealEntry/MealEntryView.swift`).
"Done" moved out of `ToolbarItemGroup(placement: .keyboard)` — which welds it to
the keys — into the existing bottom safe-area inset with a deliberate gap. The
meal screen's floating pill uses a shared `LoopKeyboardObserver` for the same
clearance.

**Content fades under the top bar instead of being cut**
(`AICarbEstimation/UI/GlassStyles.swift` + ~20 screens). The opaque
`toolbarBackground` that every screen pinned also opted the bar out of the
system's scroll-edge effect. New `loopSoftTopEdge()` applies
`.scrollEdgeEffectStyle(.soft, for: .top)`; see the new rule in
`docs/DESIGN_SYSTEM.md`.

**Verified:** builds and launches; statistics (AGP + Settings Review) checked
against 60 days of synthetic history; island gaps, meal-screen pill clearance and
the soft top edge checked on screen. **Not verified:** the island's dark flash
(too brief to screenshot), alert dominance/spacing/sound (needs a device with two
high alarms and the ringer off), and the bolus screen's Done row with a keyboard
under it (the simulator's hardware keyboard suppressed the keypad there).

---

## 2026-08-16 — Loop Follow: the connection (and the first main-app edits)

The follower stopped being a demo. Full detail in `loop follow/HANDOFF.md`;
what matters HERE is that this is the first time the follower project has
touched this app.

**Five files changed, one of them algorithm-adjacent:**

- `Managers/History/HistoryRecord.swift` — `StatusHistoryRecord` and
  `SettingsHistoryRecord`, additive to the `v`/`t` schema.
- `Managers/History/HistoryLogger.swift` — `record(status:loopCompletedAt:)`,
  the `isFollowerFeedEnabled` master switch, and the publish trigger.
- `Managers/Follow/FollowerShareManager.swift` — `FollowerPublisher` and
  `FollowerPayloadAudit` appended. (They belong in their own file; the Loop
  project has no synchronized groups, so a new file means hand-editing a
  60-format pbxproj, and there is no baseline commit to fall back on.)
- `Managers/DeviceDataManager.swift` — one weak settings-provider closure.
- `Views/FollowSettingsView.swift` — the "Share My Loop" toggle.

⚠️ **`LoopDataManager.loopDidComplete` gained ONE non-comment line:**
`HistoryLogger.shared.record(status:loopCompletedAt:)`. That is the only place
the follower project touches the loop cycle. It runs after the decision is made
and stored, hops off the queue immediately, cannot throw back, and returns at
once unless both switches are on. **It must never grow.**

Verified by diffing against pre-change snapshots: 13 changed lines in
LoopDataManager (12 of them comments), 11 in DeviceDataManager. The larger
`git diff --stat` numbers are pre-existing uncommitted work, not this.

⚠️ **A real bug found while doing it:** `FollowerShareManager`'s header had
always claimed participants are granted `.readOnly`. The code only ever set
`publicPermission`, which governs NON-participants — every invited follower was
getting CloudKit's default `.readWrite`. The app-level guarantee still held (the
follower target links no write path) but the second, independent enforcement
§12.2 asks for did not exist, and the comment is what stopped anyone checking.
Fixed, and re-pinned on every status refresh since later participants do not
inherit it.

**Bug fixed the same day — "give this follower a name" after giving one.**
`FollowSettingsView` is a `NavigationLink` destination inside the Settings list,
and that list re-renders whenever `SettingsViewModel` publishes — constantly, on
every loop cycle and device update. SwiftUI re-initialises a destination view
when its parent re-renders, so the `@State` holding the typed name went back to
"" between typing it and tapping Create Invitation. `makeShare` received an empty
string and reported exactly what it saw.

The draft (`draftName`, `isNamingFollower`) now lives on `FollowerShareManager`,
which is a singleton and outlives the view. **Don't move it back.** Also fixed a
latent mismatch: the button trimmed `.whitespaces` while the manager trimmed
`.whitespacesAndNewlines`, so a name of only a newline enabled the button and
then failed validation.

⚠️ Worth remembering generally: any `@State` in a screen reached from
`SettingsView` is unreliable across a typing session.

**Two gaps closed the same day, both found by looking rather than assuming:**

- **The patient's display label was read but never settable.** `FollowerPublisher`
  read `patientLabel` from UserDefaults and nothing anywhere wrote it, so every
  follower would have shown the fallback "Loop". Settings → Follow now has the
  field (§14.4). Deliberately not defaulted from the Apple ID or device name —
  that string lands on someone else's phone.
- **Publishing was a black box.** It runs on a background queue and swallows its
  own errors by design, so the only evidence was a console line — useless when
  you are stood next to the second phone wondering why it is empty. Settings →
  Follow now shows last-sent time, payload size, the last error, and a forced
  "Send Now" that skips the 4-minute rate limit. In the simulator it immediately
  and correctly reported "This request requires an authenticated account".

Built and RUN in the iOS 26.5 simulator; the status screen behaves normally and
the toggle works. **Nothing on the CloudKit path has ever been exercised** —
§12.1 requires two real devices with two real Apple IDs.

## 2026-08-15 — Loop Follow: a second, read-only app

Built stages F0/F1/F1b of `Loop-Follower-App-Plan-2026-08-13.md` in
`loop follow/` (separate project, outside this workspace). Full detail in
`loop follow/HANDOFF.md`.

**Nothing in this app changed.** Code was copied out, never edited in place.

The decision worth recording: the first pass reimplemented the home screen and
alerts in fresh SwiftUI, and it was rejected — the requirement is the SAME
screen, not a lookalike. So `LoopUI`'s actual UIKit HUD (14 views + 3 nibs),
`CustomAlertMonitor`, `CustomAlertsView` and the Dexcom tones were copied
wholesale into the follower target, along with the ~20 small LoopKit types they
need, and only the DATA SOURCE was swapped. LoopKit itself is still not linked
there — the plan's §2 forbids it, since it would drag the dosing layer in.

⚠️ **That makes those files drift risk in both directions.** Changing a HUD view,
an alert type or anything in `Managers/History` here means the follower holds a
copy that should probably change too. Every copy over there carries its original
header plus a `PORT NOTE` at each divergence, so diffing is meaningful.

Three gotchas that cost real time, in case they recur:
- Nib custom classes need `customModule` REPOINTED at the new target, not
  removed. Removing it gave "Unknown class …" for all 14 views and a crash on
  the first outlet connection.
- `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` has to be NO
  there, because `LoopUI/Extensions/Color.swift` declares `Color.carbs` etc.
  itself and Xcode would synthesise colliding accessors from the colour sets.
- Flattening Loop + LoopKit + LoopKitUI + LoopUI into one target surfaces genuine
  duplicate declarations, and `preferredFractionDigits` is one where the two
  versions DISAGREE.

**Second pass, same day:** the charts went the same way. `StatusChartsManager`,
the four `LoopKitUI` chart classes, `ChartsManager` and `ChartContainerView` are
copied too, with **SwiftCharts added as a real package dependency** pinned to the
revision `LoopKit/Package.resolved` holds (`c354c19`). The follower's home screen
now draws Loop's own predicted-glucose, IOB, dose and COB charts. Also: Loop's
app icon copied; the parallel follower alert layer deleted in favour of
`CustomAlertsView` alone.

⚠️ That pulled LoopKit's VALUE layer across too — `GlucoseValue`, `DoseEntry`,
`CarbValue`, `GlucoseRangeSchedule`, `DailyValueSchedule`, `QuantityFormatter`
and friends, ~65 files in the follower's `LoopKitPort/`. Still no PumpManager, no
LoopDataManager, no store, no algorithm, so the "cannot issue a device command"
invariant holds — but the plan's cleaner phrasing ("links none of the dosing
modules") no longer describes it exactly, and the §2.4 CI test is now the thing
that would actually hold the line.

Built and RUN on the iOS 26.5 simulator; the real HUD, the real Custom Alerts
screen and the real charts (with data) were all confirmed on screen. No transport
exists yet — it runs off a bundled fixture — and §15's main-app publisher work is
not started.

## 2026-08-11 — Meal-entry redesign, bottom-bar restore, alert-sound labels

Three unrelated threads, all on top of the 2026-07-28 Liquid Glass pass.

**Meal entry rebuilt on native iOS 26 controls** (`Loop/AICarbEstimation/MealEntry/MealEntryView.swift`)
- The **universal offset-time control is gone**. The meal time IS the start time now:
  setting it writes `mealTime` + `offsetTime` and calls `propagateOffset()`, which is what
  the old offset card did by hand. `Field.mealOffset` deleted with it.
- Two **floating Liquid Glass bubbles** pinned to the top, in one `GlassEffectContainer`
  with `glassEffectID`s so they morph rather than cross-fade: meal time on the left
  (collapsed = just the time; expanded = clock icon + picker + a `+15` pill), meal identity
  on the right (collapsed = name, or "Carbs" when unnamed; expanded = name field,
  photo/emoji, favourite heart, favourites picker). The plate emoji only shows once the
  user actually picks a photo or a non-default emoji (`hasChosenMealGlyph`).
- **Every value editor is now self-dismissing.** Offset time and absorption time are a
  glass chip that opens a wheel in a `.popover` with
  `.presentationCompactAdaptation(.popover)` — without that modifier a popover becomes a
  full sheet on iPhone and the two rows would not have matched.
  - **Why this was a rewrite and not a patch:** the previous version tracked "which picker
    is open" by hand and inlined `.wheel` pickers, which pushed the very chip that opened
    them out from under the user's finger — there was no reliable way back out. Custom
    dismissal state was the bug; native controls own their own dismissal.
- Carb box: hard `Divider()` rules removed, amount is bare 40pt rounded numerals (no boxed
  field), values are consistent glass chips, food-type emoji are glass circles with the
  selected one tinted by a new **`loopSelectionTint`** (`GlassStyles.swift`) — a step darker
  than `loopControlTint`, which was too faint to read as selected.
- The header row (caption + preset label) only renders when there is **more than one** carb
  box; a lone box is just "the carbs".
- Presentation only — `MealEntryViewModel` untouched, so AI prefill of name/emoji/subBlocks
  and the favourites/save paths are unchanged.

**Bottom bar restored to native bar button items** (`Loop/View Controllers/StatusTableViewController.swift`)
- A previous change had converted every toolbar control to
  `UIBarButtonItem(customView: UIButton)` with a hand-rolled 1.16× spring press animation.
  That **forfeits the toolbar's shared Liquid Glass background** — custom views don't
  participate in the grouped-capsule treatment — so the single grouped glass menu was lost.
- Reverted to plain `UIBarButtonItem(image:style:target:action:)` for bolus/settings and for
  `createPreMealButtonItem` / `createWorkoutButtonItem`; removed the press-scale targets
  from `mealButton`; deleted `createToolbarButtonItem`, `updateToolbarButton`,
  `toolbarButtonTouchDown/Ended`, `animateToolbarButton` and the four `…ToolbarButtonTapped`
  wrappers (they only forwarded to the existing `@IBAction`s). See the new rule in
  `DESIGN_SYSTEM.md` → Conventions.
- **`PassthroughToolbar`** added (`Loop/View Controllers/RootNavigationController.swift`),
  installed via `customClass` on the toolbar in `Main.storyboard` — a storyboard-instantiated
  `UINavigationController` uses `init(coder:)` and gives no chance to pass a `toolbarClass`.
  Its `hitTest` only claims touches that land on (or inside) a `UIControl`, so the empty
  strip beside and below the floating glass capsule falls through to the charts.
  - Verified empirically first: a drag at `(25, 700)` scrolled the charts, the identical drag
    at `(25, 798)` — level with the bar, beside the capsule — did nothing.

**Alert sound labels + pod-beep-only reservoir** (`Loop/Managers/Alerts/CustomAlertMonitor.swift`, `Loop/Views/CustomAlertsView.swift`)
- Labels now name the sound you will actually hear rather than an abstract setting:
  `Default` → **iOS Default Tone (default)**, `Vibrate Only` → **Silent — Vibrate Only**,
  and the six Dexcom entries → "Dexcom High Tone", "Dexcom Rise-Rate Tone", etc.
  `title` became `title(isPodAlert:)`; `alertSound` became `alertSound(isPodAlert:)`.
- **Low Insulin (Pod) is pump-beep-only.** Its sound picker is replaced by a fixed
  `labeledValue` row reading "Pump Beep (default)", and `processReservoir` passes
  `sound: .defaultSound` explicitly rather than `threshold.sound`, so it stays pump-beep even
  if another value was persisted earlier. For pod alerts `.defaultSound` maps to `.vibrate`
  (a silent notification), i.e. no phone tone layered on the pod's own beep.
- **Known limitation, stated plainly:** the app cannot make the pod beep. The pod's beep is
  hardware — OmnipodKit sends `PodAlert.lowReservoir` and the pod beeps at *its own*
  configured reminder value (Pump Settings → Low Reservoir Reminder). These Custom Alerts
  thresholds are app-side only, so at a custom threshold you get a silent notification, and
  the pod beeps separately at its own number. If you want one alarm at one threshold, set the
  pod's own reminder and drop the custom reservoir thresholds.

**Verified:** builds clean (`BUILD SUCCEEDED`, 0 errors) against
`platform=iOS Simulator,name=iPhone 17`, and each change was exercised in the simulator —
the bubbles/pickers, the restored grouped-glass toolbar capsule, the pass-through drag, and
the renamed sound rows were all confirmed on screen.

**Not verified:** the pod-beep behaviour at a real low-reservoir crossing (needs a real pod);
only the app-side silent notification path was checked.

---

## 2026-07-28 — Home screen on real iOS 26 Liquid Glass

Moved the home screen's chrome off hand-rolled fills and onto the actual iOS 26
Liquid Glass APIs. The whole workspace already targets `IPHONEOS_DEPLOYMENT_TARGET
= 26.0` (SDK 26.5), so none of this needs an `#available` guard.

**API surface used** (verified against the installed SDK's `.swiftinterface` /
headers, not from memory):
- SwiftUI (`SwiftUICore`): `GlassEffectContainer(spacing:)`,
  `.glassEffect(_:in:)`, `.glassEffectID(_:in:)`, `Glass.regular` +
  `.interactive()`.
- UIKit: `UIGlassEffect(style:)` (`isInteractive`, `tintColor`),
  `UIGlassContainerEffect` (`spacing` is a settable property — there is **no**
  `init(spacing:)`), `UIView.cornerConfiguration = .capsule()`.

**Action island → real glass** (`Loop/Views/ActionIslandView.swift`)
- Replaced the flat opaque `islandBackgroundTint` fill with a real
  `.glassEffect` on every element, all inside ONE `GlassEffectContainer`.
- The container is what makes this work: it renders every element as a single
  combined material, so the pill and bubbles merge as they approach and split as
  they part, and no element casts its own drop shadow. That per-element shadow
  was the original reason the previous pass abandoned glass here and went flat —
  the container is the correct fix, so the flat fill is gone.
- `glassEffectID(item.id, in:)` + a shared `@Namespace` make the pill↔split
  change one continuous glass morph instead of a cross-fade.
- Actionable elements use `.regular.interactive()` so the material itself
  responds to touch, on top of the existing press-expand pulse.
- Unchanged on purpose: elements are still NOT `Button`s, so `contentShape`
  hitboxes stay exact (SwiftUI inflates small buttons toward 44pt).

**Separator under the island removed** (`StatusTableViewController`)
- `configureIslandCell` now sets `separatorInset.left = 999`, hiding just that
  row's hairline (the idiom already used in `Main.storyboard`) without turning
  separators off table-wide. The island reads as a floating element, not a row.

**Top HUD pills/icons → real glass** (`LoopUI/Views/StatusBarHUDView.swift`)
- The three status views (CGM, loop completion, pump) are each re-parented into
  their own capsule `UIVisualEffectView(UIGlassEffect)`, and the whole stack now
  lives inside a `UIVisualEffectView(UIGlassContainerEffect)`. This is the
  documented UIKit pattern: nested glass effect views inside a container effect
  view get drawn as one combined material.
- Each HUD view's nib background is cleared and the bar's own
  `.secondarySystemBackground` dropped to `.clear`, so the glass is what shows.
- `heightForRowAt` already measures the bar with `systemLayoutSizeFitting`, so
  the added pill padding is picked up automatically.

**THE key change — the app was opted OUT of Liquid Glass** (`Loop/Info.plist`)
- `UIDesignRequiresCompatibility` was `true`. That is the iOS 26 opt-out: it
  forces every piece of system chrome (toolbars, nav bars, sheets, bar button
  items) to render in the legacy pre-26 style, no matter what the code does.
  Explicit SwiftUI `.glassEffect` still worked, which is why the island looked
  glassy while the toolbar stayed a flat grey strip.
- Now `false`. **This is app-wide**: every bar, sheet and system control in Loop
  now renders in the iOS 26 design, not just this screen. Flip it back if that
  is ever unwanted — but note nothing else here produces a real glass toolbar.
- Consequently there is NO custom toolbar appearance code. An explicit
  `UIToolbarAppearance` is not needed and an earlier attempt at one actively
  forced the legacy background back on. The bottom menu's glass, and its
  per-item glass capsules, are what UIKit does by itself once compatibility is
  off. Leave the toolbar unstyled.

**The floating status bar — why glass needs content behind it**
- Liquid Glass is a *refractive* material. Over a flat, static background it
  renders as a plain white blob; it only reads as glass when content moves
  underneath. The first attempt kept the HUD as a table row, so the charts
  merely started below it and nothing ever passed behind — it looked flat, and
  correctly so.
- `Section.hud` is gone. The bar is now `floatingHUDView`, added to the
  **navigation controller's view** (this is a `UITableViewController`, so `view`
  IS the scrolling table — anything added there scrolls away) and pinned to the
  top safe area. `tableView.contentInset.top` reserves its height, so content
  rests below it but travels under it.
- `heightForRowAt` for `.charts` deliberately **no longer subtracts the bar's
  height**. That subtraction sized the charts to exactly fit the viewport, so
  the table never scrolled and the glass had nothing to refract. Sizing them to
  the full viewport makes the content taller than the visible area by exactly
  the bar's height, which is what puts the charts under the glass.
- `viewWillDisappear` hides the bar, since the navigation controller hosts it
  and it would otherwise float over whatever is pushed.

**Bottom menu — one grouped glass capsule, not five circles**
- A toolbar draws one shared glass background behind a run of *adjacent* items;
  any space item breaks the run (that is literally what `fixedSpaceItem` is
  for). The old layout had a `flexibleSpace` between every control, so each icon
  got its own separate glass circle.
- Items are now adjacent, with flexible spaces only at the two ends to centre
  them — Apple's single grouped, centred glass menu. Indices moved, so the
  hard-coded `toolbarItems![0/2/4/6/8]` accesses are now a `ToolbarIndex` enum.

**Two layout bugs found by actually running it**
- *The top pills fused into a grey slab.* `spacing` on a glass container is a
  *merge distance*, not a gap: elements closer than `spacing` fuse. It was 12
  with a 6pt stack spacing, so all three merged. Now 0.
- *Scrolled content collided with the clock.* The bar was pinned to the safe
  area, so content passing under it re-emerged in the uncovered status-bar
  strip. It is now pinned to y=0 (its glass covers the strip, like a navigation
  bar), with the pills positioned against the safe area, and the reserved inset
  is `barHeight - safeAreaInsets.top` since `contentInset` is added to the
  safe-area inset.

**Follow-up pass — fixed header, hugging pills, matched background**

Requested changes after reviewing the above on device:
- **Everything is fixed to the top now.** The island was still a table row; it
  moved into a `floatingHeaderView` (a vertical `UIStackView` holding the status
  pills + a `UIHostingController` for the island) in the navigation controller's
  view. `Section.status` is gone with it, so the table is just the banner and
  the charts. Scroll-under refraction was explicitly given up in exchange —
  the glass stays.
  - The hosting controller is deliberately **not** `addChild`ed: its view lives
    in the navigation controller's hierarchy, and UIKit throws when a child view
    controller's view is installed outside its parent's tree.
  - `updateFloatingHeaderInset()` must `layoutIfNeeded()` the header before
    measuring — this VC's layout pass does not size a view owned by the nav
    controller, so the frame is stale and the island overlaps the chart.
- **The glass hugs its content.** Two causes, both non-obvious:
  1. The nib pins `CGMStatusHUDView` to `width >= 150` (sized for the old flat
     bar). That minimum was the empty gutter inside the glucose capsule; it is
     now demoted to `.defaultLow` via `relaxMinimumWidth(of:)`.
  2. A stack pinned edge-to-edge has to put its slack *somewhere*, and `.fill`
     gives it to whichever view hugs least — the glucose one. Content-hugging is
     now explicit: the pump capsule (`.defaultLow`) absorbs the slack because it
     carries the long status text, and the others (`.defaultHigh`) hug.
     `.equalSpacing` was tried first and is wrong: it squeezed the pump capsule
     until "Signal Loss" truncated.
  - The island pill likewise dropped its `Spacer` + `frame(maxWidth: .infinity)`
    for `.fixedSize(horizontal: true, …)` so it is a capsule, not a bar.
- **Backgrounds match the charts.** The header stack, `StatusBarHUDView` and the
  navigation controller's view are all `.systemBackground`, so the strips behind
  the top pills and the bottom menu are the same white as the graphs instead of
  grey.

**Third pass — original dimensions restored, pump expiry line surfaced**

- **The top bar is back to its original geometry**, glass being the only change.
  The hugging work from the previous pass is reverted: nib spacing (16/8),
  `.fill` distribution and the `width >= 150` minimum are all left alone, and
  `glassContentInsets` is now **zero** so each capsule traces its HUD view's
  original bounds. Only a 6pt outer margin remains, so the outermost capsules'
  rounded ends aren't flush against the bezel.
- **Each HUD view painted an opaque rounded fill** (`backgroundView`,
  `.systemBackground`, cornerRadius 23) left over from the flat-bar design.
  Inside a glass capsule that fill is what you actually see — so
  `DeviceStatusHUDView.clearOpaqueBackground()` now clears it and the glass
  shows through.
- **The pump lifecycle (pod/reservoir expiry) indicator was invisible.** It is a
  `UIProgressView` buried inside the pump element. It is now suppressed
  (`suppressesBuiltInProgressView`) and replaced by a floating capsule directly
  beneath the pump pill: a faint full-width groove plus a `UIGlassEffect` fill
  whose `tintColor` is `DeviceLifecycleProgressState.color`, so it still shifts
  to amber/red as the pod ages, and whose width multiplier is the elapsed
  fraction. `DeviceStatusHUDView.lifecycleProgressDidChange` feeds it, so no
  view-controller wiring was needed.

**Fourth pass — pill proportions**

- One shared `pillHeight` of 58 (down from the elements' ~70pt bounds) with the
  content centred inside each capsule rather than stretched to its edges. 50 was
  tried and is too short — the pump reservoir graphic overflows.
- The loop element's capsule is now a true circle (`width == height`) giving an
  even ring. Two bugs had to be fixed to get there:
  - A `<=` cap on the content's height is unsatisfiable against these views'
    required intrinsic heights; Auto Layout broke it and threw the icon out of
    the circle. Fixed height on the capsule + centring the content is the
    correct shape of the constraint set.
  - The nib pins the 44pt `LoopStateView` 10pt from the top of a 44pt
    `LoopCompletionHUDView`, so the icon hangs 10pt below its own container.
    Centring the container therefore did nothing — `centerLoopStateView()`
    re-pins the icon itself.
- The pump lifecycle line is inset 14pt at each end, so it runs slightly shorter
  than the pump pill rather than its full width.
- Its groove stays faint (0.08 alpha). Raising it to 0.12 was tried and reverted:
  the tinted fill on top is *glass*, i.e. translucent, so a darker groove bleeds
  through and visibly dulls the progress colour. The hue itself is
  `DeviceLifecycleProgressState.color` and is deliberately NOT hardcoded — red
  vs amber is the pod's actual critical/warning state and must keep reporting it.

**Fifth pass — the header must be transparent**

Making the header `.systemBackground` (to match the charts' white) had quietly
destroyed the glass: an opaque bar *hides* the content behind it, so the charts
cut off at its edge and the pills stopped reading as glass. The header stack and
`StatusBarHUDView` are `.clear` again; the white now comes from the table
underneath, which shows through and looks identical at rest while still letting
content travel under the pills. `navigationController.view` and `tableView` keep
`.systemBackground` so the strips are still white rather than grey.

**Sixth pass — slow return from menus, and correct glass tinting**

- **Fixed a multi-second stall returning from any settings screen.**
  `viewDidLayoutSubviews` called `updateFloatingHeaderInset()`, which called
  `floatingHeaderView.layoutIfNeeded()`. The header lives in the navigation
  controller's view, so that walks *up* and re-lays out that entire tree —
  including this table — on every single layout pass. On top of that,
  `updateIslandItems()` rebuilt the hosted SwiftUI view on every `reloadData`,
  which Loop calls constantly. Now: the inset calculation never forces layout,
  and the island short-circuits when its items are unchanged, forcing layout
  only on the appear/disappear transition that actually changes the header's
  height.
- **The pump lifecycle line moved to SwiftUI.** `UIGlassEffect.tintColor` is
  unreliable on this SDK — a fact this repo had already recorded in
  `MealEntryPickerOverlay` — and it was washing the progress colour out; the
  "the line changed colour" report was that, not the groove alpha. The line is
  now a small `PumpLifecycleLine` SwiftUI view using
  `.glassEffect(.regular.tint(...))`, hosted in the HUD, and the colour renders
  properly saturated again.
- **Glass audit.** Every glass element in this work is first-party API:
  `UIGlassEffect` / `UIGlassContainerEffect` / `UIView.cornerConfiguration` in
  UIKit, `GlassEffectContainer` / `.glassEffect` / `.glassEffectID` in SwiftUI,
  and the bottom bar is an unstyled system `UIToolbar`. Nothing fakes glass with
  `UIBlurEffect` or a hand-drawn fill, and only the lifecycle line sets a tint —
  so the rest will follow the system's glass appearance, including any future
  user-facing glass tinting.

**Seventh pass — line material, override glyph size**

- The pump lifecycle line uses `Glass.clear.tint(...)` instead of
  `.regular.tint(...)`. At full tint the regular material reads as a flat
  painted bar; the clear style keeps the hue but lets the material show.
- The selected override icons were left ALONE (stock `-selected` assets).
  Several variants were tried and all reverted at the user's request: a circular
  highlight, a runtime-composed rounded square with a larger glyph, and a
  filled disc with the shape knocked out.
- Rejected along the way, recorded so it isn't retried:
  `UIBarButtonItem.sharesBackground = false` and `UIBarButtonItemStyle.prominent`
  both pull the item out of the toolbar's shared glass capsule (the `.prominent`
  header says so explicitly), which splits the menu into separate groups. The
  menu must stay one capsule.

**Out of scope this pass** (explicitly deferred): the AI/meal interface reached
by tapping the meal button.

**Verified — runtime, not just compiled:** built and run in the iOS 26.5
simulator; the top pills, the bottom menu and the refraction of chart content
under the top bar were all confirmed on screen.

**Simulator build gotcha (new, important):** the documented build line uses
`CODE_SIGNING_ALLOWED=NO`, which produces an app with **no entitlements** — it
aborts at launch in `INPreferences.assertThisProcessHasSiriEntitlement` before
any UI appears, so it can be built but never run. Ad-hoc re-signing the built
`.app` afterwards does not fix it (the simulator runs its own installed copy and
rejects the resigned bundle). To get a runnable simulator build, swap that flag
for:

```
xcodebuild -workspace LoopWorkspace.xcworkspace -scheme Loop \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

## 2026-07-16 (b) — Make expand pervasive via glass infrastructure

Follow-up: most buttons still didn't expand because they used `.buttonStyle(.plain)`
(a ButtonStyle only affects buttons that opt in). Fixes:
- New `GlassButtonStyle(in: shape)` in `GlassStyles.swift` — the infrastructure
  piece that couples `.glassEffect` + hit shape + press-expand into one style, so
  the glass control itself grows on press.
- Converted every `.buttonStyle(.plain)` in the visible AI screens to
  `PressExpandButtonStyle()` — MealEntryView (7: star, photo/emoji bubble, heart,
  time, offset, remove-box, emoji presets, absorption toggle) and PhotoCaptureView
  (camera icon, emoji grid cells). The inline glass on their labels now expands.
- PhotoCaptureView's Continue changed from `.borderedProminent` to
  `PillActionButtonStyle(.primary)` (glass pill + expand, consistent).
- `DESIGN_SYSTEM.md` rule added: never `.buttonStyle(.plain)` for a tappable
  control — use `PressExpandButtonStyle` (or `GlassButtonStyle` for glass).
- Builds clean (BUILD SUCCEEDED, 0 errors) on iPhone 17 simulator.

## 2026-07-16 (a) — UI polish, universal design system, bug fixes, animations

**Bug fixes**
- **Edit-meal now reaches the bolus screen.** `MealEntryViewModel.submitEdits` used
  to save the edited records and dismiss, skipping bolus entirely. It now mirrors
  the new-meal flow: the first box is handed to `BolusEntryViewModel` as a
  *replacement* of its original record (`originalCarbEntry` + `potentialCarbEntry`),
  extra boxes are replaced/added immediately, removed boxes deleted, then the bolus
  screen is pushed (the edit presentation already injects `DisplayGlucosePreference`,
  so this is safe). File: `MealEntry/MealEntryViewModel.swift`.
- **Floating "Continue" pill now clearly floats.** Added elevation
  (`shadow radius 14, y 5`), a guaranteed lift above the home indicator
  (`.padding(.bottom, 10)` + `.top, 20`), and enlarged the scroll spacer
  (90 → 112 pt) so cards never hide under it. File: `MealEntry/MealEntryView.swift`.

**Universal design system + animation**
- New shared motion primitives in `AICarbEstimation/UI/GlassStyles.swift`:
  `loopPressAnimation` (spring 0.28/0.62), `loopPressScaleLarge` 1.03 /
  `loopPressScaleSmall` 1.05, a `PressExpandButtonStyle`, and a `.loopPressExpand()`
  modifier. Added `loopControlCornerRadius` (14).
- **Buttons now expand on press instead of dimming — app-wide.** Rewrote the shared
  `LoopKitUI/Views/ActionButtonStyle.swift` (used across bolus, carb entry, settings,
  therapy, etc.) to drop the 0.35 dim overlay and scale to 1.03 with the shared
  spring. `PillActionButtonStyle` and the floating Continue pill updated the same
  way. Applied `PressExpandButtonStyle` to the meal screen's add-box and +15 buttons.
- Documented the whole system in `docs/DESIGN_SYSTEM.md` (roundness, tints, motion,
  pill float, haptics, conventions).

**Docs**
- Added `docs/DESIGN_SYSTEM.md`, `docs/PROCESS.md`, `docs/WORKLOG.md`.

**Verified:** builds clean (`BUILD SUCCEEDED`, 0 errors) against
`platform=iOS Simulator,name=iPhone 17`. Not runtime-tested in the simulator yet
(no interactive run), so the visual feel of the press-expand and the edit→bolus
push should be eyeballed on device/simulator.

---

## 2026-07-08..16 — AI carb estimation: web search / nutrition lookup

Added opt-in web search so the estimation AI can look up published nutrition facts
for branded/restaurant foods. Per-provider tool wiring confirmed against current
docs (Claude `web_search_20250305`; Gemini `google_search`, dropping JSON mode which
conflicts; OpenAI search-preview model + `web_search_options`, dropping
`response_format`). Fixed a latent Claude text-extraction bug (took the first text
block, i.e. the "let me search" preamble, instead of concatenating all blocks).
Gated behind `CarbEstimationSettings.isWebSearchEnabled` + `supportsWebSearch`, with
a "Look Up Nutrition Facts" toggle. Compile-verified only (no live API keys).
Full detail in `HANDOFF.md`.

## 2026-07-08 — Custom Dexcom alert tones

6 `.caf` tones + `LoopSoundVendor` wired into `AlertManager`, registered in the
project via a `pbxproj` Python helper. Verified: valid CAF audio, builds clean,
tones land at the app bundle root. Runtime picker behavior not yet exercised. Full
detail in `HANDOFF.md`.
