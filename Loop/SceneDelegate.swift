//
//  SceneDelegate.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit

/// Owns only the window and UI-side lifecycle. Managers are launched by
/// `AppDelegate` so background launches without a scene keep working.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let log = DiagnosticLog(category: "SceneDelegate")

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }

    // MARK: - UIWindowSceneDelegate - Life Cycle

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        log.default(#function)

        guard let windowScene = scene as? UIWindowScene, let appDelegate else { return }

        // The Info.plist scene configuration names Main.storyboard, so UIKit has
        // already created the window and its RootNavigationController.
        if window == nil {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
            self.window = window
            window.makeKeyAndVisible()
        }

        // iOS can discard a background scene and connect a fresh one later. The
        // launched home screen lives on the previous window, so carry it over
        // instead of showing the storyboard's empty navigation controller.
        if let window, let previousRoot = appDelegate.window?.rootViewController, previousRoot !== window.rootViewController {
            window.rootViewController = previousRoot
        }

        appDelegate.window = window
        appDelegate.loopAppManager.windowDidBecomeAvailable()

        if let url = connectionOptions.urlContexts.first?.url {
            _ = appDelegate.loopAppManager.handle(url)
        }

        for userActivity in connectionOptions.userActivities {
            restore(userActivity, with: appDelegate.loopAppManager)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        log.default(#function)

        appDelegate?.loopAppManager.didBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        log.default(#function)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        log.default(#function)

        // Matches the old applicationWillEnterForeground, which never fired during
        // a cold launch; the launch sequence asks on its own once the UI is up.
        guard let loopAppManager = appDelegate?.loopAppManager, loopAppManager.isLaunchComplete else { return }
        loopAppManager.askUserToConfirmLoopReset()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        log.default(#function)
    }

    // MARK: - UIWindowSceneDelegate - Deeplinking

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        _ = appDelegate?.loopAppManager.handle(url)
    }

    // MARK: - UIWindowSceneDelegate - Continuity

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        log.default(#function)

        guard let loopAppManager = appDelegate?.loopAppManager else { return }
        restore(userActivity, with: loopAppManager)
    }

    private func restore(_ userActivity: NSUserActivity, with loopAppManager: LoopAppManager) {
        // UIApplicationDelegate used to call restoreUserActivityState on whatever the
        // restoration handler returned; scenes have no handler, so do it here.
        _ = loopAppManager.userActivity(userActivity) { objects in
            objects?.forEach { $0.restoreUserActivityState(userActivity) }
        }
    }
}
