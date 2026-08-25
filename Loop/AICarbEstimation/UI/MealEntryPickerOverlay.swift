//
//  MealEntryPickerOverlay.swift
//  Loop
//
//  The meal-button picker: two liquid-glass bubbles (AI ✨ / Manual ✏️) that pop
//  up above the carb toolbar button. Tap a bubble, or hold the meal button and
//  slide onto one, to choose. Tapping anywhere else dismisses. Haptics included.
//

import UIKit
import SwiftUI

final class MealEntryPickerOverlay: UIView {

    enum Choice { case ai, manual, none }

    private let onSelect: (Choice) -> Void
    private let anchor: CGRect

    private var bubbles: [(choice: Choice, view: UIView, button: UIButton)] = []
    private var hovered: Choice = .none
    /// Retains the SwiftUI hosts backing the glass bubbles (iOS 26 path).
    private var bubbleHosts: [UIViewController] = []
    /// The meal icon's center, kept so dismissal can fly bubbles back into it.
    private var iconCenter: CGPoint = .zero

    private let showHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let hoverHaptic = UISelectionFeedbackGenerator()
    private let selectHaptic = UIImpactFeedbackGenerator(style: .rigid)

    init(anchor: CGRect, onSelect: @escaping (Choice) -> Void) {
        self.anchor = anchor
        self.onSelect = onSelect
        super.init(frame: .zero)
        backgroundColor = .clear

        let backdrop = UIButton(type: .custom)
        backdrop.backgroundColor = .clear
        backdrop.addTarget(self, action: #selector(backdropTapped), for: .touchUpInside)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Manual uses the SAME icon as the carb toolbar button ("carbs" asset);
        // AI keeps the sparkles.
        let specs: [(Choice, UIImage?, String)] = [
            (.manual, UIImage(named: "carbs"), NSLocalizedString("Manual", comment: "Manual entry bubble")),
            (.ai, UIImage(systemName: "sparkles"), NSLocalizedString("AI", comment: "AI entry bubble"))
        ]
        for (choice, icon, label) in specs {
            let view = makeBubble(icon: icon, label: label)
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                button.topAnchor.constraint(equalTo: view.topAnchor),
                button.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            button.addAction(UIAction { [weak self] _ in self?.select(choice) }, for: .touchUpInside)
            bubbles.append((choice, view, button))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    // MARK: - Bubble construction (real liquid glass on iOS 26)

    private func makeBubble(icon: UIImage?, label: String) -> UIView {
        let size: CGFloat = 36

        let container: UIView
        if #available(iOS 26.0, *) {
            // REAL tinted liquid glass via SwiftUI's .glassEffect(.tint(...)) —
            // the same modifier already proven working in MealEntryView (the
            // tinted Continue pill). UIGlassEffect.tintColor renders white on
            // this SDK, so the UIKit path is not used.
            let host = UIHostingController(rootView: BubbleGlassView(icon: icon))
            host.view.backgroundColor = .clear
            bubbleHosts.append(host)
            container = host.view
        } else {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            blur.contentView.backgroundColor = Self.bubbleGreen.withAlphaComponent(0.9)
            blur.layer.cornerRadius = size / 2
            blur.clipsToBounds = true
            container = blur

            let imageView = UIImageView(image: icon?.withRenderingMode(.alwaysTemplate))
            // Inverted vs. the background: WHITE icon in light mode, BLACK in dark.
            imageView.tintColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            blur.contentView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 22),
                imageView.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: size).isActive = true
        container.heightAnchor.constraint(equalToConstant: size).isActive = true

        // No caption — just the bubble. `label` is kept for accessibility.
        container.isAccessibilityElement = true
        container.accessibilityLabel = label

        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])
        // Soft drop shadow for depth (applied to the unclipped wrapper).
        wrapper.layer.shadowColor = UIColor.black.cgColor
        wrapper.layer.shadowOpacity = 0.28
        wrapper.layer.shadowRadius = 9
        wrapper.layer.shadowOffset = CGSize(width: 0, height: 5)

        addSubview(wrapper)
        return wrapper
    }

    /// SwiftUI bubble: tinted interactive liquid glass in a circle — the same
    /// .glassEffect(.tint(...)) that renders correctly elsewhere in the app.
    private struct BubbleGlassView: View {
        let icon: UIImage?
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Group {
                if let icon {
                    Image(uiImage: icon.withRenderingMode(.alwaysTemplate))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                }
            }
            // Inverted vs. the background: WHITE icon in light mode, BLACK in dark.
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(width: 36, height: 36)
            // Translucent tint lets the glass refraction show (full-opacity tint
            // rendered as a flat disc); slightly more solid in dark for punch.
            .glassEffect(.regular
                .tint(Color(MealEntryPickerOverlay.bubbleGreen).opacity(colorScheme == .dark ? 0.9 : 0.72))
                .interactive(), in: Circle())
            // Hairline edge keeps the bubble crisp, especially on dark.
            .overlay(
                Circle().strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.28 : 0.4),
                    lineWidth: 0.5
                )
            )
        }
    }

    /// Dynamic carb green: the exact toolbar carb color in light mode, pushed
    /// deeper/darker in dark mode so the bubble keeps depth on black.
    fileprivate static var bubbleGreen: UIColor {
        UIColor { traits in
            let base = UIColor.carbTintColor.resolvedColor(with: traits)
            guard traits.userInterfaceStyle == .dark else { return base }
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            if base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
                return UIColor(hue: hue, saturation: min(1, sat * 1.15), brightness: bri * 0.6, alpha: alpha)
            }
            return base
        }
    }

    // MARK: - Show / dismiss

    func show() {
        layoutIfNeeded()
        for bubble in bubbles {
            bubble.view.translatesAutoresizingMaskIntoConstraints = true
            bubble.view.frame.size = bubble.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }

        // Diagonal arc on the upper-RIGHT of the meal icon, both bubbles the same
        // distance from it: manual nearly straight up (95°), AI up-right (45°).
        // Radius is tight enough that they slightly overlap the bottom bar.
        let radius: CGFloat = 48
        let iconCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        self.iconCenter = iconCenter
        // 70° apart → bubble centers ~55pt apart, so 44pt bubbles never touch.
        let angles: [CGFloat] = [105, 35]   // degrees; index-matched to bubbles
        var centers = angles.map { angle -> CGPoint in
            let rad = angle * .pi / 180
            return CGPoint(x: iconCenter.x + radius * cos(rad),
                           y: iconCenter.y - radius * sin(rad))
        }

        // Keep the pair on-screen (shift left/right as needed).
        let halfWidth = (bubbles.first?.view.frame.width ?? 44) / 2
        let minX = safeAreaInsets.left + 8 + halfWidth
        let maxX = bounds.width - safeAreaInsets.right - 8 - halfWidth
        let leftmost = centers.map { $0.x }.min() ?? 0
        let rightmost = centers.map { $0.x }.max() ?? 0
        if leftmost < minX {
            let shift = minX - leftmost
            centers = centers.map { CGPoint(x: $0.x + shift, y: $0.y) }
        } else if rightmost > maxX {
            let shift = rightmost - maxX
            centers = centers.map { CGPoint(x: $0.x - shift, y: $0.y) }
        }

        // zip, not an index: `angles` is a fixed pair while `bubbles` is built
        // elsewhere, so indexing would crash the moment a third bubble is added.
        // zip just stops at the shorter one.
        for (bubble, center) in zip(bubbles, centers) {
            let view = bubble.view
            view.center = center
            view.alpha = 0
            // Grow out of the icon itself.
            view.transform = CGAffineTransform(
                translationX: iconCenter.x - center.x,
                y: iconCenter.y - center.y
            ).scaledBy(x: 0.2, y: 0.2)
        }
        showHaptic.impactOccurred()
        // Staggered springs: each bubble pops out of the icon a beat after the
        // previous one. Under Reduce Motion it's a plain fade instead.
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for (i, bubble) in bubbles.enumerated() {
            if reduceMotion {
                bubble.view.transform = .identity
                UIView.animate(withDuration: 0.2) { bubble.view.alpha = 1 }
            } else {
                UIView.animate(withDuration: 0.5, delay: Double(i) * 0.06,
                               usingSpringWithDamping: 0.62, initialSpringVelocity: 0.9) {
                    bubble.view.alpha = 1
                    bubble.view.transform = .identity
                }
            }
        }
    }

    func dismiss() {
        dismiss(highlighting: .none)
    }

    /// Dismisses the picker. The selected bubble (if any) pops OUTWARD as it
    /// fades — visual confirmation — while the others fly back INTO the icon
    /// they grew out of, in reverse-staggered order.
    private func dismiss(highlighting choice: Choice) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard !bubbles.isEmpty else { removeFromSuperview(); return }
        var remaining = bubbles.count
        for (i, bubble) in bubbles.enumerated() {
            let view = bubble.view
            let isChosen = bubble.choice == choice
            let delay = (reduceMotion || isChosen) ? 0 : Double(bubbles.count - 1 - i) * 0.05
            UIView.animate(withDuration: reduceMotion ? 0.15 : (isChosen ? 0.35 : 0.3),
                           delay: delay,
                           usingSpringWithDamping: isChosen ? 0.55 : 0.85,
                           initialSpringVelocity: 0.6,
                           options: [.beginFromCurrentState],
                           animations: {
                view.alpha = 0
                if !reduceMotion {
                    view.transform = isChosen
                        ? CGAffineTransform(scaleX: 1.4, y: 1.4)              // selected: pop out
                        : CGAffineTransform(translationX: self.iconCenter.x - view.center.x,
                                            y: self.iconCenter.y - view.center.y)
                            .scaledBy(x: 0.15, y: 0.15)                       // others: back into the icon
                }
            }, completion: { _ in
                remaining -= 1
                if remaining == 0 { self.removeFromSuperview() }
            })
        }
    }

    @objc private func backdropTapped() {
        dismiss()
        onSelect(.none)
    }

    private func select(_ choice: Choice) {
        selectHaptic.impactOccurred()
        dismiss(highlighting: choice)
        onSelect(choice)
    }

    // MARK: - Slide-to-select (driven by the meal button's long press)

    func updateHover(at point: CGPoint) {
        // `point` arrives in the parent view's coordinates; self fills the parent,
        // so the coordinate spaces match.
        var newHover: Choice = .none
        for bubble in bubbles {
            let expanded = bubble.view.frame.insetBy(dx: -14, dy: -14)
            if expanded.contains(point) {
                newHover = bubble.choice
            }
        }
        if newHover != hovered {
            hovered = newHover
            hoverHaptic.selectionChanged()
            // Springy focus: the hovered bubble swells while the other recedes
            // slightly, so the finger's target is unmistakable.
            UIView.animate(withDuration: 0.32, delay: 0,
                           usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                for bubble in self.bubbles {
                    if bubble.choice == newHover {
                        bubble.view.transform = CGAffineTransform(scaleX: 1.24, y: 1.24)
                    } else {
                        bubble.view.transform = newHover == .none
                            ? .identity
                            : CGAffineTransform(scaleX: 0.9, y: 0.9)
                    }
                }
            }
        }
    }

    func commitHoverOrDismiss() {
        if hovered != .none {
            select(hovered)
        } else {
            // Held and released without landing on a bubble → fade them away.
            dismiss()
            onSelect(.none)
        }
    }
}
