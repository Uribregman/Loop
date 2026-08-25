//
//  ActionIslandView.swift
//  Loop
//
//  A Dynamic-Island-style status element for the home screen.
//  When a single action is active it renders as a full-width glass pill; when
//  multiple actions are active it splits so the primary action (a bolus, when
//  present) stays the largest pill and the others collapse into small circular
//  glass bubbles alongside it.
//
//  Styling follows the app-wide liquid-glass design system in GlassStyles.swift
//  (glass, press-expand, exact contentShape hitboxes). Pill and bubbles share
//  ONE height and ONE neutral glass shade — only the glyphs inside are tinted.
//
//  This uses the real iOS 26 Liquid Glass infrastructure: every element is a
//  `.glassEffect` inside a single `GlassEffectContainer`, so the system renders
//  them as ONE combined glass layer. That is what makes the pill and bubbles
//  fluidly merge/split (via `glassEffectID`) instead of cross-fading, and it is
//  also why they no longer need the old flat opaque fill — a container renders
//  one shared material with no per-element drop shadow, which was the original
//  reason the row didn't sit flush on the background in light mode.
//

import SwiftUI

// MARK: - Model

/// One active item that can appear in the action island.
struct ActionIslandItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bolus
        case override
        case preMeal
        case pumpSuspended
        case info
    }

    let id: String
    var kind: Kind
    /// SF Symbol name used for the icon (works collapsed as a bubble and inside the pill).
    var symbolName: String
    /// The preset's own emoji, when it has one. Shown INSTEAD of `symbolName`,
    /// so a custom preset reads as its own icon rather than a generic target.
    var emoji: String?
    var title: String
    var subtitle: String?
    /// 0...1 when the item represents ongoing progress (e.g. a bolus). `nil` otherwise.
    var progress: Double?
    var tint: Color
    /// Whether tapping this item performs an action (drives whether it reads as a button).
    var isActionable: Bool = false

    /// Lower sorts first / larger. Bolus is always the primary element,
    /// then overrides, then informational prompts (e.g. no recent glucose).
    var priority: Int {
        switch kind {
        case .bolus:         return 0
        case .pumpSuspended: return 1
        case .override:      return 2
        case .preMeal:       return 3
        case .info:          return 4
        }
    }
}

// MARK: - Glyph

/// The item's icon: its emoji when it has one, otherwise the SF Symbol.
private struct IslandGlyph: View {
    let item: ActionIslandItem
    var pointSize: CGFloat

    var body: some View {
        if let emoji = item.emoji {
            Text(emoji)
                .font(.system(size: pointSize + 2))
        } else {
            Image(systemName: item.symbolName)
                .font(.system(size: pointSize, weight: .semibold))
                .foregroundStyle(item.tint)
        }
    }
}

// MARK: - Metrics

/// One shared height for the pill AND every bubble so the split never renders
/// mismatched element heights.
private let islandHeight: CGFloat = 32

/// Distance at which neighbouring glass elements start to merge into each other.
/// Matches the HStack spacing so the bubbles feel attached to the pill as they
/// come and go, the way the system's own Liquid Glass groups do.
private let islandGlassSpacing: CGFloat = 6

/// Liquid-glass island element: real `.glassEffect`, exact-shape hitbox, tap pulse.
///
/// Actionable elements use `.interactive()` glass so the material itself reacts
/// to touch (the system's own press feedback), on top of the app's shared
/// press-expand pulse. Non-actionable elements are plain regular glass.
///
/// Deliberately NOT a `Button`: SwiftUI silently expands small buttons' touch
/// targets toward the 44pt accessibility minimum, so taps just outside the
/// visible shape still fired. A plain tap gesture honors `contentShape`
/// EXACTLY — the hitbox is the pill/bubble outline, nothing more.
private struct IslandElementModifier<S: Shape>: ViewModifier {
    let shape: S
    let isActionable: Bool
    let scale: CGFloat
    /// Stable identity so the container morphs this element between the pill and
    /// bubble layouts instead of fading one out and the other in.
    let glassID: String
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var pulsing = false

    private var glass: Glass {
        isActionable ? .regular.interactive() : .regular
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: shape)
            .glassEffectID(glassID, in: namespace)
            // Hit area is deliberately LARGER than the drawn pill. Tapping a
            // running bolus to cancel it was fiddly because the target was
            // exactly the visible capsule. Padding out, taking a RECTANGULAR
            // hit shape over that grown frame, then padding back in adds margin
            // on every side without moving or resizing anything visible.
            //
            // The two margins differ on purpose. VERTICAL is generous: it takes
            // a 32pt element to 48pt, past the 44pt accessibility minimum, and
            // it now fits because the island owns the gaps above and below it
            // (`topGap`/`bottomGap`) — outside the hosting view's bounds UIKit
            // would never deliver the touch. HORIZONTAL is exactly HALF the
            // spacing between elements, so neighbouring hit areas meet but never
            // OVERLAP; overlapping ones let a tap aimed at the bolus pill land
            // on the bubble beside it, which is the wrong action entirely.
            .padding(.vertical, islandTouchMargin)
            .padding(.horizontal, islandGlassSpacing / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -islandTouchMargin)
            .padding(.horizontal, -islandGlassSpacing / 2)
            .scaleEffect(pulsing ? scale : 1)
            .onTapGesture {
                guard isActionable else { return }
                // Quick press-expand pulse, then perform the action.
                withAnimation(loopPressAnimation) { pulsing = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(loopPressAnimation) { pulsing = false }
                }
                action()
            }
            .allowsHitTesting(isActionable)
    }
}

private extension View {
    func islandElement(shape: some Shape,
                       isActionable: Bool,
                       scale: CGFloat,
                       glassID: String,
                       namespace: Namespace.ID,
                       action: @escaping () -> Void) -> some View {
        modifier(IslandElementModifier(shape: shape,
                                       isActionable: isActionable,
                                       scale: scale,
                                       glassID: glassID,
                                       namespace: namespace,
                                       action: action))
    }
}

// MARK: - View

struct ActionIslandView: View {
    /// The currently-active items, in any order. The view sorts them by priority.
    var items: [ActionIslandItem]

    /// Space above and below the island. Both come from the host
    /// (`StatusTableViewController`), which passes the SAME value for each.
    ///
    /// ⚠️ THE GAP ABOVE IS INSIDE THIS VIEW ON PURPOSE — it used to be the
    /// header stack's `spacing`, i.e. OUTSIDE the hosting view's bounds. UIKit
    /// hit-tests a hosting view's bounds before SwiftUI ever sees the touch, so
    /// the extra tappable margin `islandTouchMargin` adds above a pill was
    /// simply cut off: the top edge of every element was dead to touch. Owning
    /// the gap means the margin lands inside the bounds and the hitbox is whole.
    /// (The stack's spacing is 0 now; do not put it back.)
    var topGap: CGFloat = 8
    var bottomGap: CGFloat = 8

    /// Called with the tapped item. Only actionable items react.
    var onTap: (ActionIslandItem) -> Void = { _ in }

    /// Shared namespace so every element's `glassEffectID` resolves against the
    /// same container and the pill↔split change is one continuous glass morph.
    @Namespace private var glassNamespace

    private var sorted: [ActionIslandItem] {
        items.sorted { $0.priority < $1.priority }
    }

    var body: some View {
        // ONE container renders every element as a single combined glass layer,
        // so neighbouring elements merge as they approach and split as they part.
        GlassEffectContainer(spacing: islandGlassSpacing) {
            HStack(spacing: islandGlassSpacing) {
                if let primary = sorted.first {
                    PillView(item: primary, onTap: onTap, namespace: glassNamespace)
                        .layoutPriority(1)

                    ForEach(Array(sorted.dropFirst())) { item in
                        BubbleView(item: item, onTap: onTap, namespace: glassNamespace)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The island is hosted directly in the fixed top header, so it owns
            // its own insets. Aligned with the status pills' 6pt outer margin
            // plus a little more, so it sits under them rather than flush to the
            // screen edge. The vertical gap above comes from the header stack's
            // spacing; this is the breathing room below.
            .padding(.horizontal, 16)
            .padding(.top, topGap)
            .padding(.bottom, bottomGap)
        }
        // ⚠️ NO `.shadow` HERE, AND NO OPACITY ANIMATION ON THE HOST VIEW.
        // Both force the glass to be composited OFFSCREEN, where it has no
        // backdrop to sample, so it renders as a dark plate for the first
        // frames after it appears and only resolves once compositing settles —
        // the "island flashes dark when it shows up" bug. Glass already carries
        // its own elevation; it does not need a drop shadow. See
        // `StatusTableViewController.updateIslandItems` for the matching rule
        // on the UIKit side.
        // One smooth, slightly lazy spring for the pill↔split morph.
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: sorted.map(\.id))
    }
}

// MARK: - Pill (primary element)

private struct PillView: View {
    let item: ActionIslandItem
    let onTap: (ActionIslandItem) -> Void
    let namespace: Namespace.ID

    private var content: some View {
        HStack(spacing: 7) {
            ZStack {
                if let progress = item.progress {
                    ProgressRing(progress: progress, tint: item.tint)
                        .frame(width: 20, height: 20)
                } else if item.kind != .bolus {
                    // Keyed on KIND, not on `progress`. Keying it on progress
                    // meant the glyph reappeared for a frame during cancel, as
                    // progress goes nil just before the island collapses.
                    IslandGlyph(item: item, pointSize: 12)
                }
            }
            .frame(width: 22, height: 22)

            Text(item.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    // Equal-width digits, so a ticking value never nudges the
                    // pill's width even when the digit COUNT is unchanged.
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        // Hugs its content instead of stretching to the full width: a
        // half-empty full-width capsule reads as a bar, not as a glass pill,
        // and it has to match the sizing of the status pills above it.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: islandHeight)
    }

    var body: some View {
        content
            .islandElement(shape: Capsule(),
                           isActionable: item.isActionable,
                           scale: loopPressScaleLarge,
                           glassID: item.id,
                           namespace: namespace) {
                onTap(item)
            }
    }
}

// MARK: - Bubble (collapsed secondary element)

private struct BubbleView: View {
    let item: ActionIslandItem
    let onTap: (ActionIslandItem) -> Void
    let namespace: Namespace.ID

    private var content: some View {
        ZStack {
            if let progress = item.progress {
                ProgressRing(progress: progress, tint: item.tint)
                    .padding(4)
            } else if item.kind != .bolus {
                IslandGlyph(item: item, pointSize: 13)
            }
        }
        .frame(width: islandHeight, height: islandHeight)
    }

    var body: some View {
        content
            .islandElement(shape: Circle(),
                           isActionable: item.isActionable,
                           scale: loopPressScaleSmall,
                           glassID: item.id,
                           namespace: namespace) {
                onTap(item)
            }
    }
}

/// Extra tappable margin above and below an island element. See the note in
/// `IslandElementModifier` for why the horizontal one is different.
private let islandTouchMargin: CGFloat = 8

// MARK: - Progress ring

private struct ProgressRing: View {
    var progress: Double
    var tint: Color

    var body: some View {
        ZStack {
            // 4pt. With the glyph gone from the middle the ring carries the
            // whole element on its own, and a hairline read as faint.
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
    }
}

// MARK: - Preview

struct ActionIslandView_Previews: PreviewProvider {
    static let bolus = ActionIslandItem(id: "bolus", kind: .bolus, symbolName: "drop.fill",
                                        title: "Bolusing", subtitle: "2.1 of 5.0 U",
                                        progress: 0.42, tint: .blue, isActionable: true)
    static let override = ActionIslandItem(id: "override", kind: .override, symbolName: "figure.run",
                                           title: "Workout", subtitle: "until 3:00 PM",
                                           progress: nil, tint: .green, isActionable: true)
    static let glucose = ActionIslandItem(id: "glucose", kind: .info, symbolName: "drop.circle",
                                          title: "No Recent Glucose", subtitle: "Tap to Add",
                                          progress: nil, tint: .green, isActionable: true)

    static var previews: some View {
        VStack(spacing: 10) {
            ActionIslandView(items: [bolus])
            ActionIslandView(items: [bolus, override])
            ActionIslandView(items: [glucose, override])
            ActionIslandView(items: [override])
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}
