//
//  GlassStyles.swift
//  Loop
//
//  App-wide liquid-glass design system so every screen matches the carb-entry
//  look: big tiles use the same 24pt continuous corners + glass, big action
//  buttons use a capsule "pill" like the meal-name field, and every button
//  fluidly EXPANDS on press (instead of dimming).
//
//  See docs/DESIGN_SYSTEM.md for the canonical spec (roundness, tints,
//  animation curves). Change the constants here, not in individual views.
//

import SwiftUI
import UIKit

// MARK: - Roundness

/// Corner radius of the carb-entry cards — the standard for all big tiles.
let loopTileCornerRadius: CGFloat = 24
/// Corner radius for smaller inset controls sitting on a tile.
let loopControlCornerRadius: CGFloat = 14

// MARK: - Motion

/// The one spring used for press feedback across the app. Lively but smooth,
/// settles quickly with no visible bounce overshoot on release.
let loopPressAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.62)
/// How much a control grows while pressed. Big/full-width controls use the
/// smaller value so they don't clip at the screen edges; compact pills/chips
/// can use the larger one.
let loopPressScaleLarge: CGFloat = 1.03   // full-width action buttons
let loopPressScaleSmall: CGFloat = 1.05   // compact pills, chips, icons

/// Universal "expand on press" button style. Use this (or one of the styles
/// below, which build on the same motion) for ANY tappable control so the whole
/// app shares one press feel: the control fluidly scales up while held, then
/// springs back — never dims.
struct PressExpandButtonStyle: ButtonStyle {
    var scale: CGFloat = loopPressScaleSmall
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(loopPressAnimation, value: configuration.isPressed)
    }
}

extension View {
    /// Attach the universal press-expand feedback to a custom-styled button's
    /// label when you can't replace its whole ButtonStyle.
    func loopPressExpand(_ isPressed: Bool, scale: CGFloat = loopPressScaleSmall) -> some View {
        self
            .scaleEffect(isPressed ? scale : 1)
            .animation(loopPressAnimation, value: isPressed)
    }
}

extension Color {
    /// ONE unified screen background for the carb + bolus screens. In dark mode
    /// this is a single fixed shade (independent of sheet elevation, which is
    /// what made the two screens resolve different darks); light mode keeps the
    /// standard grouped background.
    static var loopScreenBackground: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.05, alpha: 1)
                : UIColor.systemGroupedBackground.resolvedColor(with: traits)
        })
    }
}

extension Color {
    /// Unified tile tint: pins every glass tile to ONE shade in dark mode
    /// (adaptive glass otherwise samples its surroundings, so tiles on
    /// different screens rendered different darks). Light mode: no tint.
    static var loopTileTint: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.14, alpha: 0.92)
                : UIColor(white: 1, alpha: 0)
        })
    }

    /// Small controls that sit ON a tile (mini stat tiles, meal-name pill,
    /// photo/heart bubble, +15, selected emoji): stands out against the tile in
    /// BOTH modes — lighter shade in dark, a soft grey fill in light.
    static var loopControlTint: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.30, alpha: 0.9)
                : UIColor(white: 0.0, alpha: 0.10)
        })
    }

    /// SELECTED state for a control that also exists unselected next to it
    /// (food-type presets, an open value chip). Deliberately a step darker than
    /// `loopControlTint` — at that weight the selection didn't read against its
    /// unselected neighbours.
    static var loopSelectionTint: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.46, alpha: 0.95)
                : UIColor(white: 0.0, alpha: 0.22)
        })
    }
}

extension View {
    /// Big-tile liquid glass, exactly like the carb-entry cards.
    /// Tinted so all tiles share one shade in dark mode.
    func loopTileGlass() -> some View {
        glassEffect(.regular.tint(Color.loopTileTint), in: RoundedRectangle(cornerRadius: loopTileCornerRadius, style: .continuous))
    }

    /// Apply interactive glass only when `condition` is true (e.g. selection states).
    @ViewBuilder
    func glassIf(_ condition: Bool, in shape: some Shape) -> some View {
        if condition {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            self
        }
    }
}

/// The five time-in-range band colours, low → high: purple, red, green, yellow,
/// orange. These are NOT `guidanceColors` — the bands need five distinguishable
/// steps where guidance only has three, and the low and high sides must never
/// share a colour.
///
/// Each step was picked by running the pairwise separation numbers, not by eye,
/// and the light and dark sets are chosen independently (dark is not a flip).
/// Adjacent-pair separation in OKLab ΔE×100 — normal vision / worst of
/// deuteranopia+protanopia:
///
///   light: purple→red 27.2/27.0 · red→green 34.7/14.3 · green→yellow 28.3/18.5 · yellow→orange 21.5/17.6
///   dark:  purple→red 27.5/26.9 · red→green 37.8/12.6 · green→yellow 23.1/10.8 · yellow→orange 18.7/14.3
///
/// The red is deliberately DARK in light mode: red and green collapse to almost
/// the same hue for a deuteranope, so the lightness gap is what keeps them apart
/// (it took that pair from ΔE 4.1 to 14.3). Don't "brighten the red" without
/// re-running the numbers.
enum GlucoseBandColor {
    static let veryLow  = dynamic(light: 0x7B4DD8, dark: 0x9B6BFF)   // purple
    static let low      = dynamic(light: 0xB01B2E, dark: 0xD93A50)   // red
    static let inRange  = dynamic(light: 0x2FA84F, dark: 0x34C759)   // green
    static let high     = dynamic(light: 0xFFD426, dark: 0xFFDA47)   // yellow
    static let veryHigh = dynamic(light: 0xF07B20, dark: 0xFF8A2B)   // orange

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Liquid-glass button that expands on press — the infrastructure piece for
/// interactive glass controls. It couples the glass effect, the hit shape, AND
/// the shared press-expand into ONE style, so the glass itself grows when held.
///
/// Prefer this over the old pattern of `.glassEffect(...)` on a label wrapped in
/// `.buttonStyle(.plain)` (that gives glass but no expand). Example:
///   Button { … } label: { Image(systemName: "camera.fill").frame(width: 52, height: 52) }
///       .buttonStyle(GlassButtonStyle(in: Circle()))
struct GlassButtonStyle<S: Shape>: ButtonStyle {
    private let glass: Glass
    private let shape: S
    private let scale: CGFloat

    init(_ glass: Glass = .regular.interactive(), in shape: S, scale: CGFloat = loopPressScaleSmall) {
        self.glass = glass
        self.shape = shape
        self.scale = scale
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(glass, in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(loopPressAnimation, value: configuration.isPressed)
    }
}

/// Full-width pill action button (same height feel as the standard action
/// button, but capsule-shaped liquid glass like the meal-name field).
struct PillActionButtonStyle: ButtonStyle {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    private let style: Style

    init(_ style: Style = .primary) {
        self.style = style
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(foreground)
            .glassEffect(glass, in: Capsule())
            // Whole pill is tappable, not just the text glyphs.
            .contentShape(Capsule())
            // Fluidly expand on press (never dim) — shared app-wide feel.
            .scaleEffect(configuration.isPressed ? loopPressScaleLarge : 1)
            .animation(loopPressAnimation, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch style {
        case .primary:     return .white
        case .secondary:   return .accentColor
        case .destructive: return .white
        }
    }

    private var glass: Glass {
        switch style {
        case .primary:     return .regular.tint(Color.accentColor).interactive()
        case .secondary:   return .regular.interactive()
        case .destructive: return .regular.tint(Color.red).interactive()
        }
    }
}

// MARK: - Scrolling under the top bar

extension View {
    /// Content should DISSOLVE under the navigation bar, not be sliced by it.
    ///
    /// Every screen here used to pin an opaque `toolbarBackground` of
    /// `loopScreenBackground` over the bar. That produced a flat dark plate with
    /// a hard bottom edge: a row of text scrolling up simply stopped mid-glyph
    /// at the line where the plate began. Pinning the background also opts the
    /// bar OUT of the system's scroll-edge effect, so the cut was the only thing
    /// on offer.
    ///
    /// This restores the system effect and asks for the SOFT variant: a
    /// progressive blur-and-fade over the top edge, so content thins out into
    /// the bar's shade instead of ending at a line. Apply it to the screen root
    /// (the view carrying the navigation title) and do NOT re-add
    /// `toolbarBackground(.visible,…)` next to it — an opaque background wins,
    /// and the cut comes back.
    func loopSoftTopEdge() -> some View {
        scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Keyboard

/// Publishes the on-screen keyboard's height, so a floating control can be
/// placed a deliberate distance above it.
///
/// SwiftUI's automatic keyboard avoidance is not enough for the floating pills:
/// it moves a view only when IT decides the view is affected, which is why the
/// Continue pill rose above the keypad on some entry paths and not on others.
/// Reading the height directly makes the placement the same every time.
@MainActor
final class LoopKeyboardObserver: ObservableObject {
    /// Keyboard height in points, 0 when hidden.
    @Published var height: CGFloat = 0

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.apply(note) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.height = 0 }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func apply(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let screen = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.screen.bounds.height }).first else { return }
        // Off-screen end frame = dismissing.
        height = max(0, screen - frame.origin.y)
    }
}
