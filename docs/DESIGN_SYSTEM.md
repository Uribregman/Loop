# Loop fork — Design System (key details to remember)

The canonical, quick-reference spec for the custom "liquid glass" look introduced
in this fork. **When adding or restyling UI, read this first and reuse the shared
primitives — do not hardcode these values in individual views.**

Source of truth in code: `Loop/AICarbEstimation/UI/GlassStyles.swift` (app target)
and `LoopKit/LoopKitUI/Views/ActionButtonStyle.swift` (shared button, whole app).

---

## Roundness (corner radii)

| Element | Radius | Constant |
|---|---|---|
| Big tiles / cards (meal cards, bolus tiles, history cells) | **24 pt**, `.continuous` | `loopTileCornerRadius` |
| Small inset controls sitting on a tile (chips, mini stats) | **14 pt** | `loopControlCornerRadius` |
| Full-width action buttons (`ActionButtonStyle`) | **10 pt** | (private in `ActionButtonStyle`) |
| Pills / meal-name field / +15 / Continue | **Capsule** (fully round) | `Capsule()` |

Always use `RoundedRectangle(cornerRadius:style: .continuous)` for tiles — the
continuous curve is part of the look; plain `.circular` corners read as "off".

## Motion — press feedback (the headline rule)

**Buttons EXPAND on press. They never dim.** One shared spring:

```
loopPressAnimation = .spring(response: 0.28, dampingFraction: 0.62)
loopPressScaleLarge = 1.03   // full-width buttons (avoid clipping at screen edges)
loopPressScaleSmall = 1.05   // compact pills, chips, icon buttons
```

- Held → control scales up to the scale factor; released → springs back to 1.0.
- Never add a dimming overlay or opacity change for the pressed state.
- How to apply (pick the closest one — NEVER use `.buttonStyle(.plain)` for a
  tappable control, that's exactly why "most buttons didn't expand"):
  - Plain/label-only button → `.buttonStyle(PressExpandButtonStyle())` (default
    small scale; pass `scale: loopPressScaleLarge` for wide buttons). This renders
    the label unchanged (like `.plain`) but adds the expand.
  - **Interactive glass control** (glass chip/bubble/icon) →
    `.buttonStyle(GlassButtonStyle(in: <shape>))`. This is the infrastructure
    piece: it puts the `.glassEffect` + hit shape + expand in ONE style so the
    glass itself grows on press. Don't hand-roll `.glassEffect` on a `.plain`
    button anymore.
  - Full-width capsule action → `PillActionButtonStyle(.primary/.secondary/.destructive)`.
  - Standard full-width action button → `ActionButtonStyle` (LoopKitUI) already
    expands app-wide; no per-view work. NOTE: takes effect only after LoopKit is
    rebuilt (normal Xcode workspace build does this).
  - When you can't replace the whole style → `.loopPressExpand(isPressed:)`.

**Rule of thumb:** if you're about to type `.buttonStyle(.plain)`, use
`PressExpandButtonStyle()` (or `GlassButtonStyle` for glass) instead.

Other motion in use (keep consistent):
- Card insert/remove: `.spring(response: 0.35, dampingFraction: 0.82)` +
  `.transition(.scale(scale: 0.94).combined(with: .opacity))`.
- Inline picker expand/collapse: `.easeInOut(duration: 0.2)`.
- Selection emphasis (selected emoji/heart): scale ~1.12–1.15 with
  `.spring(response: 0.28–0.3, dampingFraction: 0.5–0.6)`.

## Color / material

All defined as adaptive `Color(UIColor { traits in ... })` so dark mode is pinned
to ONE shade (adaptive glass otherwise samples surroundings and drifts per screen):

| Token | Purpose | Dark | Light |
|---|---|---|---|
| `Color.loopScreenBackground` | one unified screen background (carb + bolus) | `white 0.05` | `systemGroupedBackground` |
| `Color.loopTileTint` | glass tile tint (one shade in dark) | `white 0.14 α0.92` | transparent |
| `Color.loopControlTint` | small controls sitting on a tile | `white 0.30 α0.9` | `black α0.10` |

Glass helpers:
- `.loopTileGlass()` — big-tile liquid glass (regular glass, tinted, 24pt continuous).
- `.glassIf(condition, in:)` — interactive glass only when selected/active.
- `glassEffect(.regular.tint(Color.loopControlTint).interactive())` — for small
  interactive controls (pills, bubbles, +15).

## Liquid Glass groups (iOS 26 infrastructure)

The workspace targets iOS 26.0, so the real Liquid Glass APIs are available
unconditionally — never add an `#available` guard for them, and never fake glass
with an opaque fill.

**The rule: more than one glass element in a row/cluster → put them in a
container.** A lone `.glassEffect` draws its own edge and shadow; a container
draws the whole group as ONE material, which is both the correct look and the
fix for "glass shadows stop the row sitting flush on the background" (that is
exactly why the action island was once flattened to an opaque fill — don't
reintroduce that workaround).

| Need | SwiftUI | UIKit |
|---|---|---|
| One glass element | `.glassEffect(.regular, in: shape)` | `UIVisualEffectView(effect: UIGlassEffect(style: .regular))` |
| A group that merges | `GlassEffectContainer(spacing:) { … }` | `UIVisualEffectView(effect: UIGlassContainerEffect())`, glass views nested in its `contentView` |
| Element responds to touch | `.regular.interactive()` | `glassEffect.isInteractive = true` |
| Morph between layouts | `.glassEffectID(id, in: namespace)` | — |
| Capsule corners | `in: Capsule()` | `view.cornerConfiguration = .capsule()` |

Gotchas worth remembering:
- `UIGlassContainerEffect` has **no** `init(spacing:)` — construct it, then set
  `.spacing` (the distance at which neighbours start merging).
- `spacing` should match the stack/HStack spacing, or elements merge at the
  wrong moment.
- Nested glass views must go in the container's `contentView`, and the content
  itself goes in each nested view's `contentView`.

Live examples: `Loop/Views/ActionIslandView.swift` (SwiftUI),
`LoopUI/Views/StatusBarHUDView.swift` (UIKit).

## Bars (iOS 26) — do NOT style them

`Loop/Info.plist` sets `UIDesignRequiresCompatibility` to **false**. Keep it
that way: `true` is the iOS 26 opt-out and forces every toolbar, nav bar, sheet
and bar button item back to the legacy pre-26 look regardless of your code.
With it off, UIKit gives toolbars their Liquid Glass background and puts bar
button items in glass capsules **by itself**.

So: do not set a `UIToolbarAppearance`. `configureWithDefaultBackground()` and
friends re-impose the legacy material and undo the glass. The correct amount of
bar styling code is none.

**Spacer items split the shared background.** A toolbar draws ONE Liquid Glass
capsule behind a run of *adjacent* items. Any space item breaks the run — that
is what `fixedSpaceItem` (zero width) exists for, and `flexibleSpace` does it
too. So this:

```swift
[carbs, space, preMeal, space, bolus, space, workout, space, settings]  // ✗
```

gives five separate glass circles, while this:

```swift
[.flexibleSpace(), carbs, preMeal, bolus, workout, settings, .flexibleSpace()]  // ✓
```

gives Apple's single grouped, centred glass menu. Use flexible spaces only at
the ends to position the group. (Swift spelling is `.flexibleSpace()`, not
`flexibleSpaceItem()`.)

**A floating top bar must be pinned to y=0, not to the safe area.** Its glass has
to cover the status-bar strip the way a navigation bar does. Pinned to the safe
area, content scrolling up passes under the bar and then re-emerges in the
uncovered strip, colliding with the clock. Pin the bar to the superview's top,
position its contents against `safeAreaLayoutGuide`, and reserve
`barHeight - scrollView.safeAreaInsets.top` as `contentInset.top` (the inset is
*added* to the safe-area inset, so reserving the full bar height double-counts).

**`GlassEffectContainer` / `UIGlassContainerEffect` `spacing` is a merge
distance, not a gap.** Elements closer together than `spacing` fuse into one
continuous blob. If you want distinct capsules, keep it *below* the layout
spacing (zero is fine); raise it only when you actually want them to merge.

## Tinting glass: use the SwiftUI modifier

**`UIGlassEffect.tintColor` is unreliable on this SDK** — it washes the colour
out (and in some contexts renders white). Anywhere a glass element needs a
tint, use SwiftUI's `.glassEffect(.regular.tint(color))`, hosting it in a
`UIHostingController` if the surrounding code is UIKit. Both
`MealEntryPickerOverlay` and `StatusBarHUDView`'s pump lifecycle line hit this
and both use the SwiftUI path.

Untinted glass is fine either way — `UIGlassEffect(style:)` in UIKit and
`.glassEffect(.regular)` in SwiftUI are both first-class system glass.

**Don't set a tint you don't mean.** A tint is a semantic statement (the pump
lifecycle line is tinted because the colour reports pod severity). Leave
everything else untinted so it keeps following the system's own glass
appearance — including whatever user-facing glass tinting future OS releases
add.

## Wrapping an existing flat view in glass

Four things bite when you put a pre-Liquid-Glass view inside a glass capsule:

- **Never cap the wrapped view's height with `<=`.** These views carry *required*
  intrinsic heights, so the cap is unsatisfiable, Auto Layout breaks it, and the
  content lands somewhere arbitrary. Give the capsule a fixed height and centre
  the content inside it; don't try to squeeze the content itself.
- **Check where the content actually sits inside its own view.** The nib pins
  `LoopStateView` 10pt from the top of a 44pt `LoopCompletionHUDView`, so the
  44pt icon hangs 10pt *below* its own container. Invisible in a flat bar,
  glaring inside a glass ring — and centring the container cannot fix it,
  because the container was never where the icon was.
  `LoopCompletionHUDView.centerLoopStateView()` re-pins it.

- **Clear its opaque background first.** Views from the flat era paint their own
  rounded fill (`DeviceStatusHUDView.backgroundView` is `.systemBackground` with
  cornerRadius 23). Inside a capsule that fill is what the user sees, not the
  glass. `clearOpaqueBackground()` handles it.
- **Zero content insets keep the original dimensions.** If the brief is "same
  layout, just glass", inset the capsule by nothing and let it trace the view's
  existing bounds — leave the nib's spacing, distribution and minimum widths
  alone. Only add an outer margin so the end capsules aren't flush to the bezel.

## Making a glass capsule hug its content

(Only when you actually want the capsule to shrink-wrap — this deliberately
changes the layout's dimensions.)

A capsule with a wide empty gutter is the most common "this looks bad" symptom.
Two independent causes, both worth checking:

1. **A leftover minimum-width constraint.** `CGMStatusHUDView` carries
   `width >= 150` from the pre-glass flat bar. Demote such constraints to
   `.defaultLow` (`StatusBarHUDView.relaxMinimumWidth(of:)`) — the glass has to
   size to content, not to a bar-era floor.
2. **Stack slack has to go somewhere.** A `UIStackView` pinned edge-to-edge with
   `.fill` hands its leftover width to whichever arranged view hugs least. Set
   content-hugging explicitly: give the *low* priority to the element that
   benefits from extra width (here the pump capsule, which holds "Signal Loss"),
   and `.defaultHigh` to the ones that should hug. Do **not** reach for
   `.equalSpacing` — it spreads the gaps but starves the widest content, and it
   truncated the pump text.

In SwiftUI the equivalent is dropping `Spacer()` + `frame(maxWidth: .infinity)`
in favour of `.fixedSize(horizontal: true, vertical: false)`.

## Fixed top header (status pills + island)

Both live in `floatingHeaderView`, a vertical stack in the **navigation
controller's** view — not the table. Two traps:

- Do **not** `addChild` the island's `UIHostingController`. Its view sits in the
  navigation controller's hierarchy, and UIKit raises an exception when a child
  view controller's view is installed outside its parent's tree. Holding a
  strong reference is enough.
- Call `layoutIfNeeded()` on the header before measuring it for the scroll
  inset. This view controller's layout pass does not size a view the navigation
  controller owns, so the frame is stale and the island overlaps the chart.

## Glass needs something behind it (the rule people miss)

Liquid Glass is a **refractive** material. Over a flat, static background it
renders as a plain white blob — that is not a bug and no amount of tinting
fixes it. It only reads as glass when content moves underneath.

**The bar's own background must be `.clear`.** This is the easiest way to
silently destroy the effect: give the header an opaque `.systemBackground` and
content is *hidden behind* it, so the charts visibly cut off at its edge and the
pills stop reading as glass entirely. If you want the bar to look white, let the
white come from the scroll view underneath — it shows through and looks
identical at rest, while still letting content travel under the glass.

Practically, for any floating glass bar:
1. Host it **outside** the scroll view. In a `UITableViewController`, `view` IS
   the table — a subview added there scrolls away. Add it to
   `navigationController?.view` and pin it to the safe area.
2. Reserve its height with `scrollView.contentInset.top` (plus
   `verticalScrollIndicatorInsets`), so content rests below it but passes under.
3. **Size the content to the full viewport, not "viewport minus bar."** This is
   the step that gets missed: if the content is sized to fit exactly, the scroll
   view never scrolls, nothing ever moves behind the glass, and it looks flat.

Worked example: `StatusTableViewController.floatingHUDView` +
`updateFloatingHUDInset()` + the `heightForRowAt` comment for `.charts`.

## Floating "Continue" pill

- Bottom-anchored floating capsule (bottom-trailing in the meal screen).
- Accent-tinted interactive glass when enabled; plain glass + secondary text when disabled.
- Must clearly FLOAT: `.shadow(color: .black.opacity(0.22), radius: 14, y: 5)` and lift
  clear of the home indicator (`.padding(.bottom, 10)` on top of the safe area).
- Reserve scroll space beneath content so nothing hides under it
  (`Color.clear.frame(height: 112)` at the end of the scroll stack).
- Disabled state nudges to `scaleEffect(0.96)`.

## Haptics (SwiftUI `.sensoryFeedback`)

Meal screen wires: `.impact(.light)` on sub-block count change, `.selection` on
picker expand, `.impact(.soft)` on favorite toggle, `.success` on save/dismiss,
`.impact(.medium)` on +15. Keep new interactions consistent with these.

## Conventions

- **Content fades under the top bar; it is never cut by it.** Screens apply
  `loopSoftTopEdge()` (`.scrollEdgeEffectStyle(.soft, for: .top)`) and do NOT pin an
  opaque `toolbarBackground`. Pinning one paints a flat plate with a hard bottom edge
  AND opts the bar out of the system's scroll-edge effect, so rows scrolling up stop
  mid-glyph. An opaque background wins over the effect — if the cut comes back, that
  is what to look for.
- **No `.shadow` and no opacity animation around a glass element.** Both force the
  glass to composite offscreen, where it has no backdrop to sample and renders dark
  until compositing settles — this is what made the action island flash dark as it
  appeared. Glass carries its own elevation.
- Every user-facing string uses `NSLocalizedString(_, comment:)` / `Text(_, comment:)`.
- New optional features are **opt-in and additive** with a master toggle + a hard
  kill-switch (see the AI carb feature). Off = app behaves exactly as before.
- Secrets go in the Keychain (`CarbAIKeychain`), never UserDefaults.
- **Toolbar items must stay native `UIBarButtonItem`s.** A `UIBarButtonItem(customView:)`
  does **not** participate in the toolbar's shared Liquid Glass background, so the moment
  one item becomes a custom view the grouped glass capsule breaks apart. That means no
  hand-rolled press animations on bar buttons either — the system's own bar-button press
  feedback is the price of the shared glass. This is written here because it was already
  noted in a worklog entry, got missed, and had to be reverted: a change swapped every
  control to a custom-view button with a spring scale animation and silently lost the
  grouped menu. If a bar button needs to look or behave differently, change its *image* or
  its tint, not its class. (The one exception already in the tree is `mealButton`, whose
  custom view predates this and exists for the long-press meal picker.)
- Anything that must **not** swallow touches outside its visible shape needs explicit
  hit-testing — see `PassthroughToolbar` in `Loop/View Controllers/RootNavigationController.swift`,
  which only claims touches landing on a `UIControl` so the transparent area around the
  floating glass capsule stays scrollable.
