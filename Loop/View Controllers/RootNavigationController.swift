//
//  RootNavigationController.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit
import LoopKitUI

/// A toolbar that only claims touches landing on an actual control.
///
/// On iOS 26 the toolbar draws its items as a floating glass capsule that is
/// far narrower than the bar itself, but the bar's *view* still spans the full
/// width and the full height above the home indicator. By default it swallowed
/// every touch in that empty region, so the charts could not be scrolled or
/// tapped beside or below the capsule.
///
/// Installed via `customClass` on the toolbar in `Main.storyboard` — a
/// storyboard-instantiated `UINavigationController` uses `init(coder:)`, which
/// gives no opportunity to pass a `toolbarClass`.
final class PassthroughToolbar: UIToolbar {
    /// Extra height added to the bar, on top of the system's own.
    ///
    /// This is the OTHER half of making the bottom bar bigger. The glass capsule
    /// is laid out inside the bar's height, so growing the bar grows the capsule
    /// — the bar's actual dimensions — while
    /// `StatusTableViewController.toolbarIconScale` grows the icons inside it.
    /// The two are meant to be tuned TOGETHER so the bar scales as one piece
    /// rather than icons rattling around in a bar that stayed the same size.
    ///
    /// Height is the only thing overridden: no appearance, no item classes, so
    /// the shared Liquid Glass is untouched (see DESIGN_SYSTEM.md).
    static let extraHeight: CGFloat = 14

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var fitted = super.sizeThatFits(size)
        fitted.height += Self.extraHeight
        return fitted
    }

    // NOTE: `intrinsicContentSize` is deliberately NOT overridden. Adding height
    // there as well fed the toolbar's own measurement back into Auto Layout and
    // risked a layout loop — which shows up as an intermittent crash, not a
    // visible glitch. `sizeThatFits` alone is the supported way to resize a
    // navigation controller's toolbar.

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }

        // Walk up from the hit view: a real bar button (including the custom
        // meal button) is, or lives inside, a UIControl. Anything else is the
        // bar's own background/glass, which should let the touch fall through
        // to the scrolling content underneath.
        var view: UIView? = hit
        while let current = view, current !== self {
            if current is UIControl { return hit }
            view = current.superview
        }
        return nil
    }
}

/// The root view controller in Loop
class RootNavigationController: UINavigationController {

    /// Its root view controller is always StatusTableViewController after loading
    var statusTableViewController: StatusTableViewController! {
        return viewControllers.first as? StatusTableViewController
    }
    
    func navigate(to deeplink: Deeplink) {
        switch deeplink {
        case .carbEntry:
            statusTableViewController.presentCarbEntryScreen(nil)
        case .preMeal:
            statusTableViewController.togglePreMealMode()
        case .bolus:
            statusTableViewController.presentBolusScreen()
        case .customPresets:
            statusTableViewController.presentCustomPresets()
        }
    }

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.viewLoopStatusActivityType:
            // Keep an in-progress carb/meal entry alive: a "view status"
            // continuation (fires when the app returns to the foreground, e.g.
            // Handoff from the watch) must not tear down what the user is typing.
            if presentedViewController != nil,
               presentedViewController?.view.accessibilityIdentifier != StatusTableViewController.mealEntryScreenIdentifier {
                dismiss(animated: false, completion: nil)
            }

            if viewControllers.count > 1 {
                popToRootViewController(animated: false)
            }
        default:
            statusTableViewController.restoreUserActivityState(activity)
        }
    }

}
