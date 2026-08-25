//
//  CarbAbsorptionViewController.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopUI
import os.log


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.glucose, .carbs, .status]
}


final class CarbAbsorptionViewController: LoopChartsTableViewController, IdentifiableClass {

    private let log = OSLog(category: "StatusTableViewController")
    
    private var allowEditing: Bool = true

    var isOnboardingComplete: Bool = true

    var automaticDosingStatus: AutomaticDosingStatus!

    override func viewDidLoad() {
        super.viewDidLoad()

        self.tableView.allowsSelectionDuringEditing = true

        // Entries / Meals history mode toggle in the nav bar.
        navigationItem.titleView = modeSelector
        tableView.register(MealSummaryCell.self, forCellReuseIdentifier: MealSummaryCell.className)

        carbEffectChart.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBound

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let context = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                DispatchQueue.main.async {
                    switch LoopDataManager.LoopUpdateContext(rawValue: context) {
                    case .carbs?:
                        self?.refreshContext.formUnion([.carbs, .glucose])
                    case .glucose?:
                        self?.refreshContext.update(with: .glucose)
                    default:
                        break
                    }

                    self?.refreshContext.update(with: .status)
                    self?.reloadData(animated: true)
                }
            },
        ]

        if let gestureRecognizer = charts.gestureRecognizer {
            tableView.addGestureRecognizer(gestureRecognizer)
        }

        navigationItem.rightBarButtonItem?.isEnabled = isOnboardingComplete
        
        allowEditing = automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled

        if allowEditing {
            navigationItem.rightBarButtonItems?.append(editButtonItem)
        }

        tableView.rowHeight = UITableView.automaticDimension
        // Plain list: one hairline between entries, inset to the text, and no
        // shaded panel behind anything.
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.backgroundColor = .systemBackground

        reloadData(animated: false)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext = RefreshContext.all
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    private var refreshContext = RefreshContext.all

    private var reloading = false

    private var carbStatuses: [CarbStatus<StoredCarbEntry>] = []

    // MARK: - History display mode (per-entry vs. grouped by meal)

    private enum HistoryMode: Int { case entries, meals }
    private var historyMode: HistoryMode = .entries

    /// Groups `carbStatuses` into meals using SAVED meal metadata as the source of
    /// truth — an entry belongs to the meal it was saved with, so unrelated entries
    /// are never mixed together. Entries with no matching meal are shown on their own.
    private var meals: [[CarbStatus<StoredCarbEntry>]] {
        let sorted = carbStatuses.sorted { $0.entry.startDate > $1.entry.startDate }
        let tolerance: TimeInterval = 60
        var claimed = [Bool](repeating: false, count: sorted.count)
        var groups: [[CarbStatus<StoredCarbEntry>]] = []

        // Claim entries for each saved meal by matching their start times.
        for meta in MealMetadataStore.all() {
            var group: [CarbStatus<StoredCarbEntry>] = []
            for (i, status) in sorted.enumerated() where !claimed[i] {
                if meta.componentStartDates.contains(where: { abs($0.timeIntervalSince(status.entry.startDate)) <= tolerance }) {
                    claimed[i] = true
                    group.append(status)
                }
            }
            if !group.isEmpty { groups.append(group) }
        }

        // Everything else stays as its own single-entry card (never mixed).
        for (i, status) in sorted.enumerated() where !claimed[i] {
            groups.append([status])
        }

        groups.sort {
            ($0.map { $0.entry.startDate }.min() ?? .distantPast) >
            ($1.map { $0.entry.startDate }.min() ?? .distantPast)
        }
        return groups
    }

    private var carbsOnBoard: CarbValue?

    private var carbTotal: CarbValue?

    // MARK: - Data loading

    private let carbEffectChart = CarbEffectChart()

    override func createChartsManager() -> ChartsManager {
        return ChartsManager(colors: .primary, settings: .default, charts: [carbEffectChart], traitCollection: traitCollection)
    }

    override func glucoseUnitDidChange() {
        self.log.debug("[reloadData] for HealthKit unit preference change")
        refreshContext = RefreshContext.all
    }

    override func reloadData(animated: Bool = false) {
        guard active && !reloading && !self.refreshContext.isEmpty else { return }
        var currentContext = self.refreshContext
        var retryContext: Set<RefreshContext> = []
        self.refreshContext = []
        reloading = true

        // How far back should we show data? Use the screen size as a guide.
        let minimumSegmentWidth: CGFloat = 75

        let size = currentContext.newSize ?? self.tableView.bounds.size
        let availableWidth = size.width - self.charts.fixedHorizontalMargin
        let totalHours = floor(Double(availableWidth / minimumSegmentWidth))

        var components = DateComponents()
        components.minute = 0
        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: max(1, totalHours)))
        let chartStartDate = Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .strict, direction: .backward) ?? date
        if charts.startDate != chartStartDate {
            currentContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.updateEndDate(chartStartDate.addingTimeInterval(.hours(totalHours+1))) // When there is no data, this allows presenting current hour + 1

        let midnight = Calendar.current.startOfDay(for: Date())
        let listStart = min(midnight, chartStartDate, Date(timeIntervalSinceNow: -deviceManager.carbStore.maximumAbsorptionTimeInterval))

        let reloadGroup = DispatchGroup()
        let shouldUpdateGlucose = currentContext.contains(.glucose)
        let shouldUpdateCarbs = currentContext.contains(.carbs)

        var carbEffects: [GlucoseEffect]?
        var carbStatuses: [CarbStatus<StoredCarbEntry>]?
        var carbsOnBoard: CarbValue?
        var carbTotal: CarbValue?
        var insulinCounteractionEffects: [GlucoseEffectVelocity]?

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        deviceManager.loopManager.getLoopState { (manager, state) in
            if shouldUpdateGlucose || shouldUpdateCarbs {
                let allInsulinCounteractionEffects = state.insulinCounteractionEffects
                insulinCounteractionEffects = allInsulinCounteractionEffects.filterDateRange(chartStartDate, nil)

                reloadGroup.enter()
                self.deviceManager.carbStore.getCarbStatus(start: listStart, end: nil, effectVelocities: allInsulinCounteractionEffects) { (result) in
                    switch result {
                    case .success(let status):
                        carbStatuses = status
                        carbsOnBoard = status.getClampedCarbsOnBoard()
                    case .failure(let error):
                        self.log.error("CarbStore failed to get carbStatus: %{public}@", String(describing: error))
                        retryContext.update(with: .carbs)
                    }

                    reloadGroup.leave()
                }

                reloadGroup.enter()
                self.deviceManager.carbStore.getGlucoseEffects(start: chartStartDate, end: nil, effectVelocities: allInsulinCounteractionEffects) { (result) in
                    switch result {
                    case .success((_, let effects)):
                        carbEffects = effects
                    case .failure(let error):
                        carbEffects = []
                        self.log.error("CarbStore failed to get glucoseEffects: %{public}@", String(describing: error))
                        retryContext.update(with: .carbs)
                    }
                    reloadGroup.leave()
                }
            }

            reloadGroup.leave()
        }

        if shouldUpdateCarbs {
            reloadGroup.enter()
            deviceManager.carbStore.getTotalCarbs(since: midnight) { (result) in
                switch result {
                case .success(let total):
                    carbTotal = total
                case .failure(let error):
                    self.log.error("CarbStore failed to get total carbs: %{public}@", String(describing: error))
                    retryContext.update(with: .carbs)
                }

                reloadGroup.leave()
            }
        }

        reloadGroup.notify(queue: .main) {
            if let carbEffects = carbEffects {
                self.carbEffectChart.setCarbEffects(carbEffects)
                self.charts.invalidateChart(atIndex: 0)
            }

            if let insulinCounteractionEffects = insulinCounteractionEffects {
                self.carbEffectChart.setInsulinCounteractionEffects(insulinCounteractionEffects)
                self.charts.invalidateChart(atIndex: 0)
            }

            self.charts.prerender()

            for case let cell as ChartTableViewCell in self.tableView.visibleCells {
                cell.reloadChart()
            }

            if shouldUpdateCarbs || shouldUpdateGlucose {
                // Change to descending order for display
                self.carbStatuses = carbStatuses?.reversed() ?? []

                if shouldUpdateCarbs {
                    self.carbTotal = carbTotal
                }

                self.carbsOnBoard = carbsOnBoard

                self.tableView.reloadSections(IndexSet(integer: Section.entries.rawValue), with: .fade)
            }

            if let cell = self.tableView.cellForRow(at: IndexPath(row: 0, section: Section.totals.rawValue)) as? HeaderValuesTableViewCell {
                self.updateCell(cell)
            }

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.reloadData()
            }
        }
    }

    // MARK: - UITableViewDataSource

    private enum Section: Int {
        case charts
        case totals
        case entries

        static let count = 3
    }

    private enum ChartRow: Int {
        case carbEffect

        static let count = 1
    }

    private lazy var carbFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()

    private lazy var absorptionFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.collapsesLargestUnit = true
        formatter.unitsStyle = .abbreviated
        formatter.allowsFractionalUnits = true
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .charts:
            return ChartRow.count
        case .totals:
            return 1
        case .entries:
            return historyMode == .meals ? meals.count : carbStatuses.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell

            switch ChartRow(rawValue: indexPath.row)! {
            case .carbEffect:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.charts.chart(atIndex: 0, frame: frame)?.view
                })
            }

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.setAlpha(alpha: alpha)

            cell.setSubtitleTextColor(color: UIColor.secondaryLabel)

            return cell
        case .totals:
            let cell = tableView.dequeueReusableCell(withIdentifier: HeaderValuesTableViewCell.className, for: indexPath) as! HeaderValuesTableViewCell
            updateCell(cell)

            return cell
        case .entries:
            let unit = HKUnit.gram()

            // Meal mode: a sleek summary card per grouped meal.
            if historyMode == .meals {
                let mealCell = tableView.dequeueReusableCell(withIdentifier: MealSummaryCell.className, for: indexPath) as! MealSummaryCell
                let entries = meals[indexPath.row].map { $0.entry }
                mealCell.configure(
                    entries: entries,
                    metadata: MealMetadataStore.match(entries: entries),
                    timeFormatter: timeFormatter,
                    carbFormatter: carbFormatter
                )
                applyPlainCellBackground(to: mealCell)
                return mealCell
            }

            let cell = tableView.dequeueReusableCell(withIdentifier: CarbEntryTableViewCell.className, for: indexPath) as! CarbEntryTableViewCell
            applyPlainCellBackground(to: cell)

            // Entry value
            let status = carbStatuses[indexPath.row]
            let carbText = carbFormatter.string(from: status.entry.quantity.doubleValue(for: unit), unit: unit.unitString)

            if let carbText = carbText, let foodType = status.entry.foodType {
                cell.valueLabel?.text = String(
                    format: NSLocalizedString("%1$@: %2$@", comment: "Formats (1: carb value) and (2: food type)"),
                    carbText, foodType
                )
            } else {
                cell.valueLabel?.text = carbText
            }

            // Entry time — show the meal time (when known) and the offset time
            // distinctly, so they can't be confused.
            let startTime = timeFormatter.string(from: status.entry.startDate)
            var timeText: String
            // Always show BOTH times; without saved meal metadata the meal time
            // equals the entry's start time.
            let mealTimeText = MealMetadataStore.match(entries: [status.entry])
                .map { timeFormatter.string(from: $0.mealTime) } ?? startTime
            timeText = String(
                format: NSLocalizedString("time: %1$@ · offset: %2$@", comment: "Entries history: (1: meal time) (2: carb offset/start time)"),
                mealTimeText, startTime
            )
            if  let absorptionTime = status.entry.absorptionTime,
                let duration = absorptionFormatter.string(from: absorptionTime)
            {
                timeText += " + \(duration)"
            }
            cell.dateLabel?.text = timeText

            if let absorption = status.absorption {
                // Absorbed value
                let observedProgress = Float(absorption.observedProgress.doubleValue(for: .percent()))
                let observedCarbs = max(0, absorption.observed.doubleValue(for: unit))

                if let observedCarbsText = carbFormatter.string(from: observedCarbs, unit: unit.unitString) {
                    cell.observedValueText = String(
                        format: NSLocalizedString("%@ absorbed", comment: "Formats absorbed carb value"),
                        observedCarbsText
                    )

                    if absorption.isActive {
                        cell.observedValueTextColor = UIColor.carbTintColor
                    } else if 0.9 <= observedProgress && observedProgress <= 1.1 {
                        cell.observedValueTextColor = UIColor.systemGray
                    } else {
                        cell.observedValueTextColor = UIColor.agingColor
                    }
                }

                cell.observedProgress = observedProgress
                cell.clampedProgress = Float(absorption.clampedProgress.doubleValue(for: .percent()))
                cell.observedDateText = absorptionFormatter.string(from: absorption.estimatedDate.duration)

                // Absorbed time
                if absorption.isActive {
                    cell.observedDateTextColor = UIColor.carbTintColor
                } else {
                    cell.observedDateTextColor = UIColor.systemGray

                    if let absorptionTime = status.entry.absorptionTime {
                        let durationProgress = absorption.estimatedDate.duration / absorptionTime
                        if 0.9 > durationProgress || durationProgress > 1.1 {
                            cell.observedDateTextColor = UIColor.agingColor
                        }
                    }
                }
            }
            
            cell.isEditable = allowEditing
            return cell
        }
    }

    private func updateCell(_ cell: HeaderValuesTableViewCell) {
        let unit = HKUnit.gram()

        if let carbsOnBoard = carbsOnBoard, carbsOnBoard.quantity.doubleValue(for: unit) > 0 {
            cell.COBDateLabel.text = String(
                format: NSLocalizedString("at %@", comment: "Format fragment for a specific time"),
                timeFormatter.string(from: carbsOnBoard.startDate)
            )
            cell.COBValueLabel.text = carbFormatter.string(from: carbsOnBoard.quantity.doubleValue(for: unit))

            // Warn the user if the carbsOnBoard value isn't recent
            let textColor: UIColor
            switch carbsOnBoard.startDate.timeIntervalSinceNow {
            case let t where t < .minutes(-30):
                textColor = .staleColor
            case let t where t < .minutes(-15):
                textColor = .agingColor
            default:
                textColor = .secondaryLabel
            }

            cell.COBDateLabel.textColor = textColor
        } else {
            cell.COBDateLabel.text = nil
            cell.COBValueLabel.text = carbFormatter.string(from: 0.0)
        }

        if let carbTotal = carbTotal {
            cell.totalDateLabel.text = String(
                format: NSLocalizedString("since %@", comment: "Format fragment for a start time"),
                timeFormatter.string(from: carbTotal.startDate)
            )
            cell.totalValueLabel.text = carbFormatter.string(from: carbTotal.quantity.doubleValue(for: unit))
        } else {
            cell.totalDateLabel.text = nil
            cell.totalValueLabel.text = carbFormatter.string(from: 0.0)
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch Section(rawValue: indexPath.section)! {
        case .charts, .totals:
            return false
        case .entries:
            if historyMode == .meals {
                return allowEditing && meals[indexPath.row].contains { $0.entry.createdByCurrentApp }
            }
            return allowEditing && carbStatuses[indexPath.row].entry.createdByCurrentApp
        }
    }

    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }

        // Meal mode: swiping the card deletes the ENTIRE meal (all its components).
        let entriesToDelete: [StoredCarbEntry]
        if historyMode == .meals {
            entriesToDelete = meals[indexPath.row].map { $0.entry }.filter { $0.createdByCurrentApp }
        } else {
            entriesToDelete = [carbStatuses[indexPath.row].entry]
        }

        let group = DispatchGroup()
        var lastError: Error?
        for entry in entriesToDelete {
            group.enter()
            deviceManager.loopManager.deleteCarbEntry(entry) { result in
                if case .failure(let error) = result { lastError = error }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.isEditing = false
            if let lastError {
                self.refreshContext.update(with: .carbs)
                self.present(UIAlertController(with: lastError), animated: true)
            }
            // Success → the LoopDataUpdated notification triggers a refresh.
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            return 170
        case .totals:
            return 66
        case .entries:
            return 66
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            return indexPath
        case .totals:
            return nil
        case .entries:
            if historyMode == .meals {
                return meals[indexPath.row].contains { $0.entry.createdByCurrentApp } ? indexPath : nil
            }
            return (allowEditing && carbStatuses[indexPath.row].entry.createdByCurrentApp) ? indexPath : nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        // Meal mode: edit the whole meal in the new meal-entry screen.
        if historyMode == .meals {
            guard indexPath.row < meals.count else { return }
            let entries = meals[indexPath.row].map { $0.entry }.filter { $0.createdByCurrentApp }
            guard !entries.isEmpty else { return }
            let viewModel = MealEntryViewModel(delegate: deviceManager, editing: entries)
            viewModel.deleteHandler = { [weak self] entry, done in
                self?.deviceManager.loopManager.deleteCarbEntry(entry) { _ in
                    DispatchQueue.main.async { done() }
                }
            }
            let mealEntryView = MealEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: mealEntryView, isModalInPresentation: false)
            present(hostingController, animated: true)
            return
        }

        guard indexPath.row < carbStatuses.count else { return }
        let originalCarbEntry = carbStatuses[indexPath.row].entry

        // Entries mode used to push the LEGACY `CarbEntryView` here while Meals
        // mode got the redesign, so editing the same carbs looked like two
        // different apps depending on which tab you were on. Both now use
        // `MealEntryView`; a single entry is just a one-component meal.
        let viewModel = MealEntryViewModel(delegate: deviceManager, editing: [originalCarbEntry])
        viewModel.deleteHandler = { [weak self] entry, done in
            self?.deviceManager.loopManager.deleteCarbEntry(entry) { _ in
                DispatchQueue.main.async { done() }
            }
        }
        let mealEntryView = MealEntryView(viewModel: viewModel)
            .environmentObject(deviceManager.displayGlucosePreference)
        let hostingController = DismissibleHostingController(rootView: mealEntryView, isModalInPresentation: false)
        present(hostingController, animated: true)
    }
    
    @objc func carbEditWasCanceled() {
        navigationController?.popToViewController(self, animated: true)
    }

    /// Rounded liquid-glass card background matching the carb-entry tiles (24pt).
    /// Rounded liquid-glass card behind a history row.
    ///
    /// ⚠️ THE THREE `.clear` LINES ARE THE WHOLE FIX, NOT TIDYING UP. The
    /// background configuration below was already setting a 24pt radius and
    /// inset glass — and the rows still drew as full-width square boxes. Cause:
    /// the prototype cells come from the storyboard with an OPAQUE cell and
    /// contentView background, and those paint on top of the configuration's
    /// rounded, inset background. Clearing them is what lets the card show.
    /// A `backgroundView` left from reuse does the same thing, so it goes too.
    /// Plain row: no card, no grey panel — just the content, with the table's
    /// own hairline separating one entry from the next.
    ///
    /// This deliberately REPLACED a rounded glass card. The card needed a shaded
    /// background behind it to read as a card at all, and that shade turned the
    /// whole list into a grey slab; the user asked for the opposite. Kept as a
    /// function (rather than deleted at both call sites) because the two cell
    /// types still have to agree on this, and because the two `.clear` lines are
    /// load-bearing: the storyboard prototypes carry an opaque background that
    /// otherwise paints over the table's.
    ///
    /// ⚠️ `automaticallyUpdatesBackgroundConfiguration = false` is what makes a
    /// custom background stick at all — a cell replaces its configuration on
    /// every state change, AFTER `cellForRowAt` returns.
    private func applyPlainCellBackground(to cell: UITableViewCell) {
        cell.automaticallyUpdatesBackgroundConfiguration = false

        var bg = UIBackgroundConfiguration.clear()
        bg.backgroundColor = .systemBackground
        cell.backgroundConfiguration = bg

        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.backgroundView = nil
        cell.selectedBackgroundView = nil
    }

    // MARK: - History mode selector (Entries / Meals)

    private lazy var modeSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            NSLocalizedString("Entries", comment: "History mode: per-entry list"),
            NSLocalizedString("Meals", comment: "History mode: grouped by meal")
        ])
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(historyModeChanged(_:)), for: .valueChanged)
        return control
    }()

    @objc private func historyModeChanged(_ sender: UISegmentedControl) {
        historyMode = HistoryMode(rawValue: sender.selectedSegmentIndex) ?? .entries
        tableView.reloadSections(IndexSet(integer: Section.entries.rawValue), with: .automatic)
    }
    
    // MARK: - Navigation
    @IBAction func presentCarbEntryScreen() {
        // The "+" opens the redesigned meal-entry screen in BOTH modes now — the
        // mode you happen to be viewing should not change what adding carbs looks
        // like. (The simple-bolus path below is a different feature for
        // non-looping users and is left alone.)
        if historyMode == .meals || !(FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled) {
            let viewModel = MealEntryViewModel(delegate: deviceManager)
            let mealEntryView = MealEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: mealEntryView, isModalInPresentation: false)
            present(hostingController, animated: true)
            return
        }
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            let viewModel = SimpleBolusViewModel(delegate: deviceManager, displayMealEntry: true)
            let bolusEntryView = SimpleBolusView(viewModel: viewModel).environmentObject(DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter))
            let hostingController = DismissibleHostingController(rootView: bolusEntryView, isModalInPresentation: false)
            let navigationWrapper = UINavigationController(rootViewController: hostingController)
            hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: navigationWrapper, action: #selector(dismissWithAnimation))
            present(navigationWrapper, animated: true)
        } else {
            let viewModel = CarbEntryViewModel(delegate: deviceManager)
            let carbEntryView = CarbEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: carbEntryView, isModalInPresentation: false)
            present(hostingController, animated: true)
        }
    }
}
