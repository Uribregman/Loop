//
//  StatusBarHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit
import LoopKitUI

public class StatusBarHUDView: UIView, NibLoadable {
    
    @IBOutlet public weak var cgmStatusHUD: CGMStatusHUDView!
    
    @IBOutlet public weak var loopCompletionHUD: LoopCompletionHUDView!
    
    @IBOutlet public weak var pumpStatusHUD: PumpStatusHUDView!
        
    public var containerView: UIStackView!
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                cgmStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                pumpStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                containerView.spacing = adjustViewsForNarrowDisplay ? 8.0 : 16.0
                setNeedsLayout()
            }
        }
    }

    override public var bounds: CGRect {
        didSet {
            // need to adjust for narrow display. The labels in the status bar need more space when the bounds width is less than 350 points.
            adjustViewsForNarrowDisplay = bounds.width < 350
        }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    /// Renders the three status elements as one combined Liquid Glass group.
    /// Every glass element is a nested `UIVisualEffectView` inside this
    /// container, which is how `UIGlassContainerEffect` is meant to be used:
    /// it draws them as a single material behind its own `contentView`, so
    /// neighbouring pills merge instead of each casting its own edge.
    private var glassContainerView: UIVisualEffectView!

    /// Distance at which two glass elements begin to merge into one another.
    ///
    /// Zero on purpose: the three status elements should read as three separate
    /// capsules. Any value above the stack spacing makes the container fuse them
    /// into one continuous slab with the pills embedded in it, which reads as a
    /// grey box rather than as distinct glass pills.
    private static let glassMergeSpacing: CGFloat = 0

    /// Zero on purpose: each glass capsule traces its HUD view's ORIGINAL bounds,
    /// so the bar keeps the dimensions and proportions it had before the glass
    /// pass — only the material changed.
    private static let glassContentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    /// Small margin so the outer capsules' rounded ends aren't flush to the bezel.
    private static let horizontalInset: CGFloat = 6

    /// Gap above/below the pills inside the bar.
    /// Top gap above the pills, and bottom gap below whatever is last.
    ///
    /// The pills sit LOWER than they used to. Widening the pill-to-line gap was
    /// the wrong lever — it moved the line away from the pill it belongs to and
    /// broke the pairing. Dropping the whole island instead keeps the line tight
    /// under its pill and buys the room at the top, where there was slack.
    private static let verticalInset: CGFloat = 4
    private static let topInset: CGFloat = 12

    /// Height of the floating pump lifecycle (pod/reservoir expiry) line.
    private static let lifecycleLineHeight: CGFloat = 6

    /// Grey for the unfilled remainder of a lifecycle line.
    ///
    /// Applied as a TINT on the groove's glass (`trackEffect.tintColor`), never as
    /// a `backgroundColor`. A flat wash over glass is what killed the reflection
    /// once already — see process lesson #3 and `lifecycleLineTopGap` above. Tint
    /// keeps the material and just colours it.
    private static let lifecycleTrackTint = UIColor.label.withAlphaComponent(0.18)

    /// How far the line stops short of the pump pill's edges at each end.
    private static let lifecycleLineInset: CGFloat = 14

    /// Gap between the bottom of a pill and the lifecycle line beneath it.
    ///
    /// ⚠️ DO NOT RAISE THIS. It looks like a harmless spacing knob and it is not.
    /// The line's `fill` is a `UIGlassEffect` view living in the same
    /// `UIGlassContainerEffect` as the pills, so the container renders the line's
    /// glass in relation to the pill above it — that interaction IS the reflection
    /// you can see hugging the line. Move the line out of range and the reflection
    /// silently disappears, leaving a flat coloured capsule.
    ///
    /// Raised to 8 on 2026-08-13 to put more air under the pills; it killed the
    /// reflection and had to be reverted the same day. The `verticalInset` comment
    /// above already recorded this ("widening the pill-to-line gap was the wrong
    /// lever") — that note is now here too, at the constant someone would actually
    /// reach for. To buy vertical air, drop the whole island instead.
    private static let lifecycleLineTopGap: CGFloat = 4

    /// One shared pill height for all three elements — shorter than the bounds
    /// the flat bar used, with the content centred inside. Not lower than this:
    /// the pump element's reservoir graphic starts overflowing the capsule.
    private static let pillHeight: CGFloat = 58

    func setup() {
        containerView = (StatusBarHUDView.nib().instantiate(withOwner: self, options: nil)[0] as! UIStackView)
        containerView.translatesAutoresizingMaskIntoConstraints = false

        let containerEffect = UIGlassContainerEffect()
        containerEffect.spacing = Self.glassMergeSpacing
        glassContainerView = UIVisualEffectView(effect: containerEffect)
        glassContainerView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(glassContainerView)
        glassContainerView.contentView.addSubview(containerView)

        // Use AutoLayout to have the stack view fill its entire container.
        NSLayoutConstraint.activate([
            glassContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassContainerView.topAnchor.constraint(equalTo: topAnchor),
            glassContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerView.leadingAnchor.constraint(equalTo: glassContainerView.contentView.leadingAnchor,
                                                   constant: Self.horizontalInset),
            containerView.trailingAnchor.constraint(equalTo: glassContainerView.contentView.trailingAnchor,
                                                    constant: -Self.horizontalInset),
            // The bar itself runs edge-to-edge from y=0 (see the host constraint
            // in StatusTableViewController) so its glass covers the status-bar
            // strip the way a real navigation bar does — otherwise scrolling
            // content emerges ABOVE the bar and collides with the clock. The
            // pills themselves stay below the status bar via the safe area.
            containerView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor,
                                               constant: Self.topInset),
        ])

        wrapArrangedViewsInGlass()

        // `.fill` and the nib's own spacing/min-widths are kept as-is so the
        // three elements sit exactly where they always did.
        containerView.distribution = .fill

        // The HUD views paint an opaque rounded fill from the flat-bar design.
        // Inside a glass capsule that fill is what you'd see instead of glass.
        cgmStatusHUD?.clearOpaqueBackground()
        pumpStatusHUD?.clearOpaqueBackground()

        // Puts the loop icon in the middle of its own view, so the glass ring
        // around it is even. See the note on the method.
        loopCompletionHUD?.centerLoopStateView()
        relaxLegacyDeviceWidthConstraints()

        installLifecycleLines()

        // Transparent, NOT white. An opaque bar hides the content behind it, so
        // the charts visibly cut off at its edge instead of travelling under the
        // glass — the pills stop reading as glass at all. The white comes from
        // the table underneath, which shows through and looks identical at rest.
        self.backgroundColor = .clear
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        updateDevicePillWidth()
    }

    private func updateDevicePillWidth() {
        guard let devicePillWidthConstraint, bounds.width > 0 else { return }

        let spacing = containerView.spacing
        let availableWidth = bounds.width - (Self.horizontalInset * 2) - Self.pillHeight - (spacing * 2)
        let devicePillWidth = max(0, floor(availableWidth / 2))

        if abs(devicePillWidthConstraint.constant - devicePillWidth) > 0.5 {
            devicePillWidthConstraint.constant = devicePillWidth
        }
    }

    private func relaxLegacyDeviceWidthConstraints() {
        for deviceHUD in [cgmStatusHUD, pumpStatusHUD] {
            deviceHUD?.constraints
                .filter { $0.firstAttribute == .width }
                .forEach { $0.priority = .defaultLow }
        }
    }

    // MARK: - Pump lifecycle line

    /// The glass capsule wrapping the CGM element, so its width can be matched
    /// to the pump capsule after the bar's final width is known.
    private weak var cgmGlassView: UIView?

    /// The glass capsule wrapping the loop element, so it can stay centered in
    /// the full bar while the device pills split the remaining width.
    private weak var loopGlassView: UIView?

    /// The glass capsule wrapping the pump element, so the lifecycle line can be
    /// aligned to exactly its width.
    private weak var pumpGlassView: UIView?

    private var devicePillWidthConstraint: NSLayoutConstraint?

    /// One expiry line: a full-lifetime glass groove with a tinted glass fill
    /// whose width is the elapsed fraction. The pump and the sensor each get
    /// their own, built identically.
    ///
    /// BOTH parts are Liquid Glass. The groove used to be a plain `UIView` with a
    /// flat `UIColor.label.withAlphaComponent(0.08)` wash, which is why the lines
    /// read as coloured capsules while the pills read as glass — the unfilled
    /// remainder was simply grey paint. It is now a `UIGlassEffect` view like the
    /// fill, so the whole line is one material.
    private final class LifecycleLine {
        let track: UIVisualEffectView
        let fill: UIVisualEffectView
        /// Held onto deliberately — see `update(line:with:)`. The tint is set on
        /// THIS object and the effect is then re-assigned to the view.
        let effect: UIGlassEffect
        /// The groove's own glass. Separate object from `effect`: one
        /// `UIGlassEffect` instance cannot back two effect views.
        let trackEffect: UIGlassEffect
        var fillWidth: NSLayoutConstraint!
        var height: NSLayoutConstraint!

        init() {
            effect = UIGlassEffect(style: .regular)
            fill = UIVisualEffectView(effect: effect)
            trackEffect = UIGlassEffect(style: .regular)
            track = UIVisualEffectView(effect: trackEffect)
        }
    }

    private var pumpLifecycleLine: LifecycleLine?
    private var cgmLifecycleLine: LifecycleLine?

    /// Builds a floating expiry line just below a device pill.
    ///
    /// The HUD's own inline `UIProgressView` is suppressed: buried inside the
    /// element it was effectively invisible. This replaces it with a free
    /// floating capsule, tinted by `DeviceLifecycleProgressState.color` so it
    /// still turns amber/red as the device ages.
    ///
    /// Uses UIKit `UIGlassEffect.tintColor` by explicit request. Note this is
    /// the path `MealEntryPickerOverlay` documents as rendering washed out on
    /// this SDK — the SwiftUI `.glassEffect(.regular.tint(...))` equivalent
    /// tints more accurately, if the colour ever looks wrong here.
    private func installLifecycleLine(under pillView: UIView,
                                      for hud: DeviceStatusHUDView?) -> LifecycleLine {
        hud?.suppressesBuiltInProgressView = true

        let line = LifecycleLine()
        line.track.translatesAutoresizingMaskIntoConstraints = false
        // The groove is glass, not paint — no `backgroundColor`. A flat wash here
        // is what made the unfilled remainder read as grey plastic next to the
        // pills, and (per the process lesson above) an opaque wash over glass is
        // exactly what destroys the reflection.
        line.track.cornerConfiguration = .capsule()
        // Grey, but as glass. Same re-assign rule as the fill below: setting
        // `tintColor` on the effect object does nothing until the effect is
        // assigned back onto the view.
        line.trackEffect.tintColor = Self.lifecycleTrackTint
        line.track.effect = line.trackEffect
        // NOT clipped: a UIGlassEffect renders its specular highlight and edge
        // refraction slightly OUTSIDE its own bounds, and that overspill is what
        // makes a surface read as glass. Clipping a 5pt-tall strip cut all of it
        // off and left only the tint. The fill is capsule-shaped and pinned
        // inside the track, so it stays put without clipping.
        line.track.clipsToBounds = false
        line.track.isHidden = true

        line.fill.translatesAutoresizingMaskIntoConstraints = false
        line.fill.cornerConfiguration = .capsule()

        glassContainerView.contentView.addSubview(line.track)
        // Subviews of a UIVisualEffectView belong in its contentView; adding them
        // to the effect view directly is unsupported and drops them out of the
        // material.
        line.track.contentView.addSubview(line.fill)

        line.height = line.track.heightAnchor.constraint(equalToConstant: 0)
        line.fillWidth = line.fill.widthAnchor.constraint(equalTo: line.track.widthAnchor,
                                                          multiplier: 0.01)

        NSLayoutConstraint.activate([
            // Under its pill, inset a little at each end so the line is slightly
            // shorter than the pill rather than running its full width.
            line.track.leadingAnchor.constraint(equalTo: pillView.leadingAnchor,
                                                constant: Self.lifecycleLineInset),
            line.track.trailingAnchor.constraint(equalTo: pillView.trailingAnchor,
                                                 constant: -Self.lifecycleLineInset),
            line.track.topAnchor.constraint(equalTo: containerView.bottomAnchor,
                                            constant: Self.lifecycleLineTopGap),
            // The bar is at least tall enough to contain this line, which is what
            // makes the scroll inset and the island below reserve room for it.
            //
            // 🐛 NOT EQUALITY. With two lines pinned EQUAL to the same bottom, the
            // moment one had height 6 and the other 0 — at launch, whichever
            // device reported its lifecycle first — the constraints conflicted
            // and UIKit permanently broke a line's `height == 6`. The bar then
            // mis-measured for the rest of the process and the island was laid
            // out on top of the lines. The low-priority hug in
            // `installLifecycleLines` pulls the bar up to the tallest line.
            line.track.bottomAnchor.constraint(lessThanOrEqualTo: glassContainerView.contentView.bottomAnchor,
                                               constant: -Self.verticalInset),
            line.height,

            line.fill.leadingAnchor.constraint(equalTo: line.track.contentView.leadingAnchor),
            line.fill.topAnchor.constraint(equalTo: line.track.contentView.topAnchor),
            line.fill.bottomAnchor.constraint(equalTo: line.track.contentView.bottomAnchor),
            line.fillWidth,
        ])
        return line
    }

    /// Both devices get the same line, built by the same code — the sensor's
    /// expiry is no less worth seeing than the pod's.
    private func installLifecycleLines() {
        // Same resting height as before when no line shows (pills + gap + inset);
        // the required `lessThanOrEqual` per line wins whenever a line is taller.
        let hug = glassContainerView.contentView.bottomAnchor.constraint(
            equalTo: containerView.bottomAnchor,
            constant: Self.lifecycleLineTopGap + Self.verticalInset)
        hug.priority = .defaultLow
        hug.isActive = true

        if let pumpGlassView {
            let line = installLifecycleLine(under: pumpGlassView, for: pumpStatusHUD)
            pumpLifecycleLine = line
            pumpStatusHUD?.lifecycleProgressDidChange = { [weak self] progress in
                self?.update(line: self?.pumpLifecycleLine, with: progress)
            }
            update(line: line, with: pumpStatusHUD?.lifecycleProgress)
        }
        if let cgmGlassView {
            let line = installLifecycleLine(under: cgmGlassView, for: cgmStatusHUD)
            cgmLifecycleLine = line
            cgmStatusHUD?.lifecycleProgressDidChange = { [weak self] progress in
                self?.update(line: self?.cgmLifecycleLine, with: progress)
            }
            update(line: line, with: cgmStatusHUD?.lifecycleProgress)
        }
    }

    /// Called when this bar's overall height changes — i.e. when the pump
    /// lifecycle line appears or disappears. The host has to re-measure the
    /// scroll inset it reserves, or content ends up underneath the line.
    public var onHeightChange: (() -> Void)?

    /// True while either device's expiry line is on screen.
    ///
    /// The island below this bar needs to sit further down when a line is
    /// showing — otherwise it crowds the line, which belongs to the pill above
    /// it, and the two read as one clump.
    public var showsLifecycleLine: Bool {
        [pumpLifecycleLine, cgmLifecycleLine].contains { $0?.track.isHidden == false }
    }

    private func update(line: LifecycleLine?, with progress: DeviceLifecycleProgress?) {
        guard let line else { return }

        let previousHeight = line.height.constant
        defer {
            if line.height.constant != previousHeight { onHeightChange?() }
        }

        guard let progress else {
            line.track.isHidden = true
            line.height.constant = 0
            return
        }

        line.track.isHidden = false
        line.height.constant = Self.lifecycleLineHeight
        // No manual `layer.cornerRadius` here any more: the track is a glass view
        // and carries `cornerConfiguration = .capsule()`, which stays correct as
        // the height changes. Setting the layer radius as well fights that.

        let fraction = CGFloat(progress.percentComplete.clamped(to: 0...1))
        // Re-assigning `effect` is what makes the new tint take: mutating the
        // effect object alone does not re-render the visual effect view.
        //
        // This was in the original pump line, with this same comment, and the
        // refactor that generalised it dropped the re-assign — reading the tint
        // back off `fill.effect` and mutating that does nothing. That is why
        // BOTH lines went colourless, and why layering an opaque wash on top
        // "fixed" it in a way that destroyed the reflection.
        line.effect.tintColor = progress.progressState.color
        line.fill.effect = line.effect
        line.fillWidth.isActive = false
        line.fillWidth = line.fill.widthAnchor.constraint(equalTo: line.track.widthAnchor,
                                                          multiplier: max(0.01, fraction))
        line.fillWidth.isActive = true
    }

    /// Re-parents each arranged HUD view into its own capsule glass element.
    private func wrapArrangedViewsInGlass() {
        for hudView in containerView.arrangedSubviews {
            let index = containerView.arrangedSubviews.firstIndex(of: hudView)!

            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.isInteractive = true
            let glassView = UIVisualEffectView(effect: glassEffect)
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.cornerConfiguration = .capsule()

            containerView.removeArrangedSubview(hudView)
            hudView.removeFromSuperview()

            // The HUD views paint their own opaque background in the nib; clear
            // it so the glass underneath is what shows through.
            hudView.backgroundColor = .clear
            hudView.translatesAutoresizingMaskIntoConstraints = false
            glassView.contentView.addSubview(hudView)

            let insets = Self.glassContentInsets

            // One shared, shorter pill height for every element, with the content
            // centred inside it rather than stretched to the capsule's edges.
            //
            // NB: do NOT also cap the content's own height. The HUD views carry
            // required intrinsic heights, so a `<=` cap is unsatisfiable and
            // breaks — which threw the loop icon clean out of its circle.
            // Centring alone is enough.
            NSLayoutConstraint.activate([
                glassView.heightAnchor.constraint(equalToConstant: Self.pillHeight),
                hudView.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor),
                hudView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
            ])

            if hudView === loopCompletionHUD {
                // An even, thin glass ring all the way around the loop icon: a
                // circle, not a capsule traced around the element's taller-than-
                // wide bounds. The ring thickness is whatever the pill height
                // leaves around the centred icon.
                glassView.widthAnchor.constraint(equalTo: glassView.heightAnchor).isActive = true
                loopGlassView = glassView
            } else {
                // Width still traces the element, so the bar keeps its original
                // horizontal proportions.
                NSLayoutConstraint.activate([
                    hudView.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor,
                                                     constant: insets.leading),
                    hudView.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor,
                                                      constant: -insets.trailing),
                ])
            }

            if hudView === cgmStatusHUD {
                cgmGlassView = glassView
            } else if hudView === pumpStatusHUD {
                pumpGlassView = glassView
            }

            containerView.insertArrangedSubview(glassView, at: index)
        }

        if let cgmGlassView, let loopGlassView, let pumpGlassView {
            NSLayoutConstraint.activate([
                cgmGlassView.widthAnchor.constraint(equalTo: pumpGlassView.widthAnchor),
                loopGlassView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            ])
            devicePillWidthConstraint = cgmGlassView.widthAnchor.constraint(equalToConstant: 0)
            devicePillWidthConstraint?.isActive = true
        }
    }
        
    public func removePumpManagerProvidedView() {
        pumpStatusHUD.removePumpManagerProvidedHUD()
    }
    
    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        pumpStatusHUD.addPumpManagerProvidedHUDView(pumpManagerProvidedHUD)
    }
}
