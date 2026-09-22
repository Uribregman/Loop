//
//  StatsLiveReport.swift
//  Loop
//
//  Keeps ONE HTML file on disk up to date, so a report that has already been
//  shared keeps showing current numbers instead of the day it was sent.
//
//  ── WHAT "AUTO-UPDATING" HONESTLY MEANS HERE ────────────────────────────────
//  There is no server. Nothing is uploaded anywhere, nothing is hosted, and no
//  third party ever holds this data. What this does is REWRITE a file in the
//  same iCloud Drive folder the history log lives in. If the patient shares that
//  file (or the folder) from the Files app, whoever opens it sees whatever Loop
//  wrote last — which is the closest thing to "live" that can exist without
//  handing someone's medical data to a service.
//
//  So it updates:
//    • at most once every TWO HOURS, and only while the battery is above 40%,
//    • the moment the battery climbs back above 40% if a refresh was skipped,
//    • and immediately when the patient asks it to, whatever the battery says.
//
//  The battery floor exists because this is a background convenience running on
//  the phone that drives an insulin pump. Nothing here is worth a percent of the
//  charge that pump depends on, so below 40% it simply stops and says so.
//
//  It does NOT update while the phone is asleep in a drawer. That limitation is
//  printed in the page itself, next to the timestamp — see `LiveInfo`. A page
//  that looks live while showing three-day-old glucose data is worse than one
//  that is obviously a snapshot, and this is medical data being read by someone
//  who is probably worried.
//
//  ⚠️ WRITE-ONLY, AND NOWHERE NEAR THE ALGORITHM. This reads the history log and
//  writes one HTML file. It reads no algorithm state, mutates nothing, holds no
//  locks anything else waits on, and never runs on the main thread. It cannot
//  affect dosing, and nothing added here ever should.
//

import Foundation
import LoopCore
import UIKit
import os.log

@MainActor
final class StatsLiveReport: ObservableObject {

    static let shared = StatsLiveReport()

    private let log = OSLog(category: "StatsLiveReport")

    /// The one file. A FIXED name, deliberately: the whole feature depends on the
    /// URL staying the same, because a share link or a bookmark points at a
    /// specific file. A timestamped name would produce a new, unshared file every
    /// refresh — which is the opposite of what this is for.
    static let fileName = "Loop Statistics.html"

    /// Floor between automatic refreshes. Each one runs the statistics pass six
    /// times, so this is not free.
    static let minimumInterval: TimeInterval = 2 * 60 * 60

    /// Below this the report does not refresh at all.
    ///
    /// ⚠️ THE POINT IS THE PUMP, NOT THE PHONE. This app keeps someone alive by
    /// talking to an insulin pump over Bluetooth all day. A statistics file that
    /// nobody is currently looking at does not get to spend the battery that
    /// delivery depends on. 40% is where a phone stops being comfortably fine and
    /// starts being something you think about.
    static let batteryFloor: Float = 0.40

    /// How often to look while Loop is in the foreground for a long stretch.
    ///
    /// `didBecomeActive` alone would mean a phone left open on the charger never
    /// updated at all — the promise is "every two hours", so something has to
    /// actually tick. `refresh()` throttles itself, so this is a cheap poll of a
    /// timestamp, not a rebuild.
    private static let pollInterval: TimeInterval = 20 * 60

    /// How often an already-open browser tab reloads itself.
    static let browserReloadSeconds = 600

    private static let enabledKey = "com.loopkit.Loop.statsLiveReportEnabled"
    private static let lastWrittenKey = "com.loopkit.Loop.statsLiveReportLastWritten"
    private static let isfKey = "com.loopkit.Loop.statsLiveReportISF"
    private static let ratioKey = "com.loopkit.Loop.statsLiveReportCarbRatio"
    private static let basalKey = "com.loopkit.Loop.statsLiveReportBasal"

    /// Opt-in, like the history log itself. Nothing is written until the patient
    /// turns it on.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                refresh(force: true)
            } else {
                // Turning it OFF deletes the file. Leaving a stale report behind
                // under a name that promises to be live is exactly the failure
                // this whole file is written to avoid — and the patient may well
                // be switching it off because they no longer want it read.
                removeFile()
            }
        }
    }

    @Published private(set) var lastWritten: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    /// True when a refresh was due and the battery is what stopped it. Drives the
    /// one line in the UI that explains why nothing is happening — a feature that
    /// silently does nothing is indistinguishable from a broken one.
    @Published private(set) var isWaitingForBattery = false

    private var hasStarted = false
    private var pollTimer: Timer?

    /// No automatic refresh before this: the first one parses the whole history
    /// log, and doing that while the app is still launching slows the launch down.
    private static let launchDelay: TimeInterval = 30
    private var automaticRefreshNotBefore: Date?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let stamp = UserDefaults.standard.double(forKey: Self.lastWrittenKey)
        lastWritten = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: - Lifecycle

    /// Begin keeping the file current. Safe to call repeatedly.
    ///
    /// ⚠️ Called from `StatusTableViewController.viewDidLoad`, which runs ONCE
    /// per launch and is not on the startup critical path. It is deliberately NOT
    /// wired into `LoopAppManager`'s launch sequence: the last time this fork's
    /// startup path was reorganised it cost skipped CGM readings (STEP BB), and
    /// a statistics convenience has no business anywhere near it.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Required before `batteryLevel` returns anything but -1. Harmless and
        // free — it is a property read, not a subscription to anything costly —
        // and Loop already cares about the battery elsewhere.
        UIDevice.current.isBatteryMonitoringEnabled = true

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // The moment the charge comes back. iOS posts this about every 1%, so a
        // phone put on a charger with a report waiting picks it up within a
        // minute or two rather than at the next two-hour boundary.
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWaitingForBattery, self.hasEnoughBattery else { return }
                self.refresh()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        automaticRefreshNotBefore = Date().addingTimeInterval(Self.launchDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Whether there is enough charge to spend on this.
    ///
    /// ⚠️ UNKNOWN COUNTS AS ENOUGH. `batteryLevel` returns -1 when iOS will not
    /// say — a simulator, or monitoring not yet up. Blocking a feature on a fact
    /// the system refuses to provide would mean it silently never works on those
    /// devices, which is a worse failure than spending a little charge.
    var hasEnoughBattery: Bool {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return true }
        // Plugged in is plugged in: the floor is about draining someone's phone,
        // and a charging phone is not being drained.
        if UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full {
            return true
        }
        return level > Self.batteryFloor
    }

    /// Remember the therapy settings the statistics screen was given, so a
    /// refresh that happens with no screen open can still say what the current
    /// settings are.
    ///
    /// Persisted rather than held in memory because the first refresh of a launch
    /// happens before anyone opens the statistics screen. Three numbers the user
    /// already sees on their own settings screens — nothing sensitive is being
    /// introduced to `UserDefaults` here.
    func rememberSettings(currentISF: Double?, currentCarbRatio: Double?, scheduledBasalPerDay: Double?) {
        let defaults = UserDefaults.standard
        if let currentISF { defaults.set(currentISF, forKey: Self.isfKey) }
        if let currentCarbRatio { defaults.set(currentCarbRatio, forKey: Self.ratioKey) }
        if let scheduledBasalPerDay { defaults.set(scheduledBasalPerDay, forKey: Self.basalKey) }
    }

    // MARK: - The file

    /// Where the report is written, when there is anywhere to write it.
    ///
    /// Same folder as the history log — see `HistoryLogStore.directory`.
    var fileURL: URL? {
        HistoryLogStore.shared.directory?.appendingPathComponent(Self.fileName)
    }

    /// True when the folder is the real iCloud Drive one rather than the app's
    /// private Documents. The distinction matters to the user: only the first can
    /// be opened from another device.
    var isInICloud: Bool { HistoryLogStore.shared.location == .iCloud }

    private func removeFile() {
        guard let url = fileURL else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
        lastWritten = nil
        UserDefaults.standard.removeObject(forKey: Self.lastWrittenKey)
    }

    // MARK: - Refresh

    /// Rewrite the file, subject to the interval unless forced.
    func refresh(force: Bool = false) {
        guard isEnabled, !isRefreshing else { return }
        // The didBecomeActive that every launch posts lands here too; the delayed call in `start()` covers it.
        if !force, let notBefore = automaticRefreshNotBefore, Date() < notBefore { return }
        guard let url = fileURL else {
            lastError = NSLocalizedString("No folder to write to. Turn on the history log first.",
                                          comment: "Live report has nowhere to write")
            return
        }

        // ⚠️ THE THROTTLE ONLY APPLIES WHEN THE FILE IS ACTUALLY THERE. Someone
        // who deletes the report from the Files app and comes back to Loop
        // expects it to return; without this check the timestamp says it was
        // written fifteen minutes ago, so nothing happens, and the feature looks
        // broken for a quarter of an hour. The stamp records the last WRITE, not
        // the file's existence, and those are not the same fact.
        if !force,
           let lastWritten,
           Date().timeIntervalSince(lastWritten) < Self.minimumInterval,
           FileManager.default.fileExists(atPath: url.path) {
            return
        }

        // ⚠️ CHECKED AFTER THE INTERVAL, NOT BEFORE, AND THAT ORDER MATTERS.
        // `isWaitingForBattery` must mean "a refresh is DUE and the battery is
        // holding it up" — if it were set on every call it would be true all the
        // time on a low phone, including the 119 minutes when nothing was due
        // anyway, and the UI would blame the battery for a wait it did not cause.
        guard force || hasEnoughBattery else {
            isWaitingForBattery = true
            return
        }
        isWaitingForBattery = false

        isRefreshing = true
        lastError = nil
        let defaults = UserDefaults.standard
        let isf = defaults.object(forKey: Self.isfKey) as? Double
        let ratio = defaults.object(forKey: Self.ratioKey) as? Double
        let basal = defaults.object(forKey: Self.basalKey) as? Double

        Task { [weak self] in
            let outcome = await Self.write(to: url, currentISF: isf, currentCarbRatio: ratio,
                                           scheduledBasalPerDay: basal)
            guard let self else { return }
            self.isRefreshing = false
            switch outcome {
            case .success(let date):
                self.lastWritten = date
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastWrittenKey)
            case .failure(let message):
                self.lastError = message
                os_log("Live report failed: %{public}@", log: self.log, type: .error, message)
            }
        }
    }

    private enum Outcome {
        case success(Date)
        case failure(String)
    }

    /// All of the work, off the main thread and with no reference to `self`.
    private nonisolated static func write(to url: URL,
                                          currentISF: Double?,
                                          currentCarbRatio: Double?,
                                          scheduledBasalPerDay: Double?) async -> Outcome {
        let files = await withCheckedContinuation { continuation in
            HistoryLogStore.shared.loadFiles { continuation.resume(returning: $0) }
        }
        let urls = files.map(\.url)

        // ⚠️ EVERYTHING FROM HERE IS INSIDE THE DETACHED TASK, INCLUDING THE LOG
        // PARSE. `loadFiles` delivers its completion on the MAIN queue, so code
        // written after that `await` resumes on the main actor — parsing months
        // of JSONL there froze the UI for as long as it took, on every launch,
        // for a feature the user is not even looking at. The parse belongs on the
        // background task with the rest of the work.
        return await Task.detached(priority: .utility) {
            let lines = HistoryLogReader.read(files: urls)
            guard !lines.isEmpty else {
                return Outcome.failure(NSLocalizedString("There is no history to report on yet.",
                                                         comment: "Live report has no data"))
            }
            let insights = TherapyInsights.compute(from: lines,
                                                   currentISF: currentISF,
                                                   currentCarbRatio: currentCarbRatio)
            let weekly = HistoryStatistics.periodSummary(from: lines, granularity: .week)
            let monthly = HistoryStatistics.periodSummary(from: lines, granularity: .month)

            // ⚠️ THE SAME function the screen uses — see the note on it. A second
            // implementation of the calendar-day windowing would drift, and this
            // file's entire promise is that it mirrors the screen.
            let models = HistoryStatisticsViewModel.Period.allCases.map { period -> (id: String, title: String, longTitle: String, model: StatsReportModel) in
                let result = HistoryStatisticsViewModel.statistics(
                    for: lines, days: period.days, scheduledBasalPerDay: scheduledBasalPerDay)
                let model = StatsReportModel.build(
                    stats: result.current,
                    insights: insights,
                    weeklyComparison: weekly,
                    monthlyComparison: monthly,
                    observations: HistoryStatisticsView.observations(for: result.current),
                    periodTitle: period.title,
                    periodLongTitle: period.longTitle)
                return (id: period.rawValue, title: period.title, longTitle: period.longTitle, model: model)
            }

            let now = Date()
            let html = StatsHTMLReport.full(
                models: models,
                weeklyComparison: weekly,
                monthlyComparison: monthly,
                selected: HistoryStatisticsViewModel.Period.month.rawValue,
                generated: now,
                live: .init(reloadSeconds: StatsLiveReport.browserReloadSeconds))

            do {
                // Atomic: a reader opening the file mid-write must never get half
                // a report. On iCloud that also gives the coordinator a complete
                // file to upload rather than a growing one.
                try Data(html.utf8).write(to: url, options: .atomic)
                return .success(now)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}
