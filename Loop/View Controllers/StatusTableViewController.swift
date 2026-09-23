
//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import SwiftUI
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopTestingKit
import LoopUI
import SwiftCharts
import os.log
import Combine
import WidgetKit


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}

final class StatusTableViewController: LoopChartsTableViewController {

    private let log = OSLog(category: "StatusTableViewController")

    lazy var carbFormatter: QuantityFormatter = QuantityFormatter(for: .gram())

    var onboardingManager: OnboardingManager!

    var testingScenariosManager: TestingScenariosManager!

    var automaticDosingStatus: AutomaticDosingStatus!
    
    var alertPermissionsChecker: AlertPermissionsChecker!

    var alertMuter: AlertMuter!

    var supportManager: SupportManager!

    lazy private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {

        super.viewDidLoad()

        // Statistics only, and nothing but a file write: this starts the
        // self-updating HTML report if the user has turned it on. Placed here
        // rather than in the launch sequence on purpose — reorganising this
        // fork's startup path is what cost it CGM readings once already (STEP
        // BB), and a report file has no business near that.
        StatsLiveReport.shared.start()

        setupToolbarItems()

        tableView.register(BolusProgressTableViewCell.nib(), forCellReuseIdentifier: BolusProgressTableViewCell.className)
        tableView.register(AlertPermissionsDisabledWarningCell.self, forCellReuseIdentifier: AlertPermissionsDisabledWarningCell.className)
        tableView.register(MuteAlertsWarningCell.self, forCellReuseIdentifier: MuteAlertsWarningCell.className)

        if FeatureFlags.predictedGlucoseChartClampEnabled {
            statusCharts.glucose.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBoundClamped
        } else {
            statusCharts.glucose.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBound
        }

        registerPumpManager()
        registerCGMManager()

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext)
                DispatchQueue.main.async {
                    switch context {
                    case .none, .insulin?:
                        self?.refreshContext.formUnion([.status, .insulin])
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .carbs?:
                        self?.refreshContext.update(with: .carbs)
                    case .glucose?:
                        self?.refreshContext.formUnion([.glucose, .carbs])
                    case .loopFinished?:
                        self?.refreshContext.update(with: .insulin)
                    }

                    self?.hudView?.loopCompletionHUD.loopInProgress = false
                    self?.log.debug("[reloadData] from notification with context %{public}@", String(describing: context))
                    self?.reloadData(animated: true)
                }
                
                WidgetCenter.shared.reloadAllTimelines()
            },
            notificationCenter.addObserver(forName: .LoopRunning, object: deviceManager.loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hudView?.loopCompletionHUD.loopInProgress = true
                }
            },
            notificationCenter.addObserver(forName: .PumpManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerPumpManager()
                    self?.configurePumpManagerHUDViews()
                    self?.updateToolbarItems()
                }
            },
            notificationCenter.addObserver(forName: .CGMManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerCGMManager()
                    self?.configureCGMManagerHUDViews()
                    self?.updateToolbarItems()
                }
            },
            notificationCenter.addObserver(forName: .PumpEventsAdded, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.refreshContext.update(with: .insulin)
                    self?.reloadData(animated: true)
                }
            },
        ]

        automaticDosingStatus.$automaticDosingEnabled
            .receive(on: DispatchQueue.main)
            .sink { self.automaticDosingStatusChanged($0) }
            .store(in: &cancellables)

        alertMuter.$configuration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { _ in
                self.refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
            .store(in: &cancellables)

        if let gestureRecognizer = charts.gestureRecognizer {
            tableView.addGestureRecognizer(gestureRecognizer)
        }

        tableView.estimatedRowHeight = 74

        addScenarioStepGestureRecognizers()

        tableView.backgroundColor = .secondarySystemBackground
    
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext.formUnion(RefreshContext.all)
        }
    }

    private var appearedOnce = false

    // MARK: - Floating status bar (Liquid Glass)

    /// The CGM / loop / pump bar, fixed to the top of the screen while the charts
    /// scroll beneath it. See `installFloatingHeaderIfNeeded` for where it lives.
    private lazy var floatingHUDView: StatusBarHUDView = {
        let hud = StatusBarHUDView(frame: .zero)
        hud.translatesAutoresizingMaskIntoConstraints = false
        return hud
    }()

    /// The action island, hosted next to the status pills rather than as a table
    /// row, so it is pinned to the top with them.
    private lazy var islandHostingController: UIHostingController<ActionIslandView> = {
        let controller = UIHostingController(rootView: ActionIslandView(items: []))
        // 🐛 Without this the hosting view keeps the intrinsic height it measured
        // for the EMPTY island (its two 8pt gaps = 16pt) after `rootView` gains
        // items. The ~60pt island then overflowed a 16pt frame, centred on it,
        // and drew on top of the expiry lines — "the island still has compact
        // problems sometimes". This makes every rootView change re-measure.
        controller.sizingOptions = [.intrinsicContentSize]
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // Must be clear, or it paints an opaque box behind the glass capsule.
        controller.view.backgroundColor = .clear
        controller.view.setContentHuggingPriority(.required, for: .vertical)
        controller.view.isOpaque = false
        // Starts hidden: an empty island still occupies its padding AND the
        // header stack's spacing, which showed up as dead white space above the
        // charts whenever nothing was active.
        //
        // ⚠️ Hidden, NOT transparent. Fading a view that contains
        // `.glassEffect` composites it offscreen, where the glass has no
        // backdrop to sample and renders dark until the fade finishes — that is
        // the dark flash the island used to show as it appeared. Alpha stays at
        // 1 for the view's whole life; the reveal is the stack's height change.
        controller.view.isHidden = true
        controller.view.alpha = 1
        return controller
    }()

    /// Clear space above the pills, as tall as the top safe area.
    ///
    /// The pills place themselves below the status bar using their own safe area.
    /// Inside the table (see `installFloatingHeaderIfNeeded`) that safe area is
    /// zero, because the table already consumes it for its content inset, so
    /// without this the pills sat under the clock and battery.
    private lazy var floatingHeaderTopSpacer: UIView = {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.backgroundColor = .clear
        return spacer
    }()

    private lazy var floatingHeaderTopSpacerHeight: NSLayoutConstraint =
        floatingHeaderTopSpacer.heightAnchor.constraint(equalToConstant: 0)

    /// Status pills + island as one fixed top header.
    private lazy var floatingHeaderView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [floatingHeaderTopSpacer, floatingHUDView, islandHostingController.view])
        stack.axis = .vertical
        // ZERO, deliberately. The gap above the island is drawn INSIDE the
        // island's own view (see `ActionIslandView.topGap`): as stack spacing it
        // sat outside the hosting view's bounds, and UIKit refuses touches
        // outside those bounds — which silently clipped the top of every
        // element's hit area.
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Transparent so the charts pass UNDER the glass instead of being cut off
        // at an opaque edge. The white is the table showing through, so it still
        // matches the charts when nothing is scrolled behind it.
        stack.backgroundColor = .clear
        return stack
    }()

    private func installFloatingHeaderIfNeeded() {
        guard floatingHeaderView.superview == nil else { return }

        // 🐛 It used to live in the NAVIGATION CONTROLLER's view, so it did not
        // travel with push/pop transitions and had to be hidden and re-shown
        // around them. Mid back-swipe it was drawn over the screen being left
        // (its nav bar, back button and title), and every fix was a timing rule.
        // Now it is part of this screen: pinned to the table's `frameLayoutGuide`
        // it stays fixed while the charts scroll, and it slides, follows the
        // finger and is covered by the incoming screen exactly like the bottom
        // bar — with no visibility bookkeeping at all.
        //
        // The island's hosting controller is still not added as a child; the lazy
        // property keeps it alive, which is all this static view needs.
        let host = tableView!
        host.addSubview(floatingHeaderView)
        // Draw above the cells; `keepFloatingHeaderInFront` handles touches.
        floatingHeaderView.layer.zPosition = 1

        NSLayoutConstraint.activate([
            floatingHeaderView.leadingAnchor.constraint(equalTo: host.frameLayoutGuide.leadingAnchor),
            floatingHeaderView.trailingAnchor.constraint(equalTo: host.frameLayoutGuide.trailingAnchor),
            // Pinned to the very top, NOT the safe area, so the header's white
            // background covers the status-bar strip the way a navigation bar
            // does. The pills position themselves against the safe area inside.
            floatingHeaderView.topAnchor.constraint(equalTo: host.frameLayoutGuide.topAnchor),
            floatingHeaderTopSpacerHeight,
        ])
        updateFloatingHeaderTopSpacer()

        // The bar grows and shrinks with the pump lifecycle line, and that
        // changes how much scroll inset has to be reserved beneath it.
        floatingHUDView.onHeightChange = { [weak self] in
            // Order matters: set the gap first, then measure — the inset is
            // derived from the header's height, which the gap changes.
            self?.updateIslandSpacing()
            // A discrete one-off change (an expiry line appeared or vanished),
            // so the content should hold its place rather than jump. This is the
            // ONLY caller allowed to move the scroll position from here; the
            // island's own animation owns it during a show/hide.
            self?.updateFloatingHeaderInset(adjustingOffset: true)
        }
        updateIslandSpacing()

        // Wires gesture recognizers, state colors and the initial values.
        hudView = floatingHUDView
    }

    /// Gap between the status pills and the island below them.
    ///
    /// 🐛 There used to be two of these — 14pt normally, 22pt when a pump or CGM
    /// expiry line was showing — on the theory that the island needed extra air
    /// to clear the line. It did not: the line lives INSIDE the pills' own
    /// height, so its 4pt gap and 6pt bar already push the island down. The
    /// second constant added 8pt on top of that, so the same island sat 18pt
    /// lower whenever an expiry line happened to be visible, and the gap
    /// appeared to change at random as pods aged in and out of their warning
    /// window. One constant, always — the line pays for its own space.
    private static let islandGap: CGFloat = 14

    /// The gap currently used BOTH above the island (the stack's spacing) and
    /// below it (the SwiftUI view's own bottom padding). One value, so the
    /// island always sits with equal air on each side.
    private var currentIslandGap: CGFloat { Self.islandGap }

    /// The gap the island is currently drawing above and below itself.
    private var renderedIslandGap: CGFloat = StatusTableViewController.islandGap

    private func updateIslandSpacing() {
        let gap = currentIslandGap
        guard renderedIslandGap != gap else { return }
        renderedIslandGap = gap
        // The island owns BOTH gaps, so it has to be told the new value.
        rebuildIslandRootView()
    }

    /// Push the current items AND the current gaps into the hosted SwiftUI view.
    private func rebuildIslandRootView() {
        islandHostingController.rootView = ActionIslandView(items: renderedIslandItems,
                                                            topGap: currentIslandGap,
                                                            bottomGap: currentIslandGap) { [weak self] item in
            self?.handleIslandTap(item)
        }
        islandHostingController.view.backgroundColor = .clear
    }

    /// Reserve the header's height so the charts start below it.
    ///
    /// Deliberately does NOT force layout. The header lives in the navigation
    /// controller's view, so `layoutIfNeeded()` here walks up and re-lays out
    /// that whole tree — including this table — and calling it from
    /// `viewDidLayoutSubviews` (i.e. on every layout pass) made returning from a
    /// settings screen take seconds. Forced layout happens once, in
    /// `updateIslandItems`, and only when the island actually appears or
    /// disappears.
    /// - Parameter adjustingOffset: opt-IN, and deliberately defaulted to FALSE.
    ///
    ///   `viewDidLayoutSubviews` calls this on every layout pass — including on
    ///   every intermediate frame of the island's spring animation. With
    ///   compensation on by default it nudged `contentOffset` on each of those
    ///   frames, and the nudges COMPOUNDED: cancelling a bolus scrolled the
    ///   Glucose header clean up behind the status pills.
    ///
    ///   Only a caller that knows a discrete, one-off height change just
    ///   happened may ask for compensation. Anything driven by layout must not.
    @discardableResult
    private func updateFloatingHeaderInset(adjustingOffset: Bool = false) -> CGFloat {
        // The header spans from y=0, so its height already includes the status
        // bar. `contentInset` is ADDED to the scroll view's safe-area inset, so
        // only the part below the safe area must be reserved here.
        // Measure AFTER layout. `frame.height` read before the header has laid
        // out returns its previous height, which is why the spacing appeared to
        // apply only some of the time — whichever pass happened to run first won.
        floatingHeaderView.layoutIfNeeded()
        let headerHeight = floatingHeaderView.isHidden ? 0 : floatingHeaderView.frame.height
        let inset = max(0, headerHeight - tableView.safeAreaInsets.top)
        let previous = tableView.contentInset.top
        guard abs(previous - inset) > 0.5 else { return previous }

        // Changing `contentInset.top` shoves the content down by the same amount,
        // which is the jump seen when the island appears or disappears. Move the
        // offset by the opposite delta so the content stays visually still —
        // unless the user was already at the top, where it should stay pinned.
        let wasAtTop = tableView.contentOffset.y <= -previous + 1
        tableView.contentInset.top = inset
        tableView.verticalScrollIndicatorInsets.top = inset
        guard adjustingOffset else { return inset }
        if wasAtTop {
            tableView.contentOffset.y = -inset
        } else {
            tableView.contentOffset.y -= (inset - previous)
        }
        return inset
    }

    /// The items currently rendered by the island, so an unchanged reload is a
    /// no-op instead of rebuilding the SwiftUI view. `reloadData` runs often.
    private var renderedIslandItems: [ActionIslandItem] = []

    /// How long the island takes to expand in / collapse out.
    private static let islandRevealDuration: TimeInterval = 0.34

    /// How far from the top still counts as "at the top" when deciding whether
    /// the content should follow the header as the island appears. Roughly one
    /// island's height, so a small scroll nudge doesn't change the behaviour.
    private static let topFollowThreshold: CGFloat = 80

    /// Push the current island items into the hosted SwiftUI view.
    ///
    /// - Parameter animated: `false` when arriving on the screen, so the island
    ///   is simply already in its correct state rather than animating on entry.
    private func updateIslandItems(animated: Bool = true) {
        let items = shouldShowStatus ? determineIslandItems() : []
        let shouldHide = items.isEmpty

        // Evaluated BEFORE the unchanged-items short circuit. Both start empty,
        // so an early return here left the empty hosting view visible, taking up
        // the header stack's spacing and its own padding for nothing.
        let visibilityChanged = islandHostingController.view.isHidden != shouldHide

        guard items != renderedIslandItems || visibilityChanged else { return }
        renderedIslandItems = items

        // Content first, so the pill expands with its final contents already
        // laid out instead of growing and then filling in.
        rebuildIslandRootView()

        // Only the appear/disappear transition changes the header's height, so
        // that is the only case that needs a re-measure.
        guard visibilityChanged else { return }

        // Captured before the inset changes. If the content was at — or near —
        // the top, it follows the header down as the island expands; otherwise
        // the header grows over content that stays put and the top elements end
        // up overlapping the charts. Deliberately a range rather than an exact
        // match: being nudged a little off the top is still visually "at the
        // top", and it should behave the same.
        let restingTop = -tableView.adjustedContentInset.top + Self.restingScrollOffset
        let wasNearTop = tableView.contentOffset.y <= restingTop + Self.topFollowThreshold

        let applyVisibility = { [weak self] in
            guard let self else { return }
            // A hidden arranged subview is excluded from the stack's layout —
            // including its spacing — so animating this collapses the gap too.
            self.islandHostingController.view.isHidden = shouldHide
            self.floatingHeaderView.layoutIfNeeded()
            // Inside the animation block so the charts slide with the header
            // rather than snapping to the new inset. Offset is handled just
            // below, by `wasNearTop`, so this must not touch it.
            let newInset = self.updateFloatingHeaderInset(adjustingOffset: false)

            // Assigning `contentOffset` inside the block scrolls with the same
            // spring, so it reads as one motion rather than a separate jump.
            if wasNearTop {
                // Computed from the inset just applied, NOT from
                // `adjustedContentInset` — that still reports the old value at
                // this point in the pass, so the scroll overshot on cancel.
                self.tableView.contentOffset = CGPoint(
                    x: 0,
                    y: -(self.tableView.safeAreaInsets.top + newInset) + Self.restingScrollOffset
                )
            }
        }

        guard animated else {
            applyVisibility()
            if wasNearTop { scrollToTop() }
            return
        }

        UIView.animate(withDuration: Self.islandRevealDuration,
                       delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0,
                       options: [.beginFromCurrentState],
                       animations: applyVisibility) { [weak self] _ in
            // Land EXACTLY at rest, not merely near it. Everything inside the
            // animation works from an inset predicted mid-flight; this runs once
            // the animation is over, when `adjustedContentInset` is finally
            // truthful, and snaps the content to the real top. Without it the
            // island's disappearance left the content a little short of the top
            // rather than settled against it.
            guard wasNearTop else { return }
            self?.scrollToTop()
        }
    }

    /// Set when the screen is about to appear, so the charts are returned to the
    /// top rather than wherever they were left scrolled.
    private var needsScrollToTop = false

    /// How far past the top of the scroll range to rest.
    ///
    /// Zero: the content rests fully clear of the floating header, with nothing
    /// tucked underneath it. A positive value scrolls the content up so the top
    /// of the glucose chart slides under the status pills, which is explicitly
    /// not wanted — the top elements must not overlap anything at rest.
    private static let restingScrollOffset: CGFloat = 0

    /// Rests the content just past the top of its scroll range.
    /// `adjustedContentInset` already accounts for the floating header.
    private func scrollToTop() {
        let top = -tableView.adjustedContentInset.top + Self.restingScrollOffset
        guard abs(tableView.contentOffset.y - top) > 0.5 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keepFloatingHeaderInFront()
        healFloatingHeaderVisibility()
        updateFloatingHeaderTopSpacer()
        updateFloatingHeaderInset()

        // Deferred to here, not `viewWillAppear`: the header's height — and so
        // the content inset the top position is measured from — is not settled
        // until layout has run.
        if needsScrollToTop {
            needsScrollToTop = false
            scrollToTop()
        }
    }

    /// Keep the space above the pills equal to the top safe area (status bar /
    /// Dynamic Island). Only touches the constraint when the value really changed,
    /// so calling it on every layout pass cannot start a layout loop.
    private func updateFloatingHeaderTopSpacer() {
        let top = tableView.safeAreaInsets.top
        guard abs(floatingHeaderTopSpacerHeight.constant - top) > 0.5 else { return }
        floatingHeaderTopSpacerHeight.constant = top
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateFloatingHeaderTopSpacer()
    }

    /// The table adds cell views as it scrolls, and a view added later sits above
    /// the header for hit-testing, which would steal taps on the pills and island.
    /// `zPosition` only affects drawing, so reorder too. Runs every layout pass —
    /// including every scroll frame — and only moves anything when it must.
    private func keepFloatingHeaderInFront() {
        guard floatingHeaderView.superview === tableView,
              tableView.subviews.last !== floatingHeaderView else { return }
        tableView.bringSubviewToFront(floatingHeaderView)
    }

    /// Put the top header back if it is hidden. Deliberately **show-only**: it can
    /// never take the header away, so running it on every layout pass cannot
    /// introduce a new way to lose it. Nothing hides the header any more (it
    /// travels with this screen), so this only guards against a cause not found.
    ///
    /// This is the backstop for the "HUD disappeared until I restarted the app"
    /// class of bug. The individual causes are fixed at their source (see
    /// `landscapeMode`); this makes sure that any cause we have NOT found still
    /// heals itself on the next layout pass instead of persisting for the life of
    /// the process.
    private func healFloatingHeaderVisibility() {
        guard floatingHeaderView.superview != nil else { return }

        if shouldShowHUD, floatingHUDView.isHidden {
            floatingHUDView.isHidden = false
        }

        if floatingHeaderView.isHidden {
            floatingHeaderView.isHidden = false
            floatingHeaderView.alpha = 1
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.setToolbarHidden(false, animated: animated)

        installFloatingHeaderIfNeeded()
        floatingHUDView.isHidden = !shouldShowHUD
        // Not animated: arriving on the screen should find the island already in
        // its correct state, not animating into it.
        updateIslandItems(animated: false)
        refreshDeviceStatusHUD()
        needsScrollToTop = true

        // Same white as the charts, so the strip behind the bottom menu matches.
        navigationController?.view.backgroundColor = .systemBackground
        tableView.backgroundColor = .systemBackground

        updateToolbarItems()

        alertPermissionsChecker.checkNow()

        updateBolusProgress()

        onboardingManager.$isComplete
            .merge(with: onboardingManager.$isSuspended)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshContext.update(with: .status)
                self?.reloadData(animated: true)
                self?.updateToolbarItems()
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {

        super.viewDidAppear(animated)

        if !appearedOnce {
            appearedOnce = true
            DispatchQueue.main.async {
                self.log.debug("[reloadData] after HealthKit authorization")
                self.reloadData()
            }
        }

        onscreen = true

        deviceManager.analyticsServicesManager.didDisplayStatusScreen()

        deviceManager.checkDeliveryUncertaintyState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        onscreen = false

        if presentedViewController == nil {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            // The header is NOT hidden here: it belongs to this screen and leaves
            // with it, covered by the incoming screen like the bottom bar.
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        maybeOpenDebugMenu()

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    // This reflects whether the application is active 
    override var active: Bool {
        didSet {
            hudView?.loopCompletionHUD.assertTimer(active)
            updateHUDActive()
        }
    }

    // This is similar to the visible property, but is set later, on viewDidAppear, to be
    // suitable for animations that should be seen in their entirety.
    var onscreen: Bool = false {
        didSet {
            updateHUDActive()
        }
    }

    private var bolusState: PumpManagerStatus.BolusState = .noBolus {
        didSet {
            if oldValue != bolusState {
                switch bolusState {
                case .inProgress:
                    guard case .inProgress = oldValue else {
                        // Bolus starting
                        bolusProgressReporter = deviceManager.pumpManager?.createBolusProgressReporter(reportingOn: DispatchQueue.main)
                        // Refresh the island now in case the app is currently in the
                        // background as otherwise these values won't get initialized and can contain stale data from some earlier bolus.
                        updateIslandItems()
                        break
                    }
                default:
                    break
                }
                refreshContext.update(with: .status)
                reloadData(animated: true)
            }
        }
    }

    private var bolusProgressReporter: DoseProgressReporter?

    private func updateBolusProgress() {
        updateIslandItems()
    }

    private func updateHUDActive() {
        deviceManager.pumpManagerHUDProvider?.visible = active && onscreen
    }

    // Indices into `toolbarItems`. The five controls are ADJACENT with no spacer
    // items between them: on iOS 26 a toolbar draws ONE shared Liquid Glass
    // background behind a run of adjacent items, and any space item — including
    // `fixedSpaceItem` — deliberately breaks that run. The old layout put a
    // flexible space between every control, which is why each icon got its own
    // separate glass circle instead of Apple's single grouped glass menu. The
    // only flexible spaces are the outer two, which centre the group.
    private enum ToolbarIndex {
        static let carbs = 1
        static let statistics = 2
        static let bolus = 3
        /// The presets button. Pre-Meal used to be its own toolbar item; it now
        /// lives in this button's menu alongside the other presets, which is
        /// where it belongs — they are mutually exclusive overrides.
        static let presets = 4
        static let settings = 5
    }

    /// How much bigger the bottom-bar icons are drawn than their natural asset
    /// size.
    ///
    /// This is HALF of the bottom bar's size. The other half is
    /// `PassthroughToolbar.extraHeight`, which grows the bar (and so the glass
    /// capsule) itself. Tune the two together — icons alone just makes bigger
    /// glyphs inside a bar that stayed the same height.
    ///
    /// Scaling the image, rather than setting an appearance or using custom-view
    /// items, is what keeps the shared Liquid Glass intact (see DESIGN_SYSTEM.md).
    static let toolbarIconScale: CGFloat = 1.08

    // Scaled ONCE, at first use. `updateToolbarItems()` runs on every loop cycle
    // and `createPresetsButtonItem` rebuilds
    // their item each time — so scaling inline meant re-rendering images through
    // UIGraphicsImageRenderer on the main thread, over and over, forever.
    private static let scaledBolusImage = UIImage(named: "bolus")?.scaled(by: toolbarIconScale)
    private static let scaledSettingsImage = UIImage(named: "settings")?.scaled(by: toolbarIconScale)
    private static let scaledCarbsImage = UIImage(named: "carbs")?
        .scaled(by: toolbarIconScale)
        .withRenderingMode(.alwaysTemplate)
    private static let scaledPreMealImages: [Bool: UIImage] = [
        true: UIImage.preMealImage(selected: true)?.scaled(by: toolbarIconScale),
        false: UIImage.preMealImage(selected: false)?.scaled(by: toolbarIconScale)
    ].compactMapValues { $0 }
    private static let scaledWorkoutImages: [Bool: UIImage] = [
        true: UIImage.workoutImage(selected: true)?.scaled(by: toolbarIconScale),
        false: UIImage.workoutImage(selected: false)?.scaled(by: toolbarIconScale)
    ].compactMapValues { $0 }

    private func setupToolbarItems() {
        let carbs = UIBarButtonItem(customView: mealButton)
        let bolus = UIBarButtonItem(image: Self.scaledBolusImage, style: .plain, target: self, action: #selector(presentBolusScreen))
        let settings = UIBarButtonItem(image: Self.scaledSettingsImage, style: .plain, target: self, action: #selector(onSettingsTapped))

        let statistics = createStatisticsButtonItem()
        let presets = createPresetsButtonItem(selected: false, isEnabled: true)
        toolbarItems = [
            .flexibleSpace(),
            carbs,
            statistics,
            bolus,
            presets,
            settings,
            .flexibleSpace()
        ]
    }

    private func updateToolbarItems() {
        let isPumpOnboarded = onboardingManager.isComplete || deviceManager.pumpManager?.isOnboarded == true

        toolbarItems![ToolbarIndex.carbs].accessibilityLabel = NSLocalizedString("Add Meal", comment: "The label of the carb entry button")
        toolbarItems![ToolbarIndex.carbs].isEnabled = isPumpOnboarded
        toolbarItems![ToolbarIndex.carbs].tintColor = UIColor.carbTintColor
        mealButton.isEnabled = isPumpOnboarded
        toolbarItems![ToolbarIndex.bolus].accessibilityLabel = NSLocalizedString("Bolus", comment: "The label of the bolus entry button")
        toolbarItems![ToolbarIndex.bolus].isEnabled = isPumpOnboarded
        toolbarItems![ToolbarIndex.bolus].tintColor = UIColor.insulinTintColor
        toolbarItems![ToolbarIndex.settings].accessibilityLabel = NSLocalizedString("Settings", comment: "The label of the settings button")
        // Solid gray: .secondaryLabel is see-through and faded into iOS 27's dark toolbar.
        toolbarItems![ToolbarIndex.settings].tintColor = UIColor.systemGray

        toolbarItems![ToolbarIndex.statistics].isEnabled = true
        // Rebuilt rather than mutated so the menu picks up the current pre-meal
        // and preset state (the menu shows which one is active).
        toolbarItems![ToolbarIndex.presets] = createPresetsButtonItem(
            selected: (workoutMode == true && workoutModeAllowed) || (preMealMode == true && preMealModeAllowed),
            isEnabled: workoutModeAllowed || preMealModeAllowed)
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? = nil {
        didSet {
            if oldValue != basalDeliveryState {
                log.debug("New basalDeliveryState: %@", String(describing: basalDeliveryState))
                refreshContext.update(with: .status)
                reloadData(animated: true)
            }
        }
    }

    // Toggles the display mode based on the screen aspect ratio.
    //
    // 🐛 This used to be stored, written ONLY from `viewWillTransition` by way of
    // `refreshContext.newSize`. That made it a latch: anything that set it true
    // and was not followed by another size-carrying reload left the whole top HUD
    // hidden until the app was killed and relaunched — which is exactly the
    // "pills vanished, had to restart" report. Derived from the current geometry
    // instead, so every layout pass answers the question afresh and a wrong
    // answer cannot outlive the condition that caused it.
    private var landscapeMode: Bool {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else {
            // No geometry yet (before the first layout). Portrait is the safe
            // default: it SHOWS the HUD, so a bad guess here cannot hide it.
            return false
        }
        return size.width > size.height
    }

    private var lastLoopError: Error?

    private var reloading = false

    private var refreshContext = RefreshContext.all

    private var shouldShowHUD: Bool {
        return !landscapeMode
    }

    private var shouldShowStatus: Bool {
        return !landscapeMode && statusRowMode.hasRow
    }

    override func glucoseUnitDidChange() {
        log.debug("[reloadData] for HealthKit unit preference change")
        refreshContext = RefreshContext.all
    }
    
    private func registerCGMManager() {
        deviceManager.cgmManager?.removeStatusObserver(self)
        deviceManager.cgmManager?.addStatusObserver(self, queue: .main)
    }

    private func registerPumpManager() {
        basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState
        bolusState = deviceManager.pumpManager?.status.bolusState ?? .noBolus
        deviceManager.pumpManager?.removeStatusObserver(self)
        deviceManager.pumpManager?.addStatusObserver(self, queue: .main)
    }
    
    private lazy var statusCharts = StatusChartsManager(colors: .primary, settings: .default, traitCollection: traitCollection)

    override func createChartsManager() -> ChartsManager {
        return statusCharts
    }

    private func updateChartDateRange() {
        // How far back should we show data? Use the screen size as a guide.
        let availableWidth = (refreshContext.newSize ?? tableView.bounds.size).width - charts.fixedHorizontalMargin

        let totalHours = floor(Double(availableWidth / LoopConstants.minimumChartWidthPerHour))
        let futureHours = ceil(deviceManager.doseStore.longestEffectDuration.hours)
        let historyHours = max(LoopConstants.statusChartMinimumHistoryDisplay.hours, totalHours - futureHours)

        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: historyHours))
        let chartStartDate = Calendar.current.nextDate(after: date, matching: DateComponents(minute: 0), matchingPolicy: .strict, direction: .backward) ?? date
        if charts.startDate != chartStartDate {
            refreshContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.maxEndDate = chartStartDate.addingTimeInterval(.hours(totalHours))
        charts.updateEndDate(charts.maxEndDate)
    }

    override func reloadData(animated: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard view.window != nil else {
            return
        }

        // This should be kept up to date immediately
        hudView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

        guard !reloading && !deviceManager.authorizationRequired else {
            return
        }

        updateChartDateRange()

        if case .bolusing = statusRowMode, bolusProgressReporter?.progress.isComplete == true {
            refreshContext.update(with: .status)
        }

        if visible && active {
            bolusProgressReporter?.addObserver(self)
        } else {
            bolusProgressReporter?.removeObserver(self)
        }

        guard active && visible && !refreshContext.isEmpty else {
            updateBannerRow(animated: animated)
            redrawCharts()
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var glucoseSamples: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var doseEntries: [DoseEntry]?
        var totalDelivery: Double?
        var cobValues: [CarbValue]?
        var carbsOnBoard: HKQuantity?
        let startDate = charts.startDate
        let basalDeliveryState = self.basalDeliveryState
        let automaticDosingEnabled = automaticDosingStatus.automaticDosingEnabled

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucoseIncludingPendingInsulin ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let lastLoopError = state.error

            // Net basal rate HUD
            let netBasal: NetBasal?
            if let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory {
                netBasal = basalDeliveryState?.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            } else {
                netBasal = nil
            }
            self.log.debug("Update net basal to %{public}@", String(describing: netBasal))

            DispatchQueue.main.async {
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.pumpStatusHUD.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)
                }
            }

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                self.deviceManager.carbStore.getCarbsOnBoardValues(start: startDate, end: nil, effectVelocities: state.insulinCounteractionEffects) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("CarbStore failed to get carbs on board values: %{public}@", String(describing: error))
                        retryContext.update(with: .carbs)
                        cobValues = []
                    case .success(let values):
                        cobValues = values
                    }
                    reloadGroup.leave()
                }
            }
            // always check for cob
            carbsOnBoard = state.carbsOnBoard?.quantity

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            deviceManager.glucoseStore.getGlucoseSamples(start: startDate, end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting glucose samples: %{public}@", String(describing: error))
                    glucoseSamples = nil
                case .success(let samples):
                    glucoseSamples = samples
                }
                reloadGroup.leave()
            }
        }

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.doseStore.getInsulinOnBoardValues(start: startDate, end: nil, basalDosingEnd: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get insulin on board values: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                    iobValues = []
                case .success(let values):
                    iobValues = values
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.doseStore.getNormalizedDoseEntries(start: startDate, end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get normalized dose entries: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                    doseEntries = []
                case .success(let doses):
                    doseEntries = doses
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.doseStore.getTotalUnitsDelivered(since: Calendar.current.startOfDay(for: Date())) { (result) in
                switch result {
                case .failure:
                    retryContext.update(with: .insulin)
                    totalDelivery = nil
                case .success(let total):
                    totalDelivery = total.value
                }

                reloadGroup.leave()
            }
        }

        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)

        if deviceManager.loopManager.settings.preMealTargetRange == nil {
            preMealMode = nil
        } else {
            preMealMode = deviceManager.loopManager.settings.preMealTargetEnabled()
        }

        if !FeatureFlags.sensitivityOverridesEnabled, deviceManager.loopManager.settings.legacyWorkoutTargetRange == nil {
            workoutMode = nil
        } else {
            workoutMode = deviceManager.loopManager.settings.nonPreMealOverrideEnabled()
        }

        reloadGroup.notify(queue: .main) {
            /// Update the chart data

            // Glucose
            if let glucoseSamples = glucoseSamples {
                self.statusCharts.setGlucoseValues(glucoseSamples)
            }
            if (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled), let predictedGlucoseValues = predictedGlucoseValues {
                self.statusCharts.setPredictedGlucoseValues(predictedGlucoseValues)
            } else {
                self.statusCharts.setPredictedGlucoseValues([])
            }
            if !FeatureFlags.predictedGlucoseChartClampEnabled,
                let lastPoint = self.statusCharts.glucose.predictedGlucosePoints.last?.y
            {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                // if the predicted glucose values are clamped, the eventually glucose description should not be displayed, since it may not align with what is being charted.
                self.eventualGlucoseDescription = nil
            }
            if currentContext.contains(.targets) {
                self.statusCharts.targetGlucoseSchedule = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule
                self.statusCharts.preMealOverride = self.deviceManager.loopManager.settings.preMealOverride
                self.statusCharts.scheduleOverride = self.deviceManager.loopManager.settings.scheduleOverride
            }
            if self.statusCharts.scheduleOverride?.hasFinished() == true {
                self.statusCharts.scheduleOverride = nil
            }

            let charts = self.statusCharts

            // Active Insulin
            if let iobValues = iobValues {
                charts.setIOBValues(iobValues)
            }

            // Show the larger of the value either before or after the current date
            if let maxValue = charts.iob.iobPoints.allElementsAdjacent(to: Date()).max(by: {
                return $0.y.scalar < $1.y.scalar
            }) {
                self.currentIOBDescription = String(describing: maxValue.y)
            } else {
                self.currentIOBDescription = nil
            }

            // Insulin Delivery
            if let doseEntries = doseEntries {
                charts.setDoseEntries(doseEntries)
            }
            if let totalDelivery = totalDelivery {
                self.totalDelivery = totalDelivery
            }

            // Active Carbohydrates
            if let cobValues = cobValues {
                charts.setCOBValues(cobValues)
            }
            if let index = charts.cob.cobPoints.closestIndex(priorTo: Date()) {
                self.currentCOBDescription = String(describing: charts.cob.cobPoints[index].y)
            } else if let carbsOnBoard = carbsOnBoard {
                self.currentCOBDescription = self.carbFormatter.string(from: carbsOnBoard)
            } else {
                self.currentCOBDescription = nil
            }

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // CGM Status
                if let glucose = self.deviceManager.glucoseStore.latestGlucose {
                    let unit = self.statusCharts.glucose.glucoseUnit
                    hudView.cgmStatusHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: unit),
                                                            at: glucose.startDate,
                                                            unit: unit,
                                                            staleGlucoseAge: LoopCoreConstants.inputDataRecencyInterval,
                                                            glucoseDisplay: self.deviceManager.glucoseDisplay(for: glucose),
                                                            wasUserEntered: glucose.wasUserEntered,
                                                            isDisplayOnly: glucose.isDisplayOnly)
                }
                hudView.cgmStatusHUD.presentStatusHighlight(self.deviceManager.cgmStatusHighlight)
                hudView.cgmStatusHUD.presentStatusBadge(self.deviceManager.cgmStatusBadge)
                hudView.cgmStatusHUD.lifecycleProgress = self.deviceManager.cgmLifecycleProgress

                // Pump Status
                hudView.pumpStatusHUD.presentStatusHighlight(self.deviceManager.pumpStatusHighlight)
                hudView.pumpStatusHUD.presentStatusBadge(self.deviceManager.pumpStatusBadge)
                hudView.pumpStatusHUD.lifecycleProgress = self.deviceManager.pumpLifecycleProgress
            }

            // Show/hide the table view rows
            let statusRowMode = self.determineStatusRowMode()

            self.updateBannerAndHUDandStatusRows(statusRowMode: statusRowMode, newSize: currentContext.newSize, animated: animated)

            self.redrawCharts()

            self.tableView.endUpdates()

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.log.debug("[reloadData] due to context change during previous reload")
                self.reloadData()
            }
        }
    }

    private enum Section: Int, CaseIterable {
        case alertWarning
        case charts
    }

    // MARK: - Chart Section Data

    private enum ChartRow: Int, CaseIterable {
        case glucose
        case iob
        case dose
        case cob
    }

    // MARK: Glucose

    private var eventualGlucoseDescription: String?

    // MARK: IOB

    private var currentIOBDescription: String?

    // MARK: Dose

    private var totalDelivery: Double?

    // MARK: COB

    private var currentCOBDescription: String?

    // MARK: - Loop Status Section Data

    private enum StatusRow: Int, CaseIterable {
        case status = 0
    }

    private enum StatusRowMode {
        case hidden
        case scheduleOverrideEnabled(TemporaryScheduleOverride)
        case enactingBolus
        case bolusing(dose: DoseEntry)
        case cancelingBolus
        case pumpSuspended(resuming: Bool)
        case onboardingSuspended
        case recommendManualGlucoseEntry

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden

    private func determineStatusRowMode() -> StatusRowMode {
        let statusRowMode: StatusRowMode

        if case .initiating = bolusState {
            statusRowMode = .enactingBolus
        } else if case .canceling = bolusState {
            statusRowMode = .cancelingBolus
        } else if case .suspended = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: false)
        } else if case .resuming = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: true)
        } else if case .inProgress(let dose) = bolusState, dose.endDate.timeIntervalSinceNow > 0 {
            statusRowMode = .bolusing(dose: dose)
        } else if !onboardingManager.isComplete, deviceManager.pumpManager?.isOnboarded == true {
            statusRowMode = .onboardingSuspended
        } else if onboardingManager.isComplete, deviceManager.isGlucoseValueStale {
            statusRowMode = .recommendManualGlucoseEntry
        } else if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride,
            !scheduleOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(scheduleOverride)
        } else if let premealOverride = deviceManager.loopManager.settings.preMealOverride,
            !premealOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(premealOverride)
        } else {
            statusRowMode = .hidden
        }

        return statusRowMode
    }

    // MARK: - Action Island

    /// The bolus TOTAL, which does not change mid-delivery — so it keeps the
    /// compact form ("13 U", not "13.00 U").
    private lazy var islandInsulinFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// The DELIVERED amount, which ticks upward continuously. Always two
    /// fraction digits: with a 0...2 range it alternated between "2.4" and
    /// "2.35" as delivery progressed, and since the island pill hugs its
    /// content, that one character resized the pill and shunted the bubbles
    /// beside it sideways on every update.
    private lazy var islandDeliveredFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// Formats the delivered amount at a width that stays constant for the whole
    /// bolus, by reserving room for as many integer digits as the total needs.
    /// Without this the string still widens as delivery crosses 9.99 → 10.00.
    /// U+2007 FIGURE SPACE is exactly one digit wide, so the padding is invisible.
    private func islandDeliveredString(delivered: Double, total: Double) -> String? {
        guard let deliveredString = islandDeliveredFormatter.string(from: NSNumber(value: delivered)) else {
            return nil
        }
        let totalIntegerDigits = max(1, Int(floor(log10(max(abs(total), 1)))) + 1)
        let deliveredIntegerDigits = max(1, deliveredString.prefix(while: \.isNumber).count)
        let padding = max(0, totalIntegerDigits - deliveredIntegerDigits)
        return String(repeating: "\u{2007}", count: padding) + deliveredString
    }

    /// The complete set of active items to render in the status island, primary first.
    /// The primary mirrors the single `statusRowMode` (so visibility, diffing and taps are
    /// unchanged); every other co-active state (override, stale glucose) is surfaced as a
    /// secondary bubble, giving the Dynamic-Island-style split.
    /// Display priority (largest first): bolus, override, no-recent-glucose.
    private func determineIslandItems() -> [ActionIslandItem] {
        guard let primary = islandItem(for: statusRowMode) else { return [] }
        var items = [primary]
        if primary.kind != .override && primary.kind != .preMeal,
           let override = activeOverrideIslandItem(), override.id != primary.id {
            items.append(override)
        }
        if primary.id != "glucose", onboardingManager.isComplete, deviceManager.isGlucoseValueStale,
           let glucose = islandItem(for: .recommendManualGlucoseEntry) {
            items.append(glucose)
        }
        return items
    }

    private func islandItem(for mode: StatusRowMode) -> ActionIslandItem? {
        let insulinTint = Color(UIColor.insulinTintColor)
        switch mode {
        case .hidden:
            return nil
        case .enactingBolus:
            return ActionIslandItem(id: "bolus", kind: .bolus, symbolName: "drop.fill",
                                    title: NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent"),
                                    subtitle: nil, progress: nil, tint: insulinTint)
        case .cancelingBolus:
            return ActionIslandItem(id: "bolus", kind: .bolus, symbolName: "drop.fill",
                                    title: NSLocalizedString("Canceling Bolus", comment: "The title of the cell indicating a bolus is being canceled"),
                                    subtitle: nil, progress: nil, tint: insulinTint)
        case .bolusing(let dose):
            let delivered = bolusProgressReporter?.progress.deliveredUnits
            let total = dose.programmedUnits
            let progress: Double? = (total > 0 && delivered != nil) ? min(1, delivered! / total) : nil
            var subtitle: String?
            if let delivered = delivered,
               let deliveredString = islandDeliveredString(delivered: delivered, total: total),
               let totalString = islandInsulinFormatter.string(from: NSNumber(value: total)) {
                subtitle = String(format: NSLocalizedString("%1$@ of %2$@ U", comment: "Bolus progress island subtitle (1: delivered units)(2: total units)"), deliveredString, totalString)
            }
            return ActionIslandItem(id: "bolus", kind: .bolus, symbolName: "drop.fill",
                                    title: NSLocalizedString("Bolusing", comment: "The title of the cell indicating a bolus is in progress"),
                                    subtitle: subtitle, progress: progress, tint: insulinTint, isActionable: true)
        case .pumpSuspended(let resuming):
            return ActionIslandItem(id: "suspend", kind: .pumpSuspended, symbolName: "pause.circle.fill",
                                    title: resuming ? NSLocalizedString("Resuming", comment: "The title of the cell indicating insulin delivery is resuming") : NSLocalizedString("Insulin Suspended", comment: "The title of the cell indicating the pump is suspended"),
                                    subtitle: resuming ? nil : NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume insulin delivery"),
                                    progress: nil, tint: Color(UIColor.warning), isActionable: !resuming)
        case .scheduleOverrideEnabled(let override):
            return overrideIslandItem(override)
        case .onboardingSuspended:
            return ActionIslandItem(id: "onboarding", kind: .info, symbolName: "exclamationmark.circle.fill",
                                    title: NSLocalizedString("Setup Incomplete", comment: "The title of the cell indicating that onboarding is suspended"),
                                    subtitle: NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume onboarding"),
                                    progress: nil, tint: Color(UIColor.warning), isActionable: true)
        case .recommendManualGlucoseEntry:
            return ActionIslandItem(id: "glucose", kind: .info, symbolName: "drop.circle",
                                    title: NSLocalizedString("No Recent Glucose", comment: "The title of the cell indicating that there is no recent glucose"),
                                    subtitle: NSLocalizedString("Tap to Add", comment: "The subtitle of the cell displaying an action to add a manually measurement glucose value"),
                                    progress: nil, tint: Color(UIColor.glucoseTintColor), isActionable: true)
        }
    }

    private func activeOverrideIslandItem() -> ActionIslandItem? {
        if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride, !scheduleOverride.hasFinished() {
            return overrideIslandItem(scheduleOverride)
        } else if let preMealOverride = deviceManager.loopManager.settings.preMealOverride, !preMealOverride.hasFinished() {
            return overrideIslandItem(preMealOverride)
        }
        return nil
    }

    private func overrideIslandItem(_ override: TemporaryScheduleOverride) -> ActionIslandItem {
        let symbolName: String
        /// A preset's own emoji replaces the generic symbol when it has one.
        var emoji: String?
        let title: String
        let tint: Color
        let kind: ActionIslandItem.Kind
        // Every override item is tappable; what the tap DOES differs (see below).
        let actionable: Bool
        switch override.context {
        // Pre-meal and workout have no editor to open — but "nothing happens"
        // is not an acceptable answer for something that looks like a button.
        // Tapping either ENDS it, through the same confirm-then-clear paths the
        // toolbar buttons use (`togglePreMealMode` / `presentCustomPresets`).
        case .preMeal:
            symbolName = "fork.knife"
            title = NSLocalizedString("Pre-meal", comment: "Status island title for premeal override enabled")
            tint = Color(UIColor.carbTintColor)
            kind = .preMeal
            actionable = true
        case .legacyWorkout:
            symbolName = "figure.run"
            title = NSLocalizedString("Workout", comment: "Status island title for workout override enabled")
            tint = Color(UIColor.glucoseTintColor)
            kind = .override
            actionable = true
        case .preset(let preset):
            symbolName = "target"
            // The emoji becomes the icon, so it must not also be repeated in the
            // title — that rendered as "◎ 🏸 Name".
            emoji = preset.symbol.isEmpty ? nil : preset.symbol
            title = emoji == nil
                ? String(format: NSLocalizedString("%1$@ %2$@", comment: "The format for an active custom preset. (1: preset symbol)(2: preset name)"), preset.symbol, preset.name)
                : preset.name
            tint = Color(UIColor.glucoseTintColor)
            kind = .override
            actionable = true
        case .custom:
            symbolName = "target"
            title = NSLocalizedString("Custom Preset", comment: "The title of the cell indicating a generic custom preset is enabled")
            tint = Color(UIColor.glucoseTintColor)
            kind = .override
            actionable = true
        }

        var subtitle: String?
        if override.isActive() {
            if case .finite = override.duration {
                let endTimeText = DateFormatter.localizedString(from: override.activeInterval.end, dateStyle: .none, timeStyle: .short)
                subtitle = String(format: NSLocalizedString("until %@", comment: "The format for the description of a custom preset end date"), endTimeText)
            }
        } else {
            let startTimeText = DateFormatter.localizedString(from: override.startDate, dateStyle: .none, timeStyle: .short)
            subtitle = String(format: NSLocalizedString("starting at %@", comment: "The format for the description of a custom preset start date"), startTimeText)
        }

        return ActionIslandItem(id: "override", kind: kind,
                                symbolName: symbolName, emoji: emoji, title: title, subtitle: subtitle, progress: nil, tint: tint, isActionable: actionable)
    }

    private func handleIslandTap(_ item: ActionIslandItem) {
        guard item.isActionable else { return }
        switch item.kind {
        case .bolus:
            cancelActiveBolus()
        case .pumpSuspended:
            resumeInsulinDelivery()
        case .override:
            if let override = activeEditableOverride() {
                presentEditOverride(override)
            } else {
                // Workout has no editor. This is the toolbar preset button's own
                // path: it asks "Disable Preset?" first, so a stray tap on the
                // island can't silently drop an override.
                presentCustomPresets()
            }
        case .info:
            if item.id == "onboarding" {
                onboardingManager.resume()
            } else if item.id == "glucose" {
                presentBolusEntryView(enableManualGlucoseEntry: true)
            }
        case .preMeal:
            // Confirms ("Disable Pre-Meal Preset?") before clearing — same call
            // the pre-meal toolbar button makes.
            togglePreMealMode()
        }
    }

    /// The currently-active custom/preset override, if one is editable.
    private func activeEditableOverride() -> TemporaryScheduleOverride? {
        guard let override = deviceManager.loopManager.settings.scheduleOverride, !override.hasFinished() else {
            return nil
        }
        switch override.context {
        case .preMeal, .legacyWorkout:
            return nil
        default:
            return override
        }
    }

    private func presentEditOverride(_ override: TemporaryScheduleOverride) {
        let vc = AddEditOverrideTableViewController(glucoseUnit: statusCharts.glucose.glucoseUnit)
        vc.inputMode = .editOverride(override)
        vc.delegate = self
        show(vc, sender: nil)
    }

    private func resumeInsulinDelivery() {
        updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: true), newSize: nil, animated: true)
        deviceManager.pumpManager?.resumeDelivery() { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    let alert = UIAlertController(with: error, title: NSLocalizedString("Failed to Resume Insulin Delivery", comment: "The alert title for a resume error"))
                    self.present(alert, animated: true, completion: nil)
                    if case .suspended = self.basalDeliveryState {
                        self.updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: false), newSize: nil, animated: true)
                    }
                } else {
                    self.updateBannerAndHUDandStatusRows(statusRowMode: self.determineStatusRowMode(), newSize: nil, animated: true)
                    self.refreshContext.update(with: .insulin)
                    self.log.debug("[reloadData] after manually resuming suspend")
                    self.reloadData()
                }
            }
        }
    }

    private func cancelActiveBolus() {
        updateBannerAndHUDandStatusRows(statusRowMode: .cancelingBolus, newSize: nil, animated: true)
        deviceManager.pumpManager?.cancelBolus() { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    // show user confirmation and actual delivery amount?
                    break
                case .failure(let error):
                    self.presentErrorCancelingBolus(error)
                    if case .inProgress(let dose) = self.bolusState {
                        self.updateBannerAndHUDandStatusRows(statusRowMode: .bolusing(dose: dose), newSize: nil, animated: true)
                    } else {
                        self.updateBannerAndHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                    }
                }
            }
        }
    }

    private var shouldShowBannerWarning: Bool {
        alertPermissionsChecker.showWarning || alertMuter.configuration.shouldMute
    }

    private func updateBannerRow(animated: Bool) {
        let warningWasVisible = tableView.numberOfRows(inSection: Section.alertWarning.rawValue) != 0
        if !shouldShowBannerWarning && warningWasVisible {
            tableView.deleteRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else if shouldShowBannerWarning && !warningWasVisible {
            tableView.insertRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else {
            tableView.reloadRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: .none)
        }
    }

    private func updateBannerAndHUDandStatusRows(statusRowMode: StatusRowMode, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD

        self.statusRowMode = statusRowMode

        let hudIsVisible = self.shouldShowHUD

        hudView?.cgmStatusHUD?.isVisible = hudIsVisible

        // The HUD is no longer a row — show/hide the floating bar instead and let
        // the layout pass re-reserve its inset. Assigned unconditionally, because
        // `shouldShowHUD` is now derived: `hudWasVisible` and `hudIsVisible` agree
        // whenever the geometry has not changed, and gating the assignment on them
        // would mean nothing ever put the bar back.
        floatingHUDView.isHidden = !hudIsVisible
        if hudWasVisible != hudIsVisible {
            view.setNeedsLayout()
        }

        tableView.beginUpdates()

        updateBannerRow(animated: animated)

        tableView.endUpdates()

        // The island is no longer a row — it is part of the fixed top header, so
        // it is refreshed directly. Done unconditionally (not only when the
        // primary mode changes) so a co-active override's secondary bubble
        // updates too. SwiftUI spring-morphs between the states itself.
        updateIslandItems()
    }

    private func redrawCharts() {
        tableView.beginUpdates()
        charts.prerender()
        for case let cell as ChartTableViewCell in tableView.visibleCells {
            cell.reloadChart()

            if let indexPath = tableView.indexPath(for: cell) {
                self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)
            }
        }
        tableView.endUpdates()
    }

    // MARK: - Toolbar data

    private var preMealMode: Bool? = nil {
        didSet {
            guard oldValue != preMealMode else {
                return
            }
            updatePresetModeAvailability(automaticDosingEnabled: automaticDosingStatus.automaticDosingEnabled)
        }
    }
    private lazy var preMealModeAllowed: Bool = {
        onboardingManager.isComplete &&
                (automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
    }()

    private func updatePresetModeAvailability(automaticDosingEnabled: Bool) {
        preMealModeAllowed = onboardingManager.isComplete &&
                (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
        workoutModeAllowed = onboardingManager.isComplete && workoutMode != nil
        updateToolbarItems()
    }

    private var workoutMode: Bool? = nil {
        didSet {
            guard oldValue != workoutMode else {
                return
            }
            workoutModeAllowed = workoutMode != nil && onboardingManager.isComplete
            updateToolbarItems()
        }
    }
    private lazy var workoutModeAllowed: Bool = {
        workoutMode != nil && onboardingManager.isComplete
    }()

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .alertWarning:
            return shouldShowBannerWarning ? 1 : 0
        case .charts:
            return ChartRow.allCases.count
        }
    }

    private class AlertPermissionsDisabledWarningCell: UITableViewCell {
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let titleImageAttachment = NSTextAttachment()
            titleImageAttachment.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.white)
            let title = NSMutableAttributedString(string: NSLocalizedString(" Safety Notifications are OFF", comment: "Warning text for when Notifications or Critical Alerts Permissions is disabled"))
            let titleWithImage = NSMutableAttributedString(attachment: titleImageAttachment)
            titleWithImage.append(title)
            contentConfig.attributedText = titleWithImage
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .bold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = NSLocalizedString("Fix now by turning Notifications, Critical Alerts and Time Sensitive Notifications ON.", comment: "Secondary text for alerts disabled warning, which appears on the main status screen.")
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.backgroundColor = .critical
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 10)
            backgroundConfiguration?.cornerRadius = 24

            let disclosureIndicator = UIImage(systemName: "chevron.right")?.withTintColor(.white)
            let imageView = UIImageView(image: disclosureIndicator)
            imageView.tintColor = .white
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }

    private class MuteAlertsWarningCell: UITableViewCell {
        var formattedAlertMuteEndTime: String = NSLocalizedString("Unknown", comment: "label for when the alert mute end time is unknown")

        fileprivate class GradientView: UIView {
            override static var layerClass: AnyClass { CAGradientLayer.self }
        }
        
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let title = NSMutableAttributedString(string: NSLocalizedString("All Alerts Muted", comment: "Warning text for when alerts are muted"))
            let image = UIImage(systemName: "speaker.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .thin, scale: .large))
            contentConfig.image = image
            contentConfig.imageProperties.tintColor = .white
            contentConfig.attributedText = title
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .semibold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = String(format: NSLocalizedString("Until %1$@", comment: "indication of when alerts will be unmuted (1: time when alerts unmute)"), formattedAlertMuteEndTime)
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            let backgroundGradient = GradientView()
            (backgroundGradient.layer as? CAGradientLayer)?.colors = [UIColor.warning.cgColor, UIColor.warning.withAlphaComponent(0.9).cgColor]
            
            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.customView = backgroundGradient
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 5, trailing: 5)
            backgroundConfiguration?.cornerRadius = 24

            let unmuteIndicator = UIImage(systemName: "stop.circle")?.withTintColor(.white)
            let imageView = UIImageView(image: unmuteIndicator)
            imageView.tintColor = .white
            imageView.frame.size = CGSize(width: 30, height: 30)
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                let cell = tableView.dequeueReusableCell(withIdentifier: AlertPermissionsDisabledWarningCell.className, for: indexPath) as! AlertPermissionsDisabledWarningCell
                return cell
            } else {
                let cell = tableView.dequeueReusableCell(withIdentifier: MuteAlertsWarningCell.className, for: indexPath) as! MuteAlertsWarningCell
                cell.formattedAlertMuteEndTime = alertMuter.formattedEndTime
                cell.selectionStyle = .none
                return cell
            }
        case .charts:
            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.glucoseChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph"))
                cell.doesNavigate = automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled
            case .iob:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.iobChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph"))
            case .dose:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.doseChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Insulin Delivery", comment: "The title of the insulin delivery graph"))
            case .cob:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.cobChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board graph"))
            }

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.setAlpha(alpha: alpha)

            cell.setSubtitleTextColor(color: UIColor.secondaryLabel)

            return cell
        }
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                if let eventualGlucose = eventualGlucoseDescription {
                    cell.setSubtitleLabel(label: String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose))
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
                cell.doesNavigate = automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled
            case .iob:
                if let currentIOB = currentIOBDescription {
                    cell.setSubtitleLabel(label: currentIOB)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            case .dose:
                let integerFormatter = NumberFormatter()
                integerFormatter.maximumFractionDigits = 0

                if  let total = totalDelivery,
                    let totalString = integerFormatter.string(from: total) {
                    cell.setSubtitleLabel(label: String(format: NSLocalizedString("%@ U Total", comment: "The subtitle format describing total insulin. (1: localized insulin total)"), totalString))
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            case .cob:
                if let currentCOB = currentCOBDescription {
                    cell.setSubtitleLabel(label: currentCOB)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            }
        case .alertWarning:
            break
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            // Deliberately does NOT subtract the floating status bar's height.
            // The charts are sized to the full viewport, so the content is
            // taller than the visible area by exactly that bar's height and
            // therefore actually travels UNDER the glass as you scroll. Sizing
            // them to "viewport minus bar" instead made the content fit exactly,
            // the table never scrolled, and the glass had nothing to refract —
            // which is what made it read as a flat white blob.
            var availableSize = max(tableView.bounds.width, tableView.bounds.height)
            availableSize -= (tableView.safeAreaInsets.top + tableView.safeAreaInsets.bottom)

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                return max(106, 0.37 * availableSize)
            case .iob, .dose, .cob:
                return max(106, 0.21 * availableSize)
            }
        case .alertWarning:
            return UITableView.automaticDimension
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                tableView.deselectRow(at: indexPath, animated: true)
                AlertPermissionsChecker.gotoSettings()
            } else {
                tableView.deselectRow(at: indexPath, animated: true)
                presentUnmuteAlertConfirmation()
            }
        case .charts:
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                if automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled {
                    performSegue(withIdentifier: PredictionTableViewController.className, sender: indexPath)
                }
            case .iob, .dose:
                performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: indexPath)
            case .cob:
                performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: indexPath)
            }
        }
    }

    private func presentUnmuteAlertConfirmation() {
        let title = NSLocalizedString("Unmute Alerts?", comment: "The alert title for unmute alert confirmation")
        let body = NSLocalizedString("Tap Unmute to resume sound for your alerts and alarms.", comment: "The alert body for unmute alert confirmation")
        let action = UIAlertAction(
            title: NSLocalizedString("Unmute", comment: "The title of the action used to unmute alerts"),
            style: .default) { _ in
                self.alertMuter.unmuteAlerts()
            }
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        alert.addCancelAction { _ in }
        present(alert, animated: true, completion: nil)
    }

    private func presentErrorCancelingBolus(_ error: (Error)) {
        log.error("Error Canceling Bolus: %@", error.localizedDescription)
        let title = NSLocalizedString("Error Canceling Bolus", comment: "The alert title for an error while canceling a bolus")
        let body = NSLocalizedString("Unable to stop the bolus in progress. Move your iPhone closer to the pump and try again. Check your insulin delivery history for details, and monitor your glucose closely.", comment: "The alert body for an error while canceling a bolus")
        let action = UIAlertAction(
            title: NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert"), style: .default)
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Actions

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.newCarbEntryActivityType:
            presentCarbEntryScreen(activity)
        default:
            break
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        var targetViewController = segue.destination

        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }

        switch targetViewController {
        case let vc as CarbAbsorptionViewController:
            vc.isOnboardingComplete = onboardingManager.isComplete
            vc.automaticDosingStatus = automaticDosingStatus
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
        case let vc as InsulinDeliveryTableViewController:
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
            vc.enableEntryDeletion = FeatureFlags.entryDeletionEnabled
            vc.headerValueLabelColor = .insulinTintColor
        case let vc as OverrideSelectionViewController:
            if deviceManager.loopManager.settings.futureOverrideEnabled() {
                vc.scheduledOverride = deviceManager.loopManager.settings.scheduleOverride
            }
            vc.presets = deviceManager.loopManager.settings.overridePresets
            vc.glucoseUnit = statusCharts.glucose.glucoseUnit
            vc.overrideHistory = deviceManager.loopManager.overrideHistory.getEvents()
            vc.delegate = self
            // Pre-Meal lives IN the override screen, as a fixed button along its
            // bottom. It goes in the TOOLBAR, not the navigation bar: that
            // screen's own `viewDidLoad` runs after this and assigns
            // `navigationItem.rightBarButtonItems = [saveButton, editButton]`,
            // which silently wiped an item set here. `toolbarItems` is never
            // touched by it, so the button survives — and the screen itself,
            // being LoopKitUI's, still needs no edit.
            vc.toolbarItems = [.flexibleSpace(), preMealBarButtonItem(), .flexibleSpace()]
            (segue.destination as? UINavigationController)?.isToolbarHidden = false
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        default:
            break
        }
    }

    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {}

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {}

    @IBAction func userTappedAddCarbs() {
        presentCarbEntryScreen(nil)
    }

    /// Marks a presented carb/meal-entry screen so RootNavigationController's
    /// "view status" activity restoration doesn't dismiss it on app foreground.
    static let mealEntryScreenIdentifier = "MealEntryScreen"

    func presentCarbEntryScreen(_ activity: NSUserActivity?) {
        let navigationWrapper: UINavigationController
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            let viewModel = SimpleBolusViewModel(delegate: deviceManager, displayMealEntry: true)
            if let activity = activity {
                viewModel.restoreUserActivityState(activity)
            }
            let bolusEntryView = SimpleBolusView(viewModel: viewModel).environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: bolusEntryView, isModalInPresentation: false)
            navigationWrapper = UINavigationController(rootViewController: hostingController)
            hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: navigationWrapper, action: #selector(dismissWithAnimation))
            navigationWrapper.view.accessibilityIdentifier = Self.mealEntryScreenIdentifier
            present(navigationWrapper, animated: true)
        } else if activity != nil {
            // Preserve the existing screen for missed-meal / Siri restore flows.
            let viewModel = CarbEntryViewModel(delegate: deviceManager)
            if let activity {
                viewModel.restoreUserActivityState(activity)
            }
            let carbEntryView = CarbEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: carbEntryView, isModalInPresentation: false)
            hostingController.view.accessibilityIdentifier = Self.mealEntryScreenIdentifier
            present(hostingController, animated: true)
        } else {
            // Redesigned meal-entry screen (§7) for fresh manual entry.
            let viewModel = MealEntryViewModel(delegate: deviceManager)
            let mealEntryView = MealEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: mealEntryView, isModalInPresentation: false)
            hostingController.view.accessibilityIdentifier = Self.mealEntryScreenIdentifier
            present(hostingController, animated: true)
        }
        deviceManager.analyticsServicesManager.didDisplayCarbEntryScreen()
    }

    // MARK: - Meal entry picker (tap/hold the carb button → AI / Manual bubbles)

    private static var mealButtonKey: UInt8 = 0
    var mealButton: UIButton {
        if let button = objc_getAssociatedObject(self, &Self.mealButtonKey) as? UIButton {
            return button
        }
        let button = UIButton(type: .custom)
        // Template rendering so tintColor still greens the icon (.custom, unlike
        // .system, shows images in their original mode by default).
        button.setImage(Self.scaledCarbsImage, for: .normal)
        button.tintColor = .carbTintColor
        // No highlight dim/tint on press (the .system button flashed white).
        button.adjustsImageWhenHighlighted = false
        // Center the icon so a scale transform grows it symmetrically (no drift).
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.accessibilityLabel = NSLocalizedString("Add Meal", comment: "The label of the carb entry button")
        button.addTarget(self, action: #selector(mealButtonTapped), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(mealButtonPressed(_:)))
        press.minimumPressDuration = 0.25
        button.addGestureRecognizer(press)
        objc_setAssociatedObject(self, &Self.mealButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return button
    }

    private static var mealPickerKey: UInt8 = 0
    private var mealPicker: MealEntryPickerOverlay? {
        get { objc_getAssociatedObject(self, &Self.mealPickerKey) as? MealEntryPickerOverlay }
        set { objc_setAssociatedObject(self, &Self.mealPickerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc private func mealButtonTapped() {
        // AI off → behave exactly like today: straight to manual entry, no picker.
        guard CarbEstimationSettings().isEnabled else {
            presentCarbEntryScreen(nil)
            return
        }
        if let picker = mealPicker {
            picker.dismiss()
            mealPicker = nil
        } else {
            showMealPicker()
        }
    }

    @objc private func mealButtonPressed(_ gesture: UILongPressGestureRecognizer) {
        guard CarbEstimationSettings().isEnabled else { return }
        switch gesture.state {
        case .began:
            setMealButtonExpanded(true)   // subtle grow while holding
            if mealPicker == nil { showMealPicker() }
        case .changed:
            if let picker = mealPicker, let host = picker.superview {
                picker.updateHover(at: gesture.location(in: host))
            }
        case .ended:
            setMealButtonExpanded(false)
            if let picker = mealPicker {
                picker.commitHoverOrDismiss()
                if picker.superview == nil { mealPicker = nil }
            }
        case .cancelled, .failed:
            setMealButtonExpanded(false)
            mealPicker?.dismiss()
            mealPicker = nil
        default:
            break
        }
    }

    /// Subtle, fluid spring scale on the carb button while it's being held.
    /// Animates the BUTTON's own transform (its layoutSubviews doesn't touch it,
    /// so the highlight pass on touch-down can't cancel the grow); the centered
    /// content keeps it from drifting sideways.
    private func setMealButtonExpanded(_ expanded: Bool) {
        UIView.animate(withDuration: expanded ? 0.7 : 0.5, delay: 0,
                       usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.mealButton.transform = expanded
                ? CGAffineTransform(scaleX: 1.4, y: 1.4)
                : .identity
        }
    }

    private func showMealPicker() {
        // Host on the navigation controller's view (not the scrolling table view)
        // so the bubbles stay pinned above the bottom bar while scrolling.
        let host: UIView = navigationController?.view ?? view
        let anchor = mealButton.convert(mealButton.bounds, to: host)
        let picker = MealEntryPickerOverlay(anchor: anchor) { [weak self] choice in
            guard let self else { return }
            self.mealPicker = nil
            switch choice {
            case .ai:     self.userTappedAICarbEstimation()
            case .manual: self.presentCarbEntryScreen(nil)
            case .none:   break
            }
        }
        host.addSubview(picker)
        picker.frame = host.bounds
        picker.show()
        mealPicker = picker
    }

    @objc func userTappedAICarbEstimation() {
        let viewModel = MealEntryViewModel(delegate: deviceManager)
        let flow = AICarbEntryFlowView(viewModel: viewModel, coordinator: CarbEstimationCoordinator())
            .environmentObject(deviceManager.displayGlucosePreference)
        let hostingController = DismissibleHostingController(rootView: flow, isModalInPresentation: false)
        hostingController.view.accessibilityIdentifier = Self.mealEntryScreenIdentifier
        present(hostingController, animated: true)
    }

    @IBAction func presentBolusScreen() {
        presentBolusEntryView()
    }
    
    @ViewBuilder
    func bolusEntryView(enableManualGlucoseEntry: Bool = false) -> some View {
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            SimpleBolusView(
                viewModel: SimpleBolusViewModel(
                    delegate: deviceManager,
                    displayMealEntry: false
                )
            )
            .environmentObject(deviceManager.displayGlucosePreference)
        } else {
            let viewModel: BolusEntryViewModel = {
                let viewModel = BolusEntryViewModel(
                    delegate: deviceManager,
                    screenWidth: UIScreen.main.bounds.width,
                    isManualGlucoseEntryEnabled: enableManualGlucoseEntry
                )
                
                Task { @MainActor in
                    await viewModel.generateRecommendationAndStartObserving()
                }
                
                viewModel.analyticsServicesManager = deviceManager.analyticsServicesManager
                
                return viewModel
            }()
            
            BolusEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
        }
    }

    func presentBolusEntryView(enableManualGlucoseEntry: Bool = false) {
        let hostingController = DismissibleHostingController(
            content: bolusEntryView(
                enableManualGlucoseEntry: enableManualGlucoseEntry
            )
        )
        
        let navigationWrapper = UINavigationController(rootViewController: hostingController)
        hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: navigationWrapper, action: #selector(dismissWithAnimation))
        present(navigationWrapper, animated: true)
        deviceManager.analyticsServicesManager.didDisplayBolusScreen()
    }

    /// Statistics — a plain native bar item so it keeps its place in the toolbar's
    /// shared Liquid Glass (see DESIGN_SYSTEM.md: never a custom view here).
    private func createStatisticsButtonItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: Self.statisticsImage,
                                   style: .plain,
                                   target: self,
                                   action: #selector(presentStatistics))
        item.accessibilityLabel = NSLocalizedString("Statistics", comment: "The label of the statistics button")
        // Same green as the carb/meal button beside it, per the user's choice.
        item.tintColor = UIColor.carbTintColor
        return item
    }

    /// Sized to sit with the custom-asset icons beside it — an SF Symbol at its
    /// default bar size reads noticeably smaller than they do.
    ///
    /// A plain trend line: every other icon here is outline line-art, so the
    /// filled bars of `chart.bar.xaxis` and then the point markers on
    /// `chart.xyaxis.line` both read as noise beside them. This symbol is a
    /// continuous stroke with no dots.
    ///
    /// Weight `.regular` rather than `.light` — one step up, which thickens the
    /// stroke just enough to sit level with the custom PDF icons instead of
    /// looking faint next to them.
    private static let statisticsImage = UIImage(
        systemName: "chart.line.uptrend.xyaxis",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20 * toolbarIconScale, weight: .regular))

    @objc private func presentStatistics() {
        // Current therapy settings are READ here purely so the review screen can
        // show "your setting" beside "your data says". Nothing writes them back.
        let therapy = deviceManager.loopManager.therapySettings
        let now = Date()
        let currentISF = therapy.insulinSensitivitySchedule?
            .quantity(at: now).doubleValue(for: .milligramsPerDeciliter)
        let currentCarbRatio = therapy.carbRatioSchedule?.value(at: now)
        let scheduledBasal = therapy.basalRateSchedule?.total()

        let hostingController = DismissibleHostingController(
            rootView: HistoryStatisticsView(currentISF: currentISF,
                                            currentCarbRatio: currentCarbRatio,
                                            scheduledBasalPerDay: scheduledBasal,
                                            showsDoneButton: true),
            isModalInPresentation: false)
        let navigationWrapper = UINavigationController(rootViewController: hostingController)
        // Done lives in the SwiftUI toolbar so it matches every other Done in
        // the app; adding a UIKit one here would give two of them.
        present(navigationWrapper, animated: true)
    }

    /// The presets button — opens the override screen directly. Pre-Meal is a
    /// button inside that screen, so the two live together without this being a
    /// menu the user has to open first.
    private func createPresetsButtonItem(selected: Bool, isEnabled: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: Self.scaledWorkoutImages[selected],
                                   style: .plain,
                                   target: self,
                                   action: #selector(toggleWorkoutMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Presets", comment: "The label of the presets button")
        if selected { item.accessibilityTraits.insert(.selected) }
        item.tintColor = UIColor.glucoseTintColor
        item.isEnabled = isEnabled
        return item
    }

    /// The Pre-Meal control shown in the override screen's navigation bar.
    /// Reflects current state in its title so it says what tapping will do.
    private func preMealBarButtonItem() -> UIBarButtonItem {
        let on = preMealMode == true
        let item = UIBarButtonItem(
            title: on
                ? NSLocalizedString("End Pre-Meal", comment: "Button ending pre-meal from the override screen")
                : NSLocalizedString("Pre-Meal", comment: "Button starting pre-meal from the override screen"),
            style: on ? .done : .plain,
            target: self,
            action: #selector(preMealButtonFromOverrideScreen))
        item.tintColor = UIColor.carbTintColor
        item.isEnabled = preMealModeAllowed
        return item
    }

    @objc private func preMealButtonFromOverrideScreen(_ sender: UIBarButtonItem) {
        // 🐛 ORDER IS THE WHOLE BUG. This used to toggle FIRST and dismiss second,
        // which silently did nothing when starting pre-meal: `togglePreMealMode`
        // needs to PRESENT the duration picker, and `self` was already presenting
        // the override screen — UIKit refuses a second presentation, logs a
        // warning nobody sees, and then the dismiss below closed the override
        // screen. Net effect: tap Pre-Meal, screen closes, nothing happens.
        // (Ending pre-meal appeared to work, because that path only mutates
        // settings and presents nothing — which is why this looked intermittent.)
        //
        // Dismiss FIRST, act in the completion, when self is free to present.
        dismiss(animated: true) { [weak self] in
            self?.togglePreMealMode(confirm: false)
        }
    }


    @IBAction func premealButtonTapped(_ sender: UIBarButtonItem) {
        togglePreMealMode(confirm: false)
    }
    
    func togglePreMealMode(confirm: Bool = true) {
        if preMealMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Pre-Meal Preset?", message: "This will remove any currently applied pre-meal preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride(matching: .preMeal)
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
            }
        } else {
            presentPreMealModeAlertController()
        }
    }
    
    func presentPreMealModeAlertController() {
        let vc = UIAlertController(premealDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.workoutMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enablePreMealOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enablePreMealOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    func presentCustomPresets(confirm: Bool = true) {
        if workoutMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Preset?", message: "This will remove any currently applied preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride()
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
            }
        } else {
            if FeatureFlags.sensitivityOverridesEnabled {
                performSegue(withIdentifier: OverrideSelectionViewController.className, sender: toolbarItems![ToolbarIndex.presets])
            } else {
                presentWorkoutModeAlertController()
            }
        }
    }
    
    func presentWorkoutModeAlertController() {
        let vc = UIAlertController(workoutDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.preMealMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    @IBAction func toggleWorkoutMode(_ sender: UIBarButtonItem) {
        presentCustomPresets(confirm: false)
    }
    
    @IBAction func onSettingsTapped(_ sender: UIBarButtonItem) {
        presentSettings()
    }

    private func presentSettings() {
        let deletePumpDataFunc: () -> PumpManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.pumpManager is TestingPumpManager) ? {
                [weak self] in self?.deviceManager.deleteTestingPumpData()
                } : nil
        }
        let deleteCGMDataFunc: () -> CGMManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.cgmManager is TestingCGMManager) ? {
                [weak self] in self?.deviceManager.deleteTestingCGMData()
                } : nil
        }
        let pumpViewModel = PumpManagerViewModel(
            image: { [weak self] in self?.deviceManager.pumpManager?.smallImage },
            name: { [weak self] in self?.deviceManager.pumpManager?.localizedTitle ?? "" },
            isSetUp: { [weak self] in self?.deviceManager.pumpManager?.isOnboarded == true },
            availableDevices: deviceManager.availablePumpManagers,
            deleteTestingDataFunc: deletePumpDataFunc,
            onTapped: { [weak self] in
                self?.onPumpTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addPumpManager(withIdentifier: $0.identifier)
        })

        let cgmViewModel = CGMManagerViewModel(
            image: {[weak self] in (self?.deviceManager.cgmManager as? DeviceManagerUI)?.smallImage },
            name: {[weak self] in self?.deviceManager.cgmManager?.localizedTitle ?? "" },
            isSetUp: {[weak self] in self?.deviceManager.cgmManager?.isOnboarded == true },
            availableDevices: deviceManager.availableCGMManagers,
            deleteTestingDataFunc: deleteCGMDataFunc,
            onTapped: { [weak self] in
                self?.onCGMTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addCGMManager(withIdentifier: $0.identifier)
        })
        let servicesViewModel = ServicesViewModel(showServices: FeatureFlags.includeServicesInSettingsEnabled,
                                                  availableServices: { [weak self] in self?.deviceManager.servicesManager.availableServices ?? [] },
                                                  activeServices: { [weak self] in self?.deviceManager.servicesManager.activeServices ?? [] },
                                                  delegate: self)
        let versionUpdateViewModel = VersionUpdateViewModel(supportManager: supportManager, guidanceColors: .default)
        let viewModel = SettingsViewModel(alertPermissionsChecker: alertPermissionsChecker,
                                          alertMuter: alertMuter,
                                          versionUpdateViewModel: versionUpdateViewModel,
                                          pumpManagerSettingsViewModel: pumpViewModel,
                                          cgmManagerSettingsViewModel: cgmViewModel,
                                          servicesViewModel: servicesViewModel,
                                          criticalEventLogExportViewModel: CriticalEventLogExportViewModel(exporterFactory: deviceManager.criticalEventLogExportManager),
                                          therapySettings: { [weak self] in self?.deviceManager.loopManager.therapySettings ?? TherapySettings() },
                                          sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                                          initialDosingEnabled: deviceManager.loopManager.settings.dosingEnabled,
                                          isClosedLoopAllowed: automaticDosingStatus.$isAutomaticDosingAllowed,
                                          automaticDosingStrategy: deviceManager.loopManager.settings.automaticDosingStrategy,
                                          availableSupports: supportManager.availableSupports,
                                          isOnboardingComplete: onboardingManager.isComplete,
                                          therapySettingsViewModelDelegate: deviceManager,
                                          delegate: self)
        let hostingController = DismissibleHostingController(
            rootView: SettingsView(viewModel: viewModel, localizedAppNameAndVersion: supportManager.localizedAppNameAndVersion)
                .environmentObject(deviceManager.displayGlucosePreference)
                .environment(\.appName, Bundle.main.bundleDisplayName),
            isModalInPresentation: false)
        present(hostingController, animated: true)
    }

    private func onPumpTapped() {
        guard var settingsViewController = deviceManager.pumpManager?.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures, allowedInsulinTypes: deviceManager.allowedInsulinTypes) else {
            // assert?
            return
        }
        settingsViewController.pumpManagerOnboardingDelegate = deviceManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }

    private func onCGMTapped() {
        guard let cgmManager = deviceManager.cgmManager as? CGMManagerUI else {
            // assert?
            return
        }

        var settings = cgmManager.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, displayGlucosePreference: deviceManager.displayGlucosePreference, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        settings.cgmManagerOnboardingDelegate = deviceManager
        settings.completionDelegate = self
        show(settings, sender: self)
    }

    private func automaticDosingStatusChanged(_ automaticDosingEnabled: Bool) {
        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)
        hudView?.loopCompletionHUD.loopIconClosed = automaticDosingEnabled
        hudView?.loopCompletionHUD.closedLoopDisallowedLocalizedDescription = deviceManager.closedLoopDisallowedLocalizedDescription
    }

    // MARK: - HUDs

    @IBOutlet var hudView: StatusBarHUDView? {
        didSet {
            guard let hudView = hudView, hudView != oldValue else {
                return
            }

            let statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showLoopCompletionMessage(_:)))
            hudView.loopCompletionHUD.addGestureRecognizer(statusTapGestureRecognizer)
            hudView.loopCompletionHUD.accessibilityHint = NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint")

            let pumpStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(pumpStatusTapped(_:)))
            hudView.pumpStatusHUD.addGestureRecognizer(pumpStatusTapGestureRecognizer)

            let cgmStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(cgmStatusTapped(_:)))
            hudView.cgmStatusHUD.addGestureRecognizer(cgmStatusTapGestureRecognizer)

            configurePumpManagerHUDViews()
            configureCGMManagerHUDViews()

            // when HUD view is initialized, update loop completion HUD (e.g., icon and last loop completed)
            hudView.loopCompletionHUD.stateColors = .loopStatus
            hudView.loopCompletionHUD.loopIconClosed = automaticDosingStatus.automaticDosingEnabled
            hudView.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

            hudView.cgmStatusHUD.stateColors = .cgmStatus
            hudView.cgmStatusHUD.tintColor = .label
            hudView.pumpStatusHUD.stateColors = .pumpStatus
            hudView.pumpStatusHUD.tintColor = .insulinTintColor

            refreshContext.update(with: .status)
            log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }

    private func configurePumpManagerHUDViews() {
        if let hudView = hudView {
            hudView.removePumpManagerProvidedView()
            if let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider {
                if let view = pumpManagerHUDProvider.createHUDView() {
                    addPumpManagerViewToHUD(view)
                }
                pumpManagerHUDProvider.visible = active && onscreen
            }
            hudView.pumpStatusHUD.presentStatusHighlight(deviceManager.pumpStatusHighlight)
            hudView.pumpStatusHUD.lifecycleProgress = deviceManager.pumpLifecycleProgress
        }
    }

    /// Pushes the current device statuses straight into the HUD.
    ///
    /// `lifecycleProgress` (the pod/reservoir expiry indicator) is otherwise only
    /// assigned inside `reloadData`'s async completion block, and changing a
    /// device's expiry urgency in its own settings screen does not emit a
    /// `PumpManagerStatus` update — so the indicator kept its old colour until
    /// the next loop cycle, minutes later. Called on the way back onto this
    /// screen, which is where such a change is made from.
    private func refreshDeviceStatusHUD() {
        guard let hudView = hudView else { return }

        hudView.cgmStatusHUD.presentStatusHighlight(deviceManager.cgmStatusHighlight)
        hudView.cgmStatusHUD.presentStatusBadge(deviceManager.cgmStatusBadge)
        hudView.cgmStatusHUD.lifecycleProgress = deviceManager.cgmLifecycleProgress

        hudView.pumpStatusHUD.presentStatusHighlight(deviceManager.pumpStatusHighlight)
        hudView.pumpStatusHUD.presentStatusBadge(deviceManager.pumpStatusBadge)
        hudView.pumpStatusHUD.lifecycleProgress = deviceManager.pumpLifecycleProgress
    }

    private func configureCGMManagerHUDViews() {
        if let hudView = hudView {
            hudView.cgmStatusHUD.presentStatusHighlight(deviceManager.cgmStatusHighlight)
            hudView.cgmStatusHUD.lifecycleProgress = deviceManager.cgmLifecycleProgress
        }
    }

    private func addPumpManagerViewToHUD(_ view: BaseHUDView) {
        if let hudView = hudView {
            view.stateColors = .pumpStatus
            hudView.addPumpManagerProvidedHUDView(view)
        }
    }

    @objc private func showLoopCompletionMessage(_: Any) {
        guard let loopCompletionMessage = hudView?.loopCompletionHUD.loopCompletionMessage else { return }
        presentLoopCompletionMessage(title: loopCompletionMessage.title, message: loopCompletionMessage.message)
    }

    private func presentLoopCompletionMessage(title: String, message: String) {
        let action = UIAlertAction(title: NSLocalizedString("Dismiss", comment: "The button label of the action used to dismiss an error alert"),
                                   style: .default)
        let alertController = UIAlertController(title: title,
                                                message: message,
                                                preferredStyle: .alert)
        alertController.addAction(action)
        present(alertController, animated: true)
    }

    @objc private func showLastError(_: Any) {
        let error: Error?
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            error = deviceError.error
        } else if let lastLoopError = lastLoopError {
            error = lastLoopError
        } else {
            error = nil
        }
        if let error = error {
            let alertController = UIAlertController(with: error)
            let manualLoopAction = UIAlertAction(title: NSLocalizedString("Retry", comment: "The button text for attempting a manual loop"), style: .default, handler: { _ in
                self.deviceManager.refreshDeviceData()
            })
            alertController.addAction(manualLoopAction)
            present(alertController, animated: true)
        }
    }

    @objc private func pumpStatusTapped(_ sender: UIGestureRecognizer) {
        if let pumpStatusView = sender.view as? PumpStatusHUDView {
            executeHUDTapAction(deviceManager.didTapOnPumpStatus(pumpStatusView.pumpManagerProvidedHUD))
        }
    }

    @objc private func cgmStatusTapped( _ sender: UIGestureRecognizer) {
        executeHUDTapAction(deviceManager.didTapOnCGMStatus())
    }

    private func executeHUDTapAction(_ action: HUDTapAction?) {
        guard let action = action else {
            return
        }

        switch action {
        case .presentViewController(let vc):
            var completionNotifyingVC = vc
            completionNotifyingVC.completionDelegate = self
            present(completionNotifyingVC, animated: true, completion: nil)
        case .openAppURL(let url):
            UIApplication.shared.open(url)
        case .setupNewCGM:
            addNewCGMManager()
        case .setupNewPump:
            addNewPumpManager()
        default:
            return
        }
    }

    private func addNewPumpManager() {
        let availablePumpManagers = deviceManager.availablePumpManagers

        switch availablePumpManagers.count {
        case 1:
            if let availablePumpManager = availablePumpManagers.first {
                addPumpManager(withIdentifier: availablePumpManager.identifier)
            }
        default:
            let alert = UIAlertController(availablePumpManagers: availablePumpManagers) { [weak self] (identifier) in
                self?.addPumpManager(withIdentifier: identifier)
            }
            alert.addCancelAction { _ in }
            present(alert, animated: true, completion: nil)
        }
    }

    private func addNewCGMManager() {
        let availableCGMManagers = deviceManager.availableCGMManagers

        switch availableCGMManagers.count {
        case 1:
            if let availableCGMManager = availableCGMManagers.first {
                addCGMManager(withIdentifier: availableCGMManager.identifier)
            }
        default:
            let alert = UIAlertController(availableCGMManagers: availableCGMManagers) { [weak self] identifier in
                self?.addCGMManager(withIdentifier: identifier)
            }
            alert.addCancelAction { _ in }
            present(alert, animated: true, completion: nil)
        }
    }


    // MARK: - Debug Scenarios and Simulated Core Data

    var lastOrientation: UIDeviceOrientation?
    var rotateCount = 0
    let maxRotationsToTrigger = 6
    var rotateTimer: Timer?
    let rotateTimerTimeout = TimeInterval.seconds(2)
    private func maybeOpenDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }
        // Opens the debug menu if you rotate the phone 6 times (or back & forth 3 times), each rotation within 2 secs.
        if lastOrientation != UIDevice.current.orientation {
            if UIDevice.current.orientation == .portrait && rotateCount >= maxRotationsToTrigger-1 {
                presentDebugMenu()
                rotateCount = 0
                rotateTimer?.invalidate()
                rotateTimer = nil
            } else {
                rotateTimer?.invalidate()
                rotateTimer = Timer.scheduledTimer(withTimeInterval: rotateTimerTimeout, repeats: false) { [weak self] _ in
                    self?.rotateCount = 0
                    self?.rotateTimer?.invalidate()
                    self?.rotateTimer = nil
                }
                rotateCount += 1
            }
        }
        lastOrientation = UIDevice.current.orientation
    }

    private func presentDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }

        let actionSheet = UIAlertController(title: "Debug", message: nil, preferredStyle: .actionSheet)
        if FeatureFlags.scenariosEnabled {
            actionSheet.addAction(UIAlertAction(title: "Scenarios", style: .default) { _ in
                DispatchQueue.main.async {
                    self.presentScenarioSelector()
                }
            })
        }
        if FeatureFlags.simulatedCoreDataEnabled {
            actionSheet.addAction(UIAlertAction(title: "Simulated Core Data", style: .default) { _ in
                self.presentSimulatedCoreDataMenu()
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Remove Exports Directory", style: .default) { _ in
            if let error = self.deviceManager.removeExportsDirectory() {
                self.presentError(error)
            }
        })
        if FeatureFlags.mockTherapySettingsEnabled {
            actionSheet.addAction(UIAlertAction(title: "Mock Therapy Settings", style: .default) { _ in
                let therapySettings = TherapySettings.mockTherapySettings
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.glucoseTargetRangeSchedule = therapySettings.glucoseTargetRangeSchedule
                    settings.preMealTargetRange = therapySettings.correctionRangeOverrides?.preMeal
                    settings.legacyWorkoutTargetRange = therapySettings.correctionRangeOverrides?.workout
                    settings.suspendThreshold = therapySettings.suspendThreshold
                    settings.maximumBolus = therapySettings.maximumBolus
                    settings.maximumBasalRatePerHour = therapySettings.maximumBasalRatePerHour
                    settings.insulinSensitivitySchedule = therapySettings.insulinSensitivitySchedule
                    settings.carbRatioSchedule = therapySettings.carbRatioSchedule
                    settings.basalRateSchedule = therapySettings.basalRateSchedule
                    settings.defaultRapidActingModel = therapySettings.defaultRapidActingModel
                }
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Crash the App", style: .destructive) { _ in
            fatalError("Test Crash")
        })
        actionSheet.addAction(UIAlertAction(title: "Delete CGM Manager", style: .destructive) { _ in
            self.deviceManager.cgmManager?.delete() { }
        })

        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentScenarioSelector() {
        guard FeatureFlags.scenariosEnabled else {
            fatalError("\(#function) should be invoked only when scenarios are enabled")
        }

        let vc = TestingScenariosTableViewController(scenariosManager: testingScenariosManager)
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func addScenarioStepGestureRecognizers() {
        if FeatureFlags.scenariosEnabled {
            let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioForward))
            leftSwipe.direction = .left
            let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioBackward))
            rightSwipe.direction = .right

            if let toolBar = navigationController?.toolbar {
                toolBar.addGestureRecognizer(leftSwipe)
                toolBar.addGestureRecognizer(rightSwipe)
            }
        }
    }

    private func presentSimulatedCoreDataMenu() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        let actionSheet = UIAlertController(title: "Simulated Core Data", message: nil, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: "Generate Simulated Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged before generating new simulated historical Core Data. Are you sure?", actionTitle: "Generate Simulated Historical") {
                self.generateSimulatedHistoricalCoreData()
            }
        })
        actionSheet.addAction(UIAlertAction(title: "Purge Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged. Are you sure?", actionTitle: "Purge Historical") {
                self.purgeHistoricalCoreData()
            }
        })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func generateSimulatedHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Generating simulated historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    if let error = error {
                        dismissActivityIndicator()
                        self.presentError(error)
                        return
                    }

                    self.deviceManager.generateSimulatedHistoricalCoreData() { error in
                        DispatchQueue.main.async {
                            dismissActivityIndicator()
                            if let error = error {
                                self.presentError(error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func purgeHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Purging historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    dismissActivityIndicator()
                    if let error = error {
                        self.presentError(error)
                    }
                }
            }
        }
    }

    private func presentConfirmation(actionSheetMessage: String, actionTitle: String, handler: @escaping () -> Void) {
        let actionSheet = UIAlertController(title: nil, message: actionSheetMessage, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in handler() })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentError(_ error: Error, handler: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Error", message: "An error occurred: \(String(describing: error))", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in handler?() })
        present(alert, animated: true)
    }

    private func presentActivityIndicator(title: String, message: String, completion: @escaping (@escaping () -> Void) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addActivityIndicator()
        present(alert, animated: true) { completion { alert.dismiss(animated: true) } }
    }

    @objc private func stepActiveScenarioForward() {
        testingScenariosManager.stepActiveScenarioForward { _ in }
    }

    @objc private func stepActiveScenarioBackward() {
        testingScenariosManager.stepActiveScenarioBackward { _ in }
    }
}

extension UIAlertController {
    func addActivityIndicator() {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let activityIndicator = UIActivityIndicatorView(frame: frame)
        activityIndicator.style = .default
        activityIndicator.startAnimating()
        let viewController = UIViewController()
        viewController.preferredContentSize = frame.size
        viewController.view.addSubview(activityIndicator)
        setValue(viewController, forKey: "contentViewController")
    }
}

extension StatusTableViewController: CompletionDelegate {
    func completionNotifyingDidComplete(_ object: CompletionNotifying) {
        if let vc = object as? UIViewController {
            if presentedViewController === vc {
                dismiss(animated: true, completion: nil)
            } else {
                vc.dismiss(animated: true, completion: nil)
            }
        }
    }
}

extension StatusTableViewController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        dispatchPrecondition(condition: .onQueue(.main))
        log.default("PumpManager:%{public}@ did update status", String(describing: type(of: pumpManager)))

        basalDeliveryState = status.basalDeliveryState
        bolusState = status.bolusState

        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: CGMManagerStatusObserver {
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {

        updateBolusProgress()

        if doseProgressReporter.progress.isComplete {
            // Bolus ended
            self.bolusProgressReporter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self.bolusState = .noBolus
                self.reloadData(animated: true)
            })
        }
    }
}

extension StatusTableViewController: OverrideSelectionViewControllerDelegate {
    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didUpdatePresets presets: [TemporaryScheduleOverridePreset]) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.overridePresets = presets
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmPreset preset: TemporaryScheduleOverridePreset) {
        let intent = EnableOverridePresetIntent()
        intent.overrideName = preset.name

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = preset.id.uuidString
        interaction.groupIdentifier = preset.name
        interaction.donate { (error) in
            if let error = error {
                os_log(.error, "Failed to donate intent: %{public}@", String(describing: error))
            }
        }
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = preset.createOverride(enactTrigger: .local)
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController: AddEditOverrideTableViewControllerDelegate {
    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didSaveOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController {
    fileprivate func addCGMManager(withIdentifier identifier: String) {
        switch deviceManager.setupCGMManager(withIdentifier: identifier) {
        case .failure(let error):
            log.error("Failure to setup CGM manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.cgmManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("CGM manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController {
    fileprivate func addPumpManager(withIdentifier identifier: String) {
        guard let maximumBasalRate = deviceManager.loopManager.settings.maximumBasalRatePerHour,
              let maxBolus = deviceManager.loopManager.settings.maximumBolus,
              let basalSchedule = deviceManager.loopManager.settings.basalRateSchedule else
        {
            log.error("Failure to setup pump manager: incomplete settings")
            return
        }
        
        let settings = PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maximumBasalRate,
                                                maxBolusUnits: maxBolus,
                                                basalSchedule: basalSchedule)
        switch deviceManager.setupPumpManagerUI(withIdentifier: identifier, initialSettings: settings) {
        case .failure(let error):
            log.error("Failure to setup pump manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.pumpManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Pump manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController: BluetoothObserver {
    func bluetoothDidUpdateState(_ state: BluetoothState) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

// MARK: - SettingsViewModel delegation
extension StatusTableViewController: SettingsViewModelDelegate {
    var closedLoopDescriptiveText: String? {
        return deviceManager.closedLoopDisallowedLocalizedDescription
    }

    func dosingEnabledChanged(_ value: Bool) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.dosingEnabled = value
        }
    }
    
    func dosingStrategyChanged(_ strategy: AutomaticDosingStrategy) {
        self.deviceManager.loopManager.mutateSettings { settings in
            settings.automaticDosingStrategy = strategy
        }
    }

    func didTapIssueReport() {
        // TODO: this dismiss here is temporary, until we know exactly where
        // we want this screen to belong in the navigation flow
        dismiss(animated: true) {
            let vc = CommandResponseViewController.generateDiagnosticReport(deviceManager: self.deviceManager)
            vc.title = NSLocalizedString("Issue Report", comment: "The view controller title for the issue report screen")
            self.show(vc, sender: nil)
        }
    }
}

// MARK: - Services delegation

extension StatusTableViewController: ServicesViewModelDelegate {
    func addService(withIdentifier identifier: String) {
        switch deviceManager.servicesManager.setupService(withIdentifier: identifier) {
        case .failure(let error):
            log.default("Failure to setup service with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.serviceOnboardingDelegate = deviceManager.servicesManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Service with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }

    func gotoService(withIdentifier identifier: String) {
        guard let serviceUI = deviceManager.servicesManager.activeServices.first(where: { $0.pluginIdentifier == identifier }) as? ServiceUI else {
            return
        }
        showServiceSettings(serviceUI)
    }

    fileprivate func showServiceSettings(_ serviceUI: ServiceUI) {
        var settingsViewController = serviceUI.settingsViewController(colorPalette: .default)
        settingsViewController.serviceOnboardingDelegate = deviceManager.servicesManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }
}
