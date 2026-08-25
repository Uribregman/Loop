//
//  LoopSoundVendor.swift
//  Loop
//
//  Exposes the bundled custom-alert tones (Loop/CustomAlertSounds/*.caf) to the
//  AlertManager sound pipeline under the "Loop" manager identifier, so custom
//  alerts (see CustomAlertMonitor) can play them as notification sounds.
//
//  NOTE: the Dexcom-derived tones are bundled for personal self-built use only.
//  See Loop/CustomAlertSounds/DEXCOM_SOUNDS_LICENSE.md.
//

import Foundation
import AVFoundation
import AudioToolbox
import LoopKit

/// Provides the bundled .caf sound files to `AlertManager`, which copies them
/// into its sounds directory as `Loop-<filename>` for notification playback.
final class LoopSoundVendor: AlertSoundVendor {
    func getSoundBaseURL() -> URL? {
        // Resource files added to the app target land at the bundle root.
        Bundle.main.resourceURL
    }

    func getSounds() -> [Alert.Sound] {
        AlertSoundChoice.bundledFilenames.map { .sound(name: $0) }
    }
}

/// Plays a custom alert's sound WHILE THE APP IS IN THE FOREGROUND.
///
/// Why this exists: a foreground alert used to arrive completely silent. The
/// in-app modal (`InAppModalAlertScheduler`) has never played anything — it just
/// puts a `UIAlertController` on screen — so the only sound was the user
/// notification's, and that one is at the mercy of the ringer switch. A glucose
/// alarm you cannot hear because the phone is face-down on silent is not an
/// alarm.
///
/// So for alerts raised by `CustomAlertMonitor` (manager identifier "Loop", the
/// user's own high/low/rate/trend alarms) the app plays the tone itself, through
/// an `AVAudioSession` in the `.playback` category — the one category that
/// sounds through the silent switch. `LoopAppManager.userNotificationCenter(_:
/// willPresent:)` drops `.sound` for exactly these alerts so nothing doubles up.
///
/// Deliberately NOT applied to pump/CGM plugin alerts: those keep the behaviour
/// they have always had.
final class AlertAudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AlertAudioPlayer()

    /// True for alerts raised by `CustomAlertMonitor`, the only ones this plays.
    static func isCustomLoopAlert(managerIdentifier: String) -> Bool {
        managerIdentifier == CustomAlertMonitor.managerIdentifier
    }

    private var player: AVAudioPlayer?

    /// Play `alert`'s sound. No-op for alerts from other managers.
    func play(_ alert: Alert) {
        guard Self.isCustomLoopAlert(managerIdentifier: alert.identifier.managerIdentifier) else { return }

        switch alert.sound {
        case .vibrate:
            vibrate()
        case .sound:
            // The file the notification pipeline already copied into
            // Library/Sounds, so the modal and the banner play the same tone.
            guard let url = AlertManager.soundURL(for: alert) else { return vibrate() }
            play(url: url)
        case .none:
            // "iOS Default Tone": there is no file to play, so use the system
            // alert sound plus a haptic. This one does respect the silent
            // switch — a user who wants an alarm through silent picks a tone.
            AudioServicesPlayAlertSound(1007)
        }
    }

    private func play(url: URL) {
        do {
            // `.playback` is what sounds through the ringer switch.
            // `.duckOthers` lowers music rather than stopping it.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.player = player
            player.play()
        } catch {
            // An alarm that cannot play its tone must still be felt.
            vibrate()
            deactivateSession()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        deactivateSession()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        deactivateSession()
    }

    /// Hand the audio session back when the tone has finished.
    ///
    /// ⚠️ NOT OPTIONAL TIDYING. `.duckOthers` stays in force for as long as this
    /// session is active, so without this one alert would leave the user's music
    /// or podcast quietened for the rest of the app's life.
    /// `.notifyOthersOnDeactivation` is what tells the other app to come back up.
    private func deactivateSession() {
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func vibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

/// Plays a short in-app preview of an alert sound (for the settings picker).
/// Non-file choices (Default / Vibrate) are no-ops for preview.
final class AlertSoundPreviewPlayer {
    static let shared = AlertSoundPreviewPlayer()
    private var player: AVAudioPlayer?

    func play(_ choice: AlertSoundChoice) {
        guard let name = choice.bundledResourceName,
              let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return }
        // Deliberately does NOT change the shared AVAudioSession category — mutating
        // it could affect how real alert sounds play afterward. Preview uses whatever
        // session Loop already has configured.
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            // Preview is best-effort; ignore playback errors.
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
