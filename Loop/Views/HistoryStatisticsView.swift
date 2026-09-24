//
//  HistoryStatisticsView.swift
//  Loop
//
//  Reads the history log back and summarises it. Nothing here writes anything or
//  talks to the algorithm.
//
//  THE RULE FOR THIS SCREEN: surface the evidence, never compute a dose. Every
//  observation quotes the number behind it and the window it came from. Nothing
//  suggests a basal rate, carb ratio or correction factor, and nothing added
//  later should.
//
//  LAYOUT: glass tiles on `loopScreenBackground`, per docs/DESIGN_SYSTEM.md —
//  same language as the meal and bolus screens. Ordered by what actually helps:
//  the headline first, then WHEN control slips, then the behaviour → outcome
//  links, then supply.
//

import SwiftUI
import Charts
import LoopKitUI

// MARK: - View model

@MainActor
final class HistoryStatisticsViewModel: ObservableObject {
    enum Period: String, CaseIterable, Identifiable {
        case threeDays, week, fortnight, month, twoMonths, quarter, all
        var id: String { rawValue }

        /// Deliberately compact ("7d", not "7 Days") so each row of the picker
        /// fits the narrowest phone without wrapping or truncating.
        var title: String {
            switch self {
            case .threeDays: return NSLocalizedString("3d", comment: "Statistics period: 3 days")
            case .week:      return NSLocalizedString("7d", comment: "Statistics period: 7 days")
            case .fortnight: return NSLocalizedString("14d", comment: "Statistics period: 14 days")
            case .month:     return NSLocalizedString("30d", comment: "Statistics period: 30 days")
            case .twoMonths: return NSLocalizedString("60d", comment: "Statistics period: 60 days")
            case .quarter:   return NSLocalizedString("90d", comment: "Statistics period: 90 days")
            case .all:       return NSLocalizedString("All", comment: "Statistics period: all data")
            }
        }

        /// Spelled out, for the scope caption under the picker.
        var longTitle: String {
            switch self {
            case .threeDays: return NSLocalizedString("3 days", comment: "Period, spelled out")
            case .week:      return NSLocalizedString("7 days", comment: "Period, spelled out")
            case .fortnight: return NSLocalizedString("14 days", comment: "Period, spelled out")
            case .month:     return NSLocalizedString("30 days", comment: "Period, spelled out")
            case .twoMonths: return NSLocalizedString("60 days", comment: "Period, spelled out")
            case .quarter:   return NSLocalizedString("90 days", comment: "Period, spelled out")
            case .all:       return NSLocalizedString("all data", comment: "Period, spelled out")
            }
        }

        var days: Int? {
            switch self {
            case .threeDays: return 3
            case .week: return 7
            case .fortnight: return 14
            case .month: return 30
            case .twoMonths: return 60
            case .quarter: return 90
            case .all: return nil
            }
        }
    }

    @Published var period: Period = .month { didSet { recompute() } }
    @Published private(set) var stats = HistoryStatistics()
    /// The equivalent window immediately before this one, for "is it improving?".
    @Published private(set) var previous: HistoryStatistics?
    /// True ONLY before the first successful load. Once there is something to
    /// show, a reload never blanks the screen again — see `isRefreshing`.
    @Published private(set) var isLoading = true
    /// A reload is in flight over data that is already on screen. Drives the
    /// floating pill; must never gate the content itself.
    @Published private(set) var isRefreshing = false
    /// Set once the first load completes, and never cleared. The screen keeps
    /// showing the last good numbers rather than falling back to a spinner.
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var hasData = false
    /// Computed from EVERY line, never the selected period — therapy evidence
    /// must not move because someone tapped "30 days".
    @Published private(set) var insights = TherapyInsights()
    /// Period-by-period comparison, also from EVERY line and for the same reason:
    /// month-by-month inside a 30-day window would be a single bar. Both
    /// granularities are computed once at load so the picker is instant.
    @Published private(set) var weeklyComparison: [HistoryStatistics.PeriodPoint] = []
    @Published private(set) var monthlyComparison: [HistoryStatistics.PeriodPoint] = []
    /// Best time in range ever, per period length in days, from EVERY line.
    @Published private(set) var bestTimeInRange: [Int: HistoryStatistics.BestTimeInRange] = [:]

    struct GlucosePoint {
        let date: Date
        let mgdl: Double
    }

    /// Glucose readings from `start` on, oldest first, for the week chart.
    func glucose(since start: Date) async -> [GlucosePoint] {
        let lines = allLines
        return await Task.detached(priority: .userInitiated) {
            let recent = lines.filter { line in
                line.t == "glucose" && (line.date.map { $0 >= start } ?? false)
            }
            return HistoryLineDeduplicator.deduplicated(recent)
                .compactMap { line -> GlucosePoint? in
                    guard let date = line.date, let mgdl = line.mgdl else { return nil }
                    return GlucosePoint(date: date, mgdl: mgdl)
                }
                .sorted { $0.date < $1.date }
        }.value
    }

    /// Best time in range over any run as long as the selected period; nil for "All".
    var bestTimeInRangeForPeriod: HistoryStatistics.BestTimeInRange? {
        period.days.flatMap { bestTimeInRange[$0] }
    }

    func comparison(_ granularity: HistoryStatistics.PeriodGranularity) -> [HistoryStatistics.PeriodPoint] {
        switch granularity {
        case .week: return weeklyComparison
        case .month: return monthlyComparison
        }
    }

    private var allLines: [HistoryLine] = []
    let currentISF: Double?
    let currentCarbRatio: Double?
    let scheduledBasalPerDay: Double?

    init(currentISF: Double?, currentCarbRatio: Double?, scheduledBasalPerDay: Double?) {
        self.currentISF = currentISF
        self.currentCarbRatio = currentCarbRatio
        self.scheduledBasalPerDay = scheduledBasalPerDay
    }

    func load() {
        // Only the FIRST load is allowed to show a loading screen. Later loads
        // leave the existing numbers in place and raise the pill instead, so the
        // content never disappears and the scroll position survives.
        isLoading = !hasLoadedOnce
        isRefreshing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let files = await withCheckedContinuation { continuation in
                HistoryLogStore.shared.loadFiles { continuation.resume(returning: $0) }
            }
            let lines = HistoryLogReader.read(files: files.map(\.url))
            let isf = await self?.currentISF
            let ratio = await self?.currentCarbRatio
            // Fixed 00:00–07:00 night, no HealthKit involvement — see
            // `TherapyInsights.nightStartHour`.
            let computed = TherapyInsights.compute(from: lines,
                                                   currentISF: isf ?? nil,
                                                   currentCarbRatio: ratio ?? nil)
            // Both granularities up front, still off the main thread.
            let weekly = HistoryStatistics.periodSummary(from: lines, granularity: .week)
            let monthly = HistoryStatistics.periodSummary(from: lines, granularity: .month)
            let best = HistoryStatistics.bestTimeInRange(from: lines,
                                                         windowDays: Period.allCases.compactMap(\.days))
            await MainActor.run {
                self?.allLines = lines
                self?.bestTimeInRange = best
                self?.insights = computed
                self?.weeklyComparison = weekly
                self?.monthlyComparison = monthly
                // `recompute()` owns `isLoading`/`isRefreshing`/`hasLoadedOnce`
                // now: it finishes AFTER this block, and clearing them here
                // would drop the loading tile before there were any numbers to
                // replace it with — a flash of "no data yet".
                self?.recompute()
            }
        }
    }

    /// Which recompute is current. A period tapped while an earlier one is
    /// still running invalidates it, so a slow result can never overwrite a
    /// newer, faster one.
    private var recomputeToken = 0

    /// Rebuild the on-screen statistics for the selected period.
    ///
    /// ⚠️ OFF THE MAIN THREAD, DELIBERATELY. This used to run synchronously
    /// inside the `period` setter, so every tap on the period picker blocked the
    /// main thread for as long as it took to filter every line in the log and
    /// run the whole statistics pass over it TWICE (the selected window and the
    /// one before it, for the comparison arrow). On a couple of months of data
    /// that is a visible freeze. The work is identical; only the thread changed,
    /// plus the token below so out-of-order results are discarded.
    private func recompute() {
        recomputeToken += 1
        let token = recomputeToken
        let lines = allLines
        let days = period.days
        let basal = scheduledBasalPerDay
        isRefreshing = true

        Task.detached(priority: .userInitiated) {
            let result = Self.statistics(for: lines, days: days, scheduledBasalPerDay: basal)
            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                self.stats = result.current
                self.previous = result.previous
                self.hasData = result.hasData
                self.isLoading = false
                self.isRefreshing = false
                self.hasLoadedOnce = true
            }
        }
    }

    /// The actual work, with no reference to `self` so it can run anywhere.
    ///
    /// ⚠️ INTERNAL, NOT PRIVATE, because `StatsLiveReport` runs the same
    /// computation with no view model in sight. It must be THIS function and not
    /// a copy: the whole-calendar-days rule below is subtle, was a bug once, and
    /// a second implementation of it would drift silently — the live report would
    /// then disagree with the screen it claims to mirror.
    nonisolated static func statistics(
        for lines: [HistoryLine],
        days: Int?,
        scheduledBasalPerDay: Double?
    ) -> (current: HistoryStatistics, previous: HistoryStatistics?, hasData: Bool) {
        guard let days else {
            let all = HistoryStatistics.compute(from: lines, scheduledBasalPerDay: scheduledBasalPerDay)
            return (all, nil, !lines.isEmpty)
        }

        // ⚠️ WHOLE CALENDAR DAYS, NOT A ROLLING 30×24 HOURS. Starting the window
        // at "now minus 30 days" makes the oldest day a half day: its records
        // count toward every total while the day itself counts as a full day in
        // the denominator, so each per-day average came out a little low. "30d"
        // now means the last 30 calendar days, today included.
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday)
            ?? now.addingTimeInterval(-Double(days) * 86400)
        let previousStart = calendar.date(byAdding: .day, value: -days, to: start)
            ?? start.addingTimeInterval(-Double(days) * 86400)

        var current: [HistoryLine] = []
        var earlier: [HistoryLine] = []
        // Reserving up front avoids a dozen reallocations of a large array.
        current.reserveCapacity(lines.count / 2)
        for line in lines {
            guard let date = line.parsedDate else { continue }
            if date >= start { current.append(line) }
            else if date >= previousStart { earlier.append(line) }
        }

        let stats = HistoryStatistics.compute(from: current, scheduledBasalPerDay: scheduledBasalPerDay)
        // Only offer a comparison when the earlier window has enough readings to
        // be a fair one — otherwise the arrow is just noise wearing a direction.
        // Skipped entirely when there is obviously not enough, which halves the
        // work for the short periods.
        var previous: HistoryStatistics?
        if earlier.count >= 100 {
            let earlierStats = HistoryStatistics.compute(from: earlier, scheduledBasalPerDay: scheduledBasalPerDay)
            previous = earlierStats.glucose.count >= 100 ? earlierStats : nil
        }
        return (stats, previous, !current.isEmpty)
    }

    // MARK: - Export

    /// One period's worth of report, ready to render.
    struct PeriodExport {
        let id: String
        let title: String
        let longTitle: String
        let model: StatsReportModel
    }

    /// The report for the period currently on screen.
    ///
    /// Cheap — pure formatting over statistics that are already computed — so a
    /// single-chapter share does not recompute anything and the picture matches
    /// the screen by construction.
    func currentReportModel() -> StatsReportModel {
        StatsReportModel.build(stats: stats,
                               insights: insights,
                               weeklyComparison: weeklyComparison,
                               monthlyComparison: monthlyComparison,
                               observations: HistoryStatisticsView.observations(for: stats),
                               periodTitle: period.title,
                               periodLongTitle: period.longTitle)
    }

    /// Every period, for the full HTML report.
    ///
    /// ⚠️ THIS IS THE EXPENSIVE ONE: it runs the whole statistics pass six times,
    /// once per period, so that the exported page carries a working time filter
    /// rather than a filter that would need the data it does not have. Off the
    /// main thread for the same reason `recompute()` is, and the caller shows a
    /// spinner — on a few months of history this is seconds, not milliseconds.
    func fullReportModels() async -> [PeriodExport] {
        let lines = allLines
        let basal = scheduledBasalPerDay
        let insights = self.insights
        let weekly = weeklyComparison
        let monthly = monthlyComparison

        return await Task.detached(priority: .userInitiated) {
            Period.allCases.map { period in
                let result = Self.statistics(for: lines, days: period.days, scheduledBasalPerDay: basal)
                let model = StatsReportModel.build(
                    stats: result.current,
                    insights: insights,
                    weeklyComparison: weekly,
                    monthlyComparison: monthly,
                    observations: HistoryStatisticsView.observations(for: result.current),
                    periodTitle: period.title,
                    periodLongTitle: period.longTitle)
                return PeriodExport(id: period.rawValue,
                                    title: period.title,
                                    longTitle: period.longTitle,
                                    model: model)
            }
        }.value
    }

    /// Percentage-point change in time in range against the previous window.
    var timeInRangeChange: Double? {
        guard let previous, previous.glucose.count > 0, stats.glucose.count > 0 else { return nil }
        return (stats.glucose.inRange - previous.glucose.inRange) * 100
    }
}

// MARK: - Screen

struct HistoryStatisticsView: View {
    @StateObject private var viewModel: HistoryStatisticsViewModel
    @Environment(\.guidanceColors) private var guidanceColors
    /// LoopKit's own dismissal hook. `DismissibleHostingController` injects this;
    /// SwiftUI's `\.dismiss` does NOT work for a UIKit-presented hosting
    /// controller, which is why the Done button did nothing at first.
    @Environment(\.dismissAction) private var dismissAction
    @Environment(\.scenePhase) private var scenePhase

    /// Only true when this screen is the modal's root (opened from the toolbar).
    /// When it is PUSHED — Settings → History Log → Statistics — there must be no
    /// Done button: `dismissAction` there belongs to the Settings modal, so a
    /// Done would close the whole of Settings rather than this screen.
    private let showsDoneButton: Bool

    /// Comparison tile controls. View state, not view-model state: switching
    /// them only re-reads arrays that were computed once at load.
    @State private var comparisonGranularity: HistoryStatistics.PeriodGranularity = .week
    @State private var comparisonMetric: ComparisonMetric = .timeInRange

    /// Live value from the chart's own selection gesture. Charts RESETS this to
    /// nil the instant the finger lifts, which would blank the readout before
    /// you could read it — so it is only a source, never displayed.
    @State private var scrubSelection: Int?

    /// The hour actually shown in the readout. Latched from `scrubSelection` and
    /// deliberately kept after lift, so you can drag to an hour, let go, and
    /// still read the numbers.
    @State private var scrubbedHour: Int?

    /// Bar-chart selections. Each is the same two-variable pattern as the scrub
    /// above: a live binding Charts drives, and a latched value that survives the
    /// gesture ending. Tapping a column is worthless if the number it reveals
    /// disappears with your finger.
    @State private var comparisonSelection: Date?
    @State private var selectedPeriodStart: Date?
    @State private var weeklyTrendSelection: Date?
    @State private var selectedWeekStart: Date?
    @State private var weekdaySelection: String?
    @State private var selectedWeekdayName: String?

    /// Set ONLY when this instance exists to be rendered into a PNG.
    ///
    /// ⚠️ THE EXPORT RENDERS THE REAL SCREEN. This is not a second, parallel
    /// layout that has to be kept in step by hand — it is this view, with the
    /// collapsibles forced open, the chrome removed and the charts labelled. A
    /// share card therefore cannot drift away from what the user was looking at,
    /// which is the failure mode every hand-built share card eventually has.
    private let exportSection: StatsReportModel.SectionID?

    private var isExporting: Bool { exportSection != nil }

    /// The share currently being prepared, if any. Drives the small spinner in
    /// place of that section's share icon.
    @State private var preparingSection: StatsReportModel.SectionID?
    @State private var isPreparingFullReport = false
    /// The self-rewriting copy in iCloud Drive. Observed rather than read once,
    /// so the "last written" line updates as it works.
    @ObservedObject private var liveReport = StatsLiveReport.shared

    /// Set when a share is ready; presenting the sheet is the only thing that
    /// clears it.
    @State private var sharePayload: StatsSharePayload?
    @State private var shareFailed = false
    @State private var showsWeekChart = false

    /// Which big tiles are expanded. Collapsed is the DEFAULT for the heavy ones:
    /// the screen was a continuous wall of charts you had to scroll past to find
    /// anything. Keyed by tile so the choices survive re-renders.
    @State private var expandedTiles: Set<String> = []

    /// What the comparison tile plots. Each case carries how to pull the number
    /// out of a period and how to render it, so the tile body stays declarative.
    enum ComparisonMetric: String, CaseIterable, Identifiable {
        case timeInRange, average, variability, belowRange
        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeInRange:  return NSLocalizedString("In Range", comment: "Comparison metric")
            case .average:      return NSLocalizedString("Average", comment: "Comparison metric")
            case .variability:  return NSLocalizedString("Variability", comment: "Comparison metric")
            case .belowRange:   return NSLocalizedString("Below Range", comment: "Comparison metric")
            }
        }

        /// Plotted value, in the unit the axis is labelled with.
        func value(_ point: HistoryStatistics.PeriodPoint) -> Double {
            switch self {
            case .timeInRange:  return point.inRange * 100
            case .average:      return point.mean
            case .variability:  return point.coefficientOfVariation
            case .belowRange:   return point.below * 100
            }
        }

        func formatted(_ point: HistoryStatistics.PeriodPoint) -> String {
            switch self {
            case .timeInRange, .belowRange, .variability:
                return String(format: "%.0f%%", value(point))
            case .average:
                return String(format: "%.0f mg/dL", value(point))
            }
        }

        /// Change of this many units or more is worth colouring. Below it the
        /// movement is noise and gets shown in grey.
        var meaningfulChange: Double {
            switch self {
            case .timeInRange:  return 3
            case .average:      return 5
            case .variability:  return 2
            case .belowRange:   return 1
            }
        }

        /// For in-range, up is good. For the rest, down is good.
        var higherIsBetter: Bool { self == .timeInRange }

        var color: Color {
            switch self {
            case .timeInRange:  return GlucoseBandColor.inRange
            case .average:      return Color.accentColor
            case .variability:  return GlucoseBandColor.high
            case .belowRange:   return GlucoseBandColor.low
            }
        }
    }

    /// Read-only, and only so the review tiles can show them beside what the
    /// data suggests. Nil when the screen is opened without them.
    init(currentISF: Double? = nil, currentCarbRatio: Double? = nil,
         scheduledBasalPerDay: Double? = nil, showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
        self.exportSection = nil
        _viewModel = StateObject(wrappedValue: HistoryStatisticsViewModel(
            currentISF: currentISF, currentCarbRatio: currentCarbRatio,
            scheduledBasalPerDay: scheduledBasalPerDay))
    }

    /// An off-screen copy of one chapter, for `ImageRenderer`.
    ///
    /// Takes the LIVE view model rather than building its own, so the card is
    /// rendered from the numbers already on screen — including the period the
    /// user has selected, which is what the card is stamped with.
    init(exporting section: StatsReportModel.SectionID, viewModel: HistoryStatisticsViewModel) {
        self.showsDoneButton = false
        self.exportSection = section
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        // ⚠️ `AnyView` for the same reason the sections are — see the note in
        // `liveScreen`. Two differently-typed branches at the root of a view this
        // large is exactly the nesting that overflowed the device stack.
        if let exportSection {
            AnyView(exportCard(exportSection))
        } else {
            AnyView(liveScreen)
        }
    }

    // MARK: - The export card
    //
    // One chapter, laid out for a picture: a real title (the section header is
    // suppressed while exporting), the window the numbers came from, and the
    // disclaimer — which must travel WITH the numbers, because a card gets
    // forwarded on its own to people who never saw this screen.

    private func exportCard(_ section: StatsReportModel.SectionID) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(exportScopeLine(section))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let first = viewModel.stats.firstDate, let last = viewModel.stats.lastDate,
                   !section.ignoresPeriod {
                    Text("\(Self.dayFormatter.string(from: first)) – \(Self.dayFormatter.string(from: last))")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            exportSectionContent(section)

            VStack(alignment: .leading, spacing: 4) {
                Text(StatsReportModel.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("Exported %@ from Loop.", comment: "Export stamp"),
                            Self.exportStampFormatter.string(from: Date())))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopScreenBackground)
    }

    /// The one line that says exactly what window the card describes.
    ///
    /// ⚠️ NEVER OMITTED. A time-in-range figure with no window attached is not a
    /// weaker statement, it is an unreadable one — 78% over a week and 78% over
    /// ninety days are different claims.
    private func exportScopeLine(_ section: StatsReportModel.SectionID) -> String {
        section.ignoresPeriod
            ? NSLocalizedString("All recorded history", comment: "Export scope")
            : String(format: NSLocalizedString("Last %@", comment: "Export scope"), viewModel.period.longTitle)
    }

    @ViewBuilder
    private func exportSectionContent(_ section: StatsReportModel.SectionID) -> some View {
        switch section {
        case .overview: headlineSection
        case .progress: progressSection
        case .when:     whenSection
        case .meals:    mealsSection
        case .safety:   safetySection
        case .deeper:   goingDeeperSection
        case .supplies: suppliesSection
        case .review:   reviewSection
        }
    }

    private static let exportStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - The live screen

    private var liveScreen: some View {
        ZStack {
            Color.loopScreenBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    periodPicker
                    periodScopeCaption
                    // ⚠️ The branch order matters for SCROLL STABILITY. Swapping
                    // the whole content out for a loading tile tears down the
                    // scroll view's children, so the position resets to the top
                    // on every reload. `isLoading` is now true only before the
                    // FIRST load; after that the content stays mounted, the
                    // numbers update in place, and the refresh shows as a pill
                    // overlay instead. Do not reintroduce `isRefreshing` here.
                    if viewModel.isLoading {
                        loadingTile
                    } else if !viewModel.hasData {
                        emptyTile
                    } else {
                        // ⚠️⚠️ THESE ARE `AnyView` ON PURPOSE. DO NOT "CLEAN UP".
                        //
                        // 🐛 This screen CRASHED ON DEVICE (not in the simulator)
                        // with EXC_BAD_ACCESS on the stack guard region — a stack
                        // overflow inside `swift_getTypeByMangledName`, called from
                        // this very closure. Cause: ~25 differently-typed children
                        // in one VStack builds a colossal nested generic type, and
                        // instantiating its mangled name recurses deeply enough to
                        // exhaust the stack.
                        //
                        // It only ever crashed on the phone because the DEVICE main
                        // thread has a 1 MB stack while the simulator's has 8 MB —
                        // which is exactly why "it works in the simulator" proved
                        // nothing here, twice.
                        //
                        // Type-erasing each section cuts the nesting: the VStack now
                        // has a handful of identical `AnyView` children instead of a
                        // deep tuple of unique types. The rendering is unchanged.
                        headlineSection
                        progressSection
                        whenSection
                        mealsSection
                        safetySection
                        goingDeeperSection
                        suppliesSection
                        reviewSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Floating refresh pill, OVERLAID on the scroll view rather than
            // inserted into it. Being outside the scrolled content is the point:
            // it cannot push anything down, cannot change the content height, and
            // therefore cannot move you from where you were reading.
            .overlay(alignment: .top) {
                if viewModel.isRefreshing && viewModel.hasLoadedOnce {
                    refreshPill
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.isRefreshing)
        }
        .navigationTitle(Text("Statistics", comment: "Title of the statistics screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsWeekChart = true } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .accessibilityLabel(Text("Glucose, last 7 days", comment: "Button that opens the week glucose chart"))
                .disabled(!viewModel.hasLoadedOnce)
            }
            // Same shape as every other Done in the app (AI settings, custom
            // alerts): trailing confirmationAction, plain semibold text.
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismissAction() } label: {
                        Text("Done", comment: "Close the statistics screen").fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear {
            viewModel.load()
            // Cheap, and it is the only place these three are known. Persisted so
            // a refresh that happens before anyone opens this screen can still
            // print "currently set to" in the settings review.
            StatsLiveReport.shared.rememberSettings(currentISF: viewModel.currentISF,
                                                    currentCarbRatio: viewModel.currentCarbRatio,
                                                    scheduledBasalPerDay: viewModel.scheduledBasalPerDay)
            StatsLiveReport.shared.refresh()
        }
        // Reload when the app comes back to the foreground. Without this the
        // pill and the whole keep-the-old-data path would be dead code: `load()`
        // otherwise runs once on appear and never again, and changing the period
        // only RECOMPUTES from lines already in memory. Coming back from
        // background is also the moment new records have actually accumulated.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, viewModel.hasLoadedOnce else { return }
            viewModel.load()
        }
        .sheet(item: $sharePayload) { payload in
            StatsActivityView(items: payload.activityItems)
        }
        .sheet(isPresented: $showsWeekChart) {
            GlucoseWeekChartView(viewModel: viewModel)
        }
        .alert(NSLocalizedString("Could not prepare the share", comment: "Share failure title"),
               isPresented: $shareFailed) {
            Button(NSLocalizedString("OK", comment: "Dismiss")) { }
        } message: {
            Text("Nothing was written and nothing was sent. Try again, or share a different section.",
                 comment: "Share failure message")
        }
    }

    // MARK: - Sections
    //
    // Each returns `AnyView` deliberately — see the note in `body`. Keeping the
    // sections small AND type-erased is what stops the mangled type name from
    // growing deep enough to overflow the device's 1 MB main-thread stack.

    private var headlineSection: AnyView {
        AnyView(VStack(spacing: 16) {
            // The overview is the top of the screen and deliberately has no
            // section heading — so its share control gets a row of its own
            // rather than being hidden inside the time-in-range tile, where it
            // would look like it shared only that one tile.
            if !isExporting {
                HStack(spacing: 6) {
                    Spacer()
                    StatsShareButton(title: StatsReportModel.SectionID.overview.title,
                                     isBusy: preparingSection == .overview) {
                        share(.overview)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, -12)
            }
            // Headline, then immediately the "so what". Observations used to sit
            // at the bottom, below a dozen tiles — the wrong end for the most
            // useful thing on the screen.
            timeInRangeTile
            observationsTile
            keyNumbersRow
            bestTimeInRangeTile
        })
    }

    private var progressSection: AnyView {
        guard viewModel.stats.weeklyTrend.count >= 2 || viewModel.stats.days.counted >= 3
                || !viewModel.weeklyComparison.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("Progress", comment: "Section header"), share: .progress)
            if viewModel.stats.weeklyTrend.count >= 2 { weeklyTrendTile }
            // Spans ALL history regardless of the period picker, so it shows
            // whenever there is any history at all.
            if !viewModel.weeklyComparison.isEmpty { periodComparisonTile }
            if viewModel.stats.days.counted >= 3 { daysTile }
        })
    }

    private var whenSection: AnyView {
        guard viewModel.stats.hourlyProfile.count >= 6 || viewModel.stats.weekdayProfile.count >= 4
        else { return AnyView(EmptyView()) }
        return AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("When", comment: "Section header"), share: .when)
            if viewModel.stats.hourlyProfile.count >= 6 { hourlyTile }
            if viewModel.stats.weekdayProfile.count >= 4 { weekdayTile }
            dayNightTile
        })
    }

    private var mealsSection: AnyView {
        guard viewModel.stats.postMeal.mealsAnalysed >= 3 || !viewModel.stats.mealWindows.isEmpty
        else { return AnyView(EmptyView()) }
        return AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("Meals", comment: "Section header"), share: .meals)
            if viewModel.stats.postMeal.mealsAnalysed >= 3 { postMealTile }
            if !viewModel.stats.mealSizeOutcomes.isEmpty { mealSizeTile }
            if !viewModel.stats.mealWindows.isEmpty { mealWindowsTile }
        })
    }

    private var safetySection: AnyView {
        guard viewModel.stats.lowEvents.count > 0 || viewModel.stats.nights.total > 0
        else { return AnyView(EmptyView()) }
        return AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("Safety", comment: "Section header"), share: .safety)
            safetyTile
            if !viewModel.stats.bedtimeOutcomes.isEmpty { bedtimeTile }
        })
    }

    private var goingDeeperSection: AnyView {
        guard viewModel.stats.glucose.count >= 200 else { return AnyView(EmptyView()) }
        return AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("Going Deeper", comment: "Section header"), share: .deeper)
            riskTile
            variabilityTile
        })
    }

    private var suppliesSection: AnyView {
        AnyView(VStack(spacing: 16) {
            sectionHeader(NSLocalizedString("Insulin & Supplies", comment: "Section header"), share: .supplies)
            loopActivityTile
            supplyTile
        })
    }

    private var reviewSection: AnyView {
        AnyView(VStack(spacing: 16) {
            // Deliberately spans ALL history and says so: therapy evidence must
            // not move because someone tapped "7d".
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(NSLocalizedString("Settings Review", comment: "Section header"), share: .review)
                // Not in an export: the card's own subtitle already says "All
                // recorded history", and with the header suppressed the badge was
                // left floating on its own under the title.
                if !isExporting { allHistoryBadge }
            }
            TherapyInsightsSection(insights: viewModel.insights, isExporting: isExporting)
            shareButton
        })
    }

    // MARK: Tile chrome

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .loopExportableTileBackground(isExporting)
    }

    /// Groups the tiles into chapters. Without these the screen is a wall of
    /// equally-weighted cards and there is no way to skim it.
    ///
    /// - Parameter share: the chapter this header names. Given one, the header
    ///   carries that chapter's share control.
    ///
    /// ⚠️ RETURNS NOTHING WHILE EXPORTING. The card draws its own large title,
    /// and a second, smaller heading underneath it read as a mistake.
    @ViewBuilder
    private func sectionHeader(_ text: String, share: StatsReportModel.SectionID? = nil) -> some View {
        if !isExporting {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let share {
                    StatsShareButton(title: text, isBusy: preparingSection == share) {
                        self.share(share)
                    }
                    .offset(y: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.horizontal, 4)
        }
    }

    private func tileTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// A tile that starts collapsed, showing its headline figure only, and
    /// expands on tap.
    ///
    /// `peek` is the one line worth seeing without opening anything — the whole
    /// point is that the collapsed screen still answers "how am I doing?" while
    /// staying skimmable. The chevron and the whole header are the hit target.
    /// - Parameter ignoresPeriod: true for the few tiles that deliberately span
    ///   ALL history whatever the picker says. They get a visible badge — a tile
    ///   that quietly answers a different question than the one the picker asks
    ///   is exactly how a reader ends up mistrusting the whole screen.
    private func collapsibleTile<Peek: View, Content: View>(
        _ key: String,
        title: String,
        ignoresPeriod: Bool = false,
        @ViewBuilder peek: () -> Peek,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // ⚠️ ALWAYS OPEN IN AN EXPORT. A collapsed tile in a picture is a tile
        // whose contents the reader can never reach — there is nothing to tap.
        let isExpanded = isExporting || expandedTiles.contains(key)
        return tile {
            Button {
                // Animated so the tile grows rather than snapping, and so the
                // chevron rotation reads as the same gesture.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    if isExpanded { expandedTiles.remove(key) } else { expandedTiles.insert(key) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    tileTitle(title)
                    if ignoresPeriod { allHistoryBadge }
                    Spacer()
                    // No chevron on a card: it advertises an interaction the
                    // picture cannot honour.
                    if !isExporting {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityHint(isExpanded
                ? Text("Collapse", comment: "Accessibility hint for an expanded statistics tile")
                : Text("Expand", comment: "Accessibility hint for a collapsed statistics tile"))

            peek()

            if isExpanded {
                content()
                    // Fades in place rather than sliding, so the peek line above
                    // it does not appear to move.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A bar's own value, drawn only in an export.
    ///
    /// Always attached to the mark, empty when not exporting: keeping the
    /// annotation unconditional keeps the chart content one stable type, which
    /// matters on a screen that has already overflowed the device stack once by
    /// growing its generic types.
    @ViewBuilder
    private func exportBarLabel(_ text: String) -> some View {
        if isExporting {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The always-visible summary line of a collapsed tile.
    private func peekLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Selection that responds to a PLAIN TAP.
    ///
    /// `chartXSelection`'s built-in gesture is a LONG PRESS followed by a drag —
    /// a normal tap does nothing at all, which reads as the chart being dead.
    /// A `DragGesture` with `minimumDistance: 0` fires `onChanged` on touch-down,
    /// so a tap selects instantly and a drag still scrubs continuously. Replacing
    /// the default gesture is the whole point; do not also leave the long press in.
    private func instantSelect(_ proxy: ChartProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                proxy.selectXValue(at: value.location.x)
            }
    }

    /// Exact numbers at the scrubbed hour, or a hint to try it.
    @ViewBuilder
    private var scrubReadout: some View {
        if let hour = scrubbedHour,
           let point = viewModel.stats.hourlyProfile.first(where: { $0.hour == hour }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.hourLabel(hour))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(String(format: NSLocalizedString("%.0f mg/dL", comment: "Scrubbed median glucose"), point.median))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                // The spread is the reason this chart exists, so it is shown
                // alongside the median rather than hidden behind another tap.
                Text(String(format: NSLocalizedString("%1$.0f–%2$.0f middle half", comment: "Scrubbed interquartile range"),
                            point.p25, point.p75))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The sample size, because the band means nothing without it.
                Text(String(format: NSLocalizedString("%d days", comment: "Days behind a scrubbed hour"), point.days))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else if !isExporting {
            // ⚠️ Never in an export: inviting the reader to drag across a PNG is
            // instructing them to do something impossible.
            Text("Touch and drag across the chart to read any hour.", comment: "Scrub hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Period

    /// Seven periods on two rows: the short ones (3d…30d) on top, the long
    /// ones (60d, 90d, All) below. One row of seven no longer fit the
    /// narrowest phone once 3d was added.
    private static let periodRows: [[HistoryStatisticsViewModel.Period]] = [
        [.threeDays, .week, .fortnight, .month],
        [.twoMonths, .quarter, .all],
    ]

    private var periodPicker: some View {
        VStack(spacing: 8) {
            ForEach(Self.periodRows.indices, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(Self.periodRows[row]) { period in
                        periodChip(period)
                    }
                }
            }
        }
    }

    private func periodChip(_ period: HistoryStatisticsViewModel.Period) -> some View {
        let isSelected = viewModel.period == period
        return Button { viewModel.period = period } label: {
            Text(period.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(GlassButtonStyle(
            isSelected ? .regular.tint(Color.loopSelectionTint).interactive() : .regular.interactive(),
            in: Capsule()))
    }

    /// Says, in one line, exactly what the numbers below cover.
    ///
    /// The picker was ambiguous in both directions: it was not obvious that
    /// every tile follows it, and it was not obvious that two of them
    /// deliberately do NOT (they are marked "All history" on the tile itself).
    /// It also names how many days actually HAVE data, because "30d" with eight
    /// days of log is eight days of evidence, not thirty.
    @ViewBuilder
    private var periodScopeCaption: some View {
        let dataDays = viewModel.stats.daysWithData
        Text(scopeText(dataDays: dataDays))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func scopeText(dataDays: Int) -> String {
        let window: String
        switch viewModel.period {
        case .all:
            window = NSLocalizedString("Everything below covers your whole history", comment: "Scope caption, all data")
        default:
            window = String(format: NSLocalizedString("Everything below covers the last %@", comment: "Scope caption (1: period)"),
                            viewModel.period.longTitle)
        }
        guard dataDays > 0 else { return window + "." }
        return window + String(format: NSLocalizedString(" — %d days of it have data.", comment: "Scope caption, days with data"), dataDays)
    }

    /// Marks a tile that deliberately ignores the period picker.
    private var allHistoryBadge: some View {
        Text("All history", comment: "Badge on tiles that ignore the period picker")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.loopControlTint))
    }

    /// The small "Updating…" pill shown while a reload runs over data that is
    /// already on screen.
    private var refreshPill: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Updating…", comment: "Statistics refresh pill")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityLabel(Text("Updating statistics", comment: "Accessibility label for the refresh pill"))
    }

    private var loadingTile: some View {
        tile {
            HStack {
                ProgressView()
                Text("Reading your history…", comment: "Statistics loading")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
    }

    private var emptyTile: some View {
        tile {
            Text("Nothing to summarise yet", comment: "Statistics empty title")
                .font(.headline)
            Text("Turn on Record History and check back once a few days of data have been logged.", comment: "Statistics empty body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Headline — time in range

    private var timeInRangeTile: some View {
        tile {
            tileTitle(NSLocalizedString("Time In Range", comment: "Tile title"))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.percent(viewModel.stats.glucose.inRange))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let change = viewModel.timeInRangeChange, abs(change) >= 1 {
                    changeBadge(change)
                }
                Spacer()
            }

            timeInRangeBar

            // The consensus target, stated so the number above has a meaning
            // beyond "bigger is better".
            Text(String(format: NSLocalizedString("70–180 mg/dL. A commonly cited goal is above 70%%; you're at %@.", comment: "TIR target context"),
                        Self.percent(viewModel.stats.glucose.inRange)))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().opacity(0.4)

            ForEach(bands) { band in
                // Every band is named with its own range and number: the severity
                // colours repeat on the low and high sides, so the bar alone can
                // never be the way you read this.
                HStack(spacing: 10) {
                    Circle().fill(band.color).frame(width: 9, height: 9)
                    Text(band.name).font(.subheadline)
                    Text(band.range).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Self.percent(band.fraction))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Best time in range over any run of days as long as the selected period, as a
    /// full-width key-number card. Hidden for "All", which has nothing to compare against.
    @ViewBuilder
    private var bestTimeInRangeTile: some View {
        if let best = viewModel.bestTimeInRangeForPeriod {
            // Runs end on whole days and a tie goes to the most recent, so the best
            // run ending today IS the period on screen.
            let isCurrent = Calendar.current.isDateInToday(best.lastDay)
            let dates = Self.bestRangeFormatter.string(from: best.firstDay, to: best.lastDay)
            // The period on screen scores higher but has too few readings to count.
            let tooLittleData = !isCurrent
                && (viewModel.stats.glucose.inRange * 100).rounded() > (best.fraction * 100).rounded()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    // Outline only, in the text colour: no colour of its own.
                    Image(systemName: "trophy")
                        .foregroundStyle(.primary)
                    Text(String(format: NSLocalizedString("Best %@", comment: "Best TIR card title (1: period, e.g. 7 Days)"),
                                viewModel.period.longTitle.localizedCapitalized))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(Self.percent(best.fraction))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Group {
                    if isCurrent {
                        Text("Right now — your best so far", comment: "Best TIR card: the period on screen is the best")
                    } else if tooLittleData {
                        Text(String(format: NSLocalizedString("%1$@ · this period needs %2$@ sensor data to count", comment: "Best TIR card: dates, and why the higher period on screen does not count (2: e.g. 70%)"),
                                    dates, Self.percent(HistoryStatistics.bestTimeInRangeMinimumCoverage)))
                    } else {
                        Text(dates)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .loopExportableTileBackground(isExporting)
            .accessibilityElement(children: .combine)
        }
    }

    private static let bestRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "dMMM"
        return formatter
    }()

    private func changeBadge(_ change: Double) -> some View {
        let improving = change > 0
        return HStack(spacing: 3) {
            Image(systemName: improving ? "arrow.up.right" : "arrow.down.right")
            Text(String(format: "%.0f pts", abs(change)))
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(improving ? guidanceColors.acceptable : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.loopControlTint))
        .accessibilityLabel(improving
            ? Text(String(format: NSLocalizedString("Up %.0f points versus the previous period", comment: "TIR change up"), abs(change)))
            : Text(String(format: NSLocalizedString("Down %.0f points versus the previous period", comment: "TIR change down"), abs(change))))
    }

    /// Stacked proportional bar: five ordered segments, 2pt of surface between
    /// them so adjacent bands never bleed together.
    /// Bands big enough to READ AS non-zero.
    ///
    /// The test is the displayed percentage, not the raw fraction: `percent`
    /// rounds to whole numbers, so anything under 0.5% prints "0%". Drawing a
    /// sliver for a band the legend calls 0% is the app contradicting itself —
    /// which is what the old `fraction > 0` test did, and with `max(6, …)` that
    /// sliver was forced to a visible 6pt besides.
    private var visibleBands: [Band] {
        bands.filter { ($0.fraction * 100).rounded() >= 1 }
    }

    /// One pill, segmented — not a row of pills.
    ///
    /// The segments are square-edged and flush against each other; the CONTAINER
    /// is clipped to a capsule, so only the outer two edges are round. Rounding
    /// each segment made five separate lozenges with gaps, which read as five
    /// unrelated bars rather than one distribution summing to 100%.
    private var timeInRangeBar: some View {
        let visible = visibleBands
        // Widths are renormalised over the VISIBLE bands so the bar always fills
        // its width exactly. Without this, dropping the sub-0.5% bands would
        // leave a hairline of background at the end.
        let total = visible.reduce(0) { $0 + $1.fraction }
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(visible) { band in
                    Rectangle()
                        .fill(band.color)
                        .frame(width: total > 0 ? geometry.size.width * (band.fraction / total) : 0)
                }
            }
        }
        .frame(height: 20)
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time in range", comment: "Accessibility label for the time in range bar"))
        // Reads every band, including the ones too small to draw — the bar is a
        // summary, the accessibility value should still be complete.
        .accessibilityValue(bands.map { "\($0.name) \(Self.percent($0.fraction))" }.joined(separator: ", "))
    }

    private struct Band: Identifiable {
        let id: String
        let name: String
        let range: String
        let fraction: Double
        let color: Color
    }

    private var bands: [Band] {
        let glucose = viewModel.stats.glucose
        return [
            Band(id: "veryLow", name: NSLocalizedString("Very Low", comment: "TIR band"),
                 range: NSLocalizedString("< 54", comment: "TIR band range"),
                 fraction: glucose.veryLow, color: GlucoseBandColor.veryLow),
            Band(id: "low", name: NSLocalizedString("Low", comment: "TIR band"),
                 range: NSLocalizedString("54–69", comment: "TIR band range"),
                 fraction: glucose.low, color: GlucoseBandColor.low),
            Band(id: "inRange", name: NSLocalizedString("In Range", comment: "TIR band"),
                 range: NSLocalizedString("70–180", comment: "TIR band range"),
                 fraction: glucose.inRange, color: GlucoseBandColor.inRange),
            Band(id: "high", name: NSLocalizedString("High", comment: "TIR band"),
                 range: NSLocalizedString("181–250", comment: "TIR band range"),
                 fraction: glucose.high, color: GlucoseBandColor.high),
            Band(id: "veryHigh", name: NSLocalizedString("Very High", comment: "TIR band"),
                 range: NSLocalizedString("> 250", comment: "TIR band range"),
                 fraction: glucose.veryHigh, color: GlucoseBandColor.veryHigh)
        ]
    }

    // MARK: Key numbers

    private var keyNumbersRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                miniTile(NSLocalizedString("Average", comment: "Stat"),
                         String(format: "%.0f", viewModel.stats.glucose.mean),
                         NSLocalizedString("mg/dL", comment: "Unit"))
                miniTile(NSLocalizedString("Est. A1c", comment: "Stat"),
                         String(format: "%.1f", viewModel.stats.glucose.gmi),
                         "%")
                miniTile(NSLocalizedString("Variability", comment: "Stat"),
                         String(format: "%.0f", viewModel.stats.glucose.coefficientOfVariation),
                         NSLocalizedString("% · goal <36", comment: "CV goal"))
            }
            HStack(spacing: 12) {
                miniTile(NSLocalizedString("Tight Range", comment: "Stat"),
                         Self.percent(viewModel.stats.glucose.inTightRange),
                         NSLocalizedString("80–140 mg/dL", comment: "Tight range band"))
                if let rise = viewModel.stats.dawn.averageRise, viewModel.stats.dawn.daysMeasured >= 5 {
                    miniTile(NSLocalizedString("Dawn Rise", comment: "Stat"),
                             String(format: "%@%.0f", rise >= 0 ? "+" : "", rise),
                             NSLocalizedString("3am → 8am", comment: "Dawn window"))
                }
                miniTile(NSLocalizedString("Sensor Data", comment: "Stat"),
                         Self.percent(viewModel.stats.coverage.fraction),
                         NSLocalizedString("of expected", comment: "Coverage unit"))
            }
        }
    }

    private func miniTile(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .loopExportableTileBackground(isExporting)
    }

    // MARK: When control slips

    private var hourlyTile: some View {
        collapsibleTile("hourly", title: NSLocalizedString("Through The Day", comment: "Tile title")) {
            if let worst = viewModel.stats.worstHour {
                peekLine(String(format: NSLocalizedString("Highest around %1$@, typically %2$.0f mg/dL.", comment: "Hourly tile peek"),
                                Self.hourLabel(worst.hour), worst.median))
            } else {
                peekLine(NSLocalizedString("Your typical glucose hour by hour.", comment: "Hourly tile peek"))
            }
        } content: {
            Text("The line is your typical glucose at each hour, and each day counts once: the bands are how much that hour varies BETWEEN days over the selected period. A narrow band is predictable — a wide one means that hour is a coin toss, which needs a different response than simply being high. Hours with fewer than three days of data are left out rather than guessed at.", comment: "AGP profile explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Readout for the scrub. Kept ABOVE the chart and always present
            // (showing a hint when nothing is selected) so the tile does not
            // change height as you drag — a jumping layout under your own finger
            // is what makes these feel broken.
            scrubReadout

            Chart {
                // Target band, drawn first and kept recessive so it reads as
                // context behind the data rather than as another series.
                RectangleMark(
                    xStart: .value("", 0), xEnd: .value("", 23),
                    yStart: .value("", 70), yEnd: .value("", 180)
                )
                .foregroundStyle(GlucoseBandColor.inRange.opacity(0.10))

                // Spread first, median on top: two nested bands (10–90 outer,
                // 25–75 inner) built from the SAME hue at different strengths, so
                // they read as one quantity at two confidence levels rather than
                // as separate series.
                //
                // ⚠️⚠️ EVERY MARK CARRIES AN EXPLICIT `series:`, AND THAT IS WHAT
                // MAKES THIS CHART CORRECT. Swift Charts groups marks of the same
                // type into ONE series unless told otherwise. The two AreaMarks
                // were therefore drawn as a single area: the path ran left to
                // right along the 10–90 band, then jumped back across the whole
                // day to pick up the 25–75 band, sweeping a diagonal wedge over
                // the chart. That wedge was the "broken graph" — it was not data.
                //
                // ⚠️ The profile is also split into runs of CONSECUTIVE hours,
                // each its own series. An hour that fails the evidence floor
                // (`minimumReadingsPerHour` / `minimumDaysPerHour`) is omitted
                // from `hourlyProfile`, and a single series would have quietly
                // interpolated straight across the hole — drawing a level for an
                // hour that was explicitly judged unmeasurable. A break in the
                // line is the honest rendering of a gap.
                //
                // ⚠️ `.monotone`, NOT `.catmullRom`. Catmull-Rom OVERSHOOTS: it
                // draws curve values outside the range of the points it connects,
                // so the median line could dip below the lowest hourly median
                // actually measured, the bands could bulge past their own
                // percentiles, and the inner band could visually cross the outer
                // one. On a glucose chart that is drawing readings that do not
                // exist. Monotone interpolation is still smooth but is
                // mathematically incapable of leaving the data's range.
                // Do not "improve" this back to catmullRom.
                ForEach(hourlyRuns, id: \.id) { run in
                    // Outer band only where enough DAYS back it. With four days
                    // or fewer p10/p90 are just the lowest and highest day, and
                    // drawing them as a "usual range" overstates what is known.
                    ForEach(run.points.filter(\.hasOuterBand)) { point in
                        AreaMark(
                            x: .value(NSLocalizedString("Hour", comment: "Chart axis"), point.hour),
                            yStart: .value("", point.p10),
                            yEnd: .value("", point.p90),
                            series: .value("", "outer-\(run.id)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                    }
                    ForEach(run.points) { point in
                        AreaMark(
                            x: .value(NSLocalizedString("Hour", comment: "Chart axis"), point.hour),
                            yStart: .value("", point.p25),
                            yEnd: .value("", point.p75),
                            series: .value("", "inner-\(run.id)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor.opacity(0.25))
                    }
                    ForEach(run.points) { point in
                        LineMark(
                            x: .value(NSLocalizedString("Hour", comment: "Chart axis"), point.hour),
                            y: .value(NSLocalizedString("Glucose", comment: "Chart axis"), point.median),
                            series: .value("", "median-\(run.id)")
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)
                    }
                    // A run of one hour has no line to draw. Without this it
                    // would be silently invisible — an hour that DID clear the
                    // evidence floor, shown as if it hadn't.
                    if run.points.count == 1, let only = run.points.first {
                        PointMark(
                            x: .value(NSLocalizedString("Hour", comment: "Chart axis"), only.hour),
                            y: .value(NSLocalizedString("Glucose", comment: "Chart axis"), only.median)
                        )
                        .symbolSize(28)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                // Every hour's median, printed. Same rule as the bars: an
                // exported AGP with no numbers on it is a shape, not a chart.
                // The symbol is sized to nothing — only the annotation is wanted.
                if isExporting {
                    ForEach(viewModel.stats.hourlyProfile) { point in
                        PointMark(
                            x: .value(NSLocalizedString("Hour", comment: "Chart axis"), point.hour),
                            y: .value(NSLocalizedString("Glucose", comment: "Chart axis"), point.median)
                        )
                        .symbolSize(0)
                        .annotation(position: .top, alignment: .center, spacing: 1) {
                            Text(String(format: "%.0f", point.median))
                                .font(.system(size: 8, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Scrub indicator. Drawn last so it sits above the bands.
                if let hour = scrubbedHour,
                   let point = viewModel.stats.hourlyProfile.first(where: { $0.hour == hour }) {
                    RuleMark(x: .value(NSLocalizedString("Hour", comment: "Chart axis"), hour))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(
                        x: .value(NSLocalizedString("Hour", comment: "Chart axis"), hour),
                        y: .value(NSLocalizedString("Glucose", comment: "Chart axis"), point.median)
                    )
                    .symbolSize(90)
                    .foregroundStyle(Color.accentColor)
                }
            }
            // Drag anywhere on the chart to read the exact numbers at that hour.
            // `chartXSelection` handles the hit-testing and snapping to the
            // nearest plotted hour, so there is no manual geometry maths here.
            .chartXSelection(value: $scrubSelection)
            .chartGesture { proxy in instantSelect(proxy) }
            // Latch: keep the last hour the finger was over. Assigning only on
            // non-nil is the whole trick — the nil that arrives on lift is
            // ignored, so the readout survives the gesture ending.
            .onChange(of: scrubSelection) { _, newValue in
                if let newValue { scrubbedHour = newValue }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(Self.hourLabel(hour))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [70, 180]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            // ⚠️ DELIBERATELY NOT horizontally scrollable, despite being the
            // busiest chart here. Scrubbing (`chartXSelection` above) and
            // horizontal scrolling both claim the same horizontal drag, and the
            // scroll wins — selection then never fires and the readout stays on
            // its hint no matter where you drag. Reading exact values matters
            // more on this chart than fitting fewer hours on screen, so the whole
            // day is shown at once and the drag belongs to the scrub.
            .frame(height: 150)

            if let worst = viewModel.stats.worstHour, worst.median > 180 {
                Label(String(format: NSLocalizedString("Highest around %1$@ — typically %2$.0f mg/dL.", comment: "Worst hour callout"),
                             Self.hourLabel(worst.hour), worst.median),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// How far apart the best and worst weekday must be, in time-in-range
    /// fraction, before one is called out. ONE percentage point: enough to stop
    /// a dead-level week from having a "weakest day" invented for it, and low
    /// enough that any real difference gets named. The comparison is `>=`, so
    /// exactly one point apart still counts as standing out.
    private static let weekdayStandoutMargin = 0.01

    /// The hourly profile split into runs of CONSECUTIVE hours, so the chart can
    /// break at the hours that were omitted for lack of evidence instead of
    /// drawing through them. See the note in `hourlyTile`.
    private var hourlyRuns: [(id: Int, points: [HistoryStatistics.HourlyPoint])] {
        var runs: [[HistoryStatistics.HourlyPoint]] = []
        for point in viewModel.stats.hourlyProfile.sorted(by: { $0.hour < $1.hour }) {
            if let last = runs.last?.last, point.hour == last.hour + 1 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.enumerated().map { (id: $0.offset, points: $0.element) }
    }

    /// Always includes the target band so the shaded region is never clipped,
    /// and pads to the data so a spike isn't flattened against the top.
    private var yDomain: ClosedRange<Double> {
        let lows = viewModel.stats.hourlyProfile.map(\.p10)
        let highs = viewModel.stats.hourlyProfile.map(\.p90)
        let low = min(60, (lows.min() ?? 70) - 10)
        let high = max(200, (highs.max() ?? 180) + 20)
        return low...high
    }

    // MARK: Day vs night

    private var dayNightTile: some View {
        collapsibleTile("dayNight", title: NSLocalizedString("Day vs Night", comment: "Tile title")) {
            let dn = viewModel.stats.dayNight
            if let night = dn.overnightMean, let day = dn.daytimeMean {
                peekLine(String(format: NSLocalizedString("Night averages %1$.0f, day %2$.0f mg/dL.", comment: "Day vs night peek"),
                                night, day))
            } else {
                peekLine(NSLocalizedString("Overnight compared with daytime.", comment: "Day vs night peek"))
            }
        } content: {
            Text("Every figure here is averaged across all the nights and days in the period shown — not a single day. Two periods can share an average and still be different problems: overnight lows and daytime spikes need opposite responses.", comment: "Day vs night explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Text("Night", comment: "Column header").font(.caption.weight(.semibold))
                    .frame(minWidth: 56, alignment: .trailing)
                Text("Day", comment: "Column header").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            let dn = viewModel.stats.dayNight
            dayNightRow(NSLocalizedString("In range", comment: "Stat"),
                        night: dn.overnightInRange.map(Self.percent),
                        day: dn.daytimeInRange.map(Self.percent))
            dayNightRow(NSLocalizedString("Below 70", comment: "Stat"),
                        night: dn.overnightBelow.map(Self.percent),
                        day: dn.daytimeBelow.map(Self.percent))
            dayNightRow(NSLocalizedString("Above 180", comment: "Stat"),
                        night: dn.overnightAbove.map(Self.percent),
                        day: dn.daytimeAbove.map(Self.percent))
            dayNightRow(NSLocalizedString("Average", comment: "Stat"),
                        night: dn.overnightMean.map { String(format: "%.0f", $0) },
                        day: dn.daytimeMean.map { String(format: "%.0f", $0) })
            dayNightRow(NSLocalizedString("Variability", comment: "Stat"),
                        night: dn.overnightCV.map { String(format: "%.0f%%", $0) },
                        day: dn.daytimeCV.map { String(format: "%.0f%%", $0) })
            dayNightRow(NSLocalizedString("Typical low point", comment: "Stat"),
                        night: dn.overnightMinimum.map { String(format: "%.0f", $0) },
                        day: dn.daytimeMinimum.map { String(format: "%.0f", $0) })
            dayNightRow(NSLocalizedString("Typical high point", comment: "Stat"),
                        night: dn.overnightMaximum.map { String(format: "%.0f", $0) },
                        day: dn.daytimeMaximum.map { String(format: "%.0f", $0) })
            Text("The last two rows average each day's own lowest and highest reading across the period — not the single most extreme value ever recorded, so one bad night doesn't come to describe every night.", comment: "Day vs night extremes note")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Night and day side by side, so the comparison is the point rather than
    /// something the reader has to assemble from two separate lists.
    private func dayNightRow(_ label: String, night: String?, day: String?) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(night ?? "—")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
            Text(day ?? "—")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    // MARK: Loop activity

    private var loopActivityTile: some View {
        tile {
            tileTitle(NSLocalizedString("How Hard Loop Is Working", comment: "Tile title"))
            Text("How often the algorithm steps in, and how far it moves from your programmed basal. A well-tuned profile needs less correcting.", comment: "Loop activity explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            statRow(NSLocalizedString("Automatic doses per day", comment: "Stat"),
                    String(format: "%.1f", viewModel.stats.loopActivity.automaticDosesPerDay))
            statRow(NSLocalizedString("Your own boluses per day", comment: "Stat"),
                    String(format: "%.1f", viewModel.stats.loopActivity.manualBolusesPerDay))
            statRow(NSLocalizedString("Basal delivered per day", comment: "Stat"),
                    String(format: "%.1f U", viewModel.stats.loopActivity.deliveredBasalPerDay))
            if let scheduled = viewModel.stats.loopActivity.scheduledBasalPerDay {
                statRow(NSLocalizedString("Your programmed basal", comment: "Stat"),
                        String(format: "%.1f U", scheduled))
                if let ratio = viewModel.stats.loopActivity.basalRatio {
                    statRow(NSLocalizedString("Delivered vs programmed", comment: "Stat"),
                            String(format: "%.0f%%", ratio * 100))
                }
            }
            if viewModel.stats.missedBolus.count > 0 {
                Divider().opacity(0.4)
                statRow(NSLocalizedString("Unexplained rises", comment: "Stat"),
                        "\(viewModel.stats.missedBolus.count)")
                Text("Climbs of 60 mg/dL or more within 90 minutes with no carbs or bolus logged nearby — usually a meal that wasn't recorded.", comment: "Missed bolus explanation")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Progress over time

    private var weeklyTrendTile: some View {
        collapsibleTile("weeklyTrend", title: NSLocalizedString("Week By Week", comment: "Tile title")) {
            if let latest = viewModel.stats.weeklyTrend.last {
                peekLine(String(format: NSLocalizedString("Latest week %@ in range.", comment: "Weekly trend peek"),
                                Self.percent(latest.inRange)))
            } else {
                peekLine(NSLocalizedString("Time in range week by week.", comment: "Weekly trend peek"))
            }
        } content: {
            Text("Time in range for each week. A single number tells you where you are; this tells you which way you're going.", comment: "Weekly trend explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            weeklyTrendSelectionReadout

            Chart(viewModel.stats.weeklyTrend) { point in
                BarMark(
                    x: .value(NSLocalizedString("Week", comment: "Chart axis"), point.weekStart, unit: .weekOfYear),
                    y: .value(NSLocalizedString("In range", comment: "Chart axis"), point.inRange * 100)
                )
                .cornerRadius(4)
                .foregroundStyle(GlucoseBandColor.inRange)
                .opacity(selectedWeekStart == nil || selectedWeekStart == point.weekStart ? 1 : 0.35)
                // ⚠️ THE NUMBER GOES ON THE BAR WHEN EXPORTING. On screen you
                // tap a column to read it; a picture cannot be tapped, so an
                // unlabelled export is a chart with its values removed.
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    exportBarLabel(Self.percent(point.inRange))
                }
                // The 70% goal, drawn once as a recessive reference rather than
                // repeated as a label on every bar.
                RuleMark(y: .value("", 70))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel()
                }
            }
            // ⚠️ NOT scrollable, for the same reason as the comparison chart: a
            // scrollable Chart swallows the tap and selection never fires. This
            // one is fed the 30-day window anyway, so it is only ever four or
            // five bars and fits comfortably.
            .chartXSelection(value: $weeklyTrendSelection)
            .chartGesture { proxy in instantSelect(proxy) }
            .onChange(of: weeklyTrendSelection) { _, newValue in
                guard let newValue else { return }
                // Same snapping problem as the comparison chart: take the last
                // week starting at or before the tap.
                selectedWeekStart = (viewModel.stats.weeklyTrend.last { $0.weekStart <= newValue }
                                     ?? viewModel.stats.weeklyTrend.first)?.weekStart
            }
            .frame(height: 130)
        }
    }

    @ViewBuilder
    private var weekdaySelectionReadout: some View {
        if let name = selectedWeekdayName,
           let point = viewModel.stats.weekdayProfile.first(where: { Self.weekdayName($0.weekday) == name }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(Self.percent(point.inRange))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(String(format: NSLocalizedString("%d days", comment: "Days in a comparison period"), point.days))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { selectedWeekdayName = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear selection", comment: "Clear the selected chart column"))
            }
        } else if !isExporting {
            // The columns carry their own numbers in an export; the invitation
            // to tap them does not survive the trip.
            Text("Tap a column to see its numbers.", comment: "Bar chart selection hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var weeklyTrendSelectionReadout: some View {
        if let start = selectedWeekStart,
           let point = viewModel.stats.weeklyTrend.first(where: { $0.weekStart == start }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.weekRangeLabel(start))
                    .font(.subheadline.weight(.semibold))
                Text(Self.percent(point.inRange))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(String(format: NSLocalizedString("%d days", comment: "Days in a comparison period"), point.days))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { selectedWeekStart = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear selection", comment: "Clear the selected chart column"))
            }
        } else if !isExporting {
            // The columns carry their own numbers in an export; the invitation
            // to tap them does not survive the trip.
            Text("Tap a column to see its numbers.", comment: "Bar chart selection hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Period comparison

    /// Week-by-week or month-by-month, on a metric of the user's choosing, with
    /// each period's change against the one before it.
    ///
    /// Descriptive only, like the rest of this screen: it reports what the log
    /// says happened and never suggests a setting change.
    private var periodComparisonTile: some View {
        let points = viewModel.comparison(comparisonGranularity)
        return collapsibleTile("compare",
                               title: NSLocalizedString("Compare Periods", comment: "Tile title"),
                               ignoresPeriod: true) {
            if let latest = points.last, points.count >= 2 {
                let previous = points[points.count - 2]
                let change = comparisonMetric.value(latest) - comparisonMetric.value(previous)
                let rounded = change.rounded()
                let direction = rounded == 0
                    ? NSLocalizedString("level with", comment: "Comparison peek, no change")
                    : (rounded > 0
                       ? String(format: NSLocalizedString("up %.0f from", comment: "Comparison peek, increase"), rounded)
                       : String(format: NSLocalizedString("down %.0f from", comment: "Comparison peek, decrease"), abs(rounded)))
                peekLine(String(format: NSLocalizedString("Latest %1$@ — %2$@ the period before.", comment: "Comparison peek"),
                                comparisonMetric.formatted(latest), direction))
            } else {
                peekLine(NSLocalizedString("Week by week, or month by month.", comment: "Comparison peek"))
            }
        } content: {
            granularityPicker
            metricPicker

            if points.count < 2 {
                // Honest empty state: say which floor was not met rather than
                // showing a lone bar and calling it a comparison.
                Text(comparisonGranularity == .week
                     ? "Not enough history yet. A week needs at least 3 days with a full day's readings, and comparing needs 2 such weeks."
                     : "Not enough history yet. A month needs at least 10 days with a full day's readings, and comparing needs 2 such months.",
                     comment: "Comparison tile empty state")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Tap a column to read it. The selected bar keeps full colour and
                // the rest step back, so the answer to "which one am I reading?"
                // is the chart itself rather than a legend.
                comparisonSelectionReadout(points)

                // Only the most recent N are PLOTTED. The chart is not scrollable
                // (see below), so plotting a year of weeks would make 50 hairline
                // bars nobody can tap. Nothing is lost: every period is listed in
                // full underneath.
                let plotted = Array(points.suffix(comparisonVisibleCount))

                Chart(plotted) { point in
                    BarMark(
                        x: .value(NSLocalizedString("Period", comment: "Chart axis"),
                                  point.start, unit: comparisonGranularity.component),
                        y: .value(comparisonMetric.title, comparisonMetric.value(point))
                    )
                    .cornerRadius(4)
                    .foregroundStyle(comparisonMetric.color)
                    .opacity(selectedPeriodStart == nil || selectedPeriodStart == point.start ? 1 : 0.35)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        exportBarLabel(comparisonMetric.formatted(point))
                    }

                    if comparisonMetric == .timeInRange {
                        // The 70% goal, drawn once as a recessive reference —
                        // same treatment as the week-by-week tile above.
                        RuleMark(y: .value("", 70))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                        AxisValueLabel()
                    }
                }
                // Scrollable rather than squashed: with a year of history this
                // chart would otherwise render 50+ hairline bars. Opens on the
                // most recent window, which is the one you care about, and you
                // drag back through time.
                // ⚠️ NOT horizontally scrollable, and that is load-bearing.
                // `chartScrollableAxes(.horizontal)` makes the scroll view eat the
                // tap, so `chartXSelection` never fires and tapping a column does
                // nothing at all. Verified in the simulator: with scrolling on,
                // taps were silently swallowed. Same conflict as the AGP scrub.
                // Recency is handled by plotting only the last N bars instead.
                .chartXSelection(value: $comparisonSelection)
                .chartGesture { proxy in instantSelect(proxy) }
                // Snap the raw x-position to the period that actually contains
                // it: Charts hands back a point on the axis, not a bar.
                .onChange(of: comparisonSelection) { _, newValue in
                    guard let newValue else { return }
                    selectedPeriodStart = Self.period(containing: newValue, in: plotted)?.start
                }
                .frame(height: 140)

                // Newest first: the period you care about is the one you are in.
                VStack(spacing: 0) {
                    ForEach(Array(points.enumerated().reversed()), id: \.element.id) { index, point in
                        comparisonPeriodRow(point, previous: index > 0 ? points[index - 1] : nil)
                        if point.id != points.first?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    /// The period whose bucket contains `date`.
    ///
    /// `chartXSelection` reports a position on the axis, which almost never
    /// equals a period's start. Matching on equality therefore selects nothing;
    /// this takes the last period starting at or before the tap.
    private static func period(containing date: Date,
                               in points: [HistoryStatistics.PeriodPoint]) -> HistoryStatistics.PeriodPoint? {
        points.last { $0.start <= date } ?? points.first
    }

    /// Numbers for the tapped column. Shows every metric, not just the plotted
    /// one — having tapped a period, "what else was true that month?" is the
    /// next question, and the answer is already computed.
    @ViewBuilder
    private func comparisonSelectionReadout(_ points: [HistoryStatistics.PeriodPoint]) -> some View {
        if let start = selectedPeriodStart,
           let point = points.first(where: { $0.start == start }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(comparisonPeriodLabel(point))
                        .font(.subheadline.weight(.semibold))
                    Text(comparisonMetric.formatted(point))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Button {
                        selectedPeriodStart = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear selection", comment: "Clear the selected chart column"))
                }
                Text(String(format: NSLocalizedString("%1$.0f%% in range · avg %2$.0f · CV %3$.0f%% · %4$d days", comment: "Selected period detail"),
                            point.inRange * 100, point.mean, point.coefficientOfVariation, point.days))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !isExporting {
            // The columns carry their own numbers in an export; the invitation
            // to tap them does not survive the trip.
            Text("Tap a column to see its numbers.", comment: "Bar chart selection hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// How many of the most recent periods the chart plots.
    ///
    /// Bars must stay wide enough to hit with a finger, so the chart shows a
    /// window rather than all of history. The rows below it are not limited.
    private var comparisonVisibleCount: Int {
        comparisonGranularity == .week ? 8 : 6
    }

    private var granularityPicker: some View {
        HStack(spacing: 8) {
            ForEach(HistoryStatistics.PeriodGranularity.allCases) { granularity in
                let isSelected = comparisonGranularity == granularity
                Button { comparisonGranularity = granularity } label: {
                    Text(granularity == .week
                         ? NSLocalizedString("Week by Week", comment: "Comparison granularity")
                         : NSLocalizedString("Month by Month", comment: "Comparison granularity"))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(GlassButtonStyle(
                    isSelected ? .regular.tint(Color.loopSelectionTint).interactive() : .regular.interactive(),
                    in: Capsule()))
            }
        }
    }

    private var metricPicker: some View {
        HStack(spacing: 6) {
            ForEach(ComparisonMetric.allCases) { metric in
                let isSelected = comparisonMetric == metric
                Button { comparisonMetric = metric } label: {
                    Text(metric.title)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(GlassButtonStyle(
                    isSelected ? .regular.tint(Color.loopSelectionTint).interactive() : .regular.interactive(),
                    in: Capsule()))
            }
        }
    }

    /// One period, its value, and the change against the period before it.
    private func comparisonPeriodRow(_ point: HistoryStatistics.PeriodPoint,
                                     previous: HistoryStatistics.PeriodPoint?) -> some View {
        let change = previous.map { comparisonMetric.value(point) - comparisonMetric.value($0) }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(comparisonPeriodLabel(point))
                    .font(.subheadline)
                // Days behind the number, so a thin period is visibly thin
                // rather than quietly equal to a full one.
                Text(String(format: NSLocalizedString("%d days", comment: "Days in a comparison period"), point.days))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(comparisonMetric.formatted(point))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            comparisonChangeLabel(change)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func comparisonChangeLabel(_ change: Double?) -> some View {
        if let change {
            let isNoise = abs(change) < comparisonMetric.meaningfulChange
            let improved = comparisonMetric.higherIsBetter ? change > 0 : change < 0
            let unit = comparisonMetric == .average ? "" : "pp"
            // Round BEFORE formatting. "%.0f" on -0.4 prints "-0", which reads as
            // a decline that didn't happen; a rounded-to-nothing change is shown
            // as ±0 instead, with no direction implied.
            let rounded = change.rounded()
            let text = rounded == 0
                ? "±0\(unit)"
                : String(format: "%@%.0f%@", rounded > 0 ? "+" : "", rounded, unit)
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isNoise ? Color.secondary
                                 : (improved ? guidanceColors.acceptable : guidanceColors.warning))
        } else {
            // First period in the series — nothing before it to compare against.
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Weeks read as a span ("6 – 12 Jul"), not a single start date: a bare start
    /// date makes the reader work out where the week ended, and the last week in
    /// the list is usually a partial one.
    ///
    /// The end is the last day INSIDE the period (start + length − 1 day), taken
    /// from the calendar's own interval rather than assuming seven days, so it
    /// stays right across DST and under a non-Gregorian calendar.
    private func comparisonPeriodLabel(_ point: HistoryStatistics.PeriodPoint) -> String {
        switch point.granularity {
        case .week:
            return Self.weekRangeLabel(point.start)
        case .month:
            return StatsReportModel.monthYearFormatter.string(from: point.start)
        }
    }

    /// "28 Jun – 4 Jul", or "19 – 25 Jul" when both ends share a month.
    ///
    /// Shared by the comparison rows and the Week By Week readout so the same
    /// week is never labelled two different ways on one screen.
    static func weekRangeLabel(_ start: Date) -> String {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: start) else {
            return DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .none)
        }
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let dayOnly = StatsReportModel.dayOnlyFormatter
        let dayMonth = StatsReportModel.dayMonthFormatter
        let sameMonth = calendar.isDate(start, equalTo: last, toGranularity: .month)
        let startText = sameMonth ? dayOnly.string(from: start) : dayMonth.string(from: start)
        return "\(startText) – \(dayMonth.string(from: last))"
    }

    // MARK: Meal size

    private var mealSizeTile: some View {
        tile {
            tileTitle(NSLocalizedString("By Meal Size", comment: "Tile title"))
            let maximum = viewModel.stats.mealSizeOutcomes.map(\.averageRise).max() ?? 1
            ForEach(viewModel.stats.mealSizeOutcomes) { outcome in
                comparisonRow(outcome.label,
                              rise: outcome.averageRise,
                              count: outcome.count,
                              maximum: maximum,
                              color: Color.accentColor)
            }
        }
    }

    // MARK: Bedtime

    private var bedtimeTile: some View {
        tile {
            tileTitle(NSLocalizedString("Bedtime & Overnight", comment: "Tile title"))
            Text("How often a night went low, grouped by the glucose you went to bed on.", comment: "Bedtime explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(viewModel.stats.bedtimeOutcomes) { outcome in
                HStack {
                    Text(outcome.label).font(.subheadline)
                    Spacer()
                    Text(String(format: NSLocalizedString("%1$@ of %2$d nights", comment: "Low rate and night count"),
                                Self.percent(outcome.lowRate), outcome.nights))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text("This describes your own nights. It is not a target to aim for — that conversation belongs with your care team.", comment: "Bedtime caveat")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Weekday pattern

    private var weekdayTile: some View {
        collapsibleTile("weekday", title: NSLocalizedString("Day Of The Week", comment: "Tile title")) {
            // ⚠️ ONLY NAME A WEAKEST DAY IF ONE ACTUALLY STANDS OUT. Taking the
            // minimum of seven near-identical numbers picks a day out of noise
            // and states it as a finding — with every weekday tied at 75% this
            // printed "Sun is your weakest day, 75% in range", which is true of
            // all seven days and useful about none of them.
            let profile = viewModel.stats.weekdayProfile
            if let worst = profile.min(by: { $0.inRange < $1.inRange }),
               let best = profile.max(by: { $0.inRange < $1.inRange }),
               (best.inRange - worst.inRange) >= Self.weekdayStandoutMargin {
                peekLine(String(format: NSLocalizedString("%1$@ is your weakest day, %2$@ in range.", comment: "Weekday peek"),
                                Self.weekdayName(worst.weekday), Self.percent(worst.inRange)))
            } else if !profile.isEmpty {
                peekLine(NSLocalizedString("No weekday stands out — your days look alike.", comment: "Weekday peek when days are level"))
            } else {
                peekLine(NSLocalizedString("Time in range by weekday.", comment: "Weekday peek"))
            }
        } content: {
            Text("Time in range by weekday. Routine shows up here — a day that repeatedly goes worse is usually about what happens on that day, not about diabetes.", comment: "Weekday explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            weekdaySelectionReadout

            Chart(viewModel.stats.weekdayProfile) { point in
                BarMark(
                    x: .value(NSLocalizedString("Day", comment: "Chart axis"), Self.weekdayName(point.weekday)),
                    y: .value(NSLocalizedString("In range", comment: "Chart axis"), point.inRange * 100)
                )
                .cornerRadius(4)
                .foregroundStyle(GlucoseBandColor.inRange)
                .opacity(selectedWeekdayName == nil
                         || selectedWeekdayName == Self.weekdayName(point.weekday) ? 1 : 0.35)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    exportBarLabel(Self.percent(point.inRange))
                }
            }
            // Categorical axis, so the selection IS the bar's name — no snapping
            // needed here, unlike the two date-axis charts.
            .chartXSelection(value: $weekdaySelection)
            .chartGesture { proxy in instantSelect(proxy) }
            .onChange(of: weekdaySelection) { _, newValue in
                if let newValue { selectedWeekdayName = newValue }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 70, 100]) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            // DELIBERATELY NOT SCROLLABLE. This axis is CATEGORICAL (weekday
            // names), and `chartXVisibleDomain(length: 7)` does not mean "seven
            // bars" there — it clipped Sunday off the end and left dead space,
            // i.e. it hid a day's data. Seven bars fit a phone width anyway, so
            // there is nothing to gain. Don't "restore" scrolling here.
            .frame(height: 130)
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        StatsReportModel.weekdayName(weekday)
    }

    // MARK: Behaviour → outcome

    private var postMealTile: some View {
        tile {
            tileTitle(NSLocalizedString("After Meals", comment: "Tile title"))

            if let rise = viewModel.stats.postMeal.averageRise {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "+%.0f", rise))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("mg/dL", comment: "Unit")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: NSLocalizedString("Typical peak rise in the 3 hours after eating, across %d meals.", comment: "Post-meal rise explanation"),
                            viewModel.stats.postMeal.mealsAnalysed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let timeToPeak = viewModel.stats.postMeal.medianTimeToPeak {
                    statRow(NSLocalizedString("Typically peaks after", comment: "Stat"),
                            Self.minutes(timeToPeak))
                }
                if let back = viewModel.stats.postMeal.medianTimeToReturn {
                    statRow(NSLocalizedString("Back under 180 after", comment: "Stat"),
                            Self.minutes(back))
                }
            }

            if let prompt = viewModel.stats.postMeal.promptRise,
               let late = viewModel.stats.postMeal.lateRise {
                Divider().opacity(0.4)
                Text("Logged on time vs. late", comment: "Prompt vs late header")
                    .font(.subheadline.weight(.medium))
                comparisonRow(NSLocalizedString("Within 15 min", comment: "Prompt meals"),
                              rise: prompt,
                              count: viewModel.stats.postMeal.promptCount,
                              maximum: max(prompt, late),
                              color: guidanceColors.acceptable)
                comparisonRow(NSLocalizedString("Later than that", comment: "Late meals"),
                              rise: late,
                              count: viewModel.stats.postMeal.lateCount,
                              maximum: max(prompt, late),
                              color: guidanceColors.warning)
                Text("Both are your own meals — the difference is only when you logged them.", comment: "Prompt vs late caveat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func comparisonRow(_ label: String, rise: Double, count: Int,
                               maximum: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: NSLocalizedString("+%1$.0f mg/dL · %2$d meals", comment: "Rise and meal count"), rise, count))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(color)
                    .frame(width: maximum > 0 ? max(4, geometry.size.width * (rise / maximum)) : 4)
            }
            .frame(height: 8)
        }
    }

    // MARK: Days & goals

    private var daysTile: some View {
        tile {
            tileTitle(NSLocalizedString("Day By Day", comment: "Tile title"))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(viewModel.stats.days.meetingGoal)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: NSLocalizedString("of %d days hit 70%% in range", comment: "Days meeting goal"),
                            viewModel.stats.days.counted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if viewModel.stats.days.bestStreak >= 2 {
                Label(String(format: NSLocalizedString("Best run: %d days in a row.", comment: "Best streak"),
                             viewModel.stats.days.bestStreak),
                      systemImage: "flame")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let weekday = viewModel.stats.days.weekdayInRange,
               let weekend = viewModel.stats.days.weekendInRange,
               abs(weekday - weekend) >= 0.03 {
                Divider().opacity(0.4)
                // The counts travel with the numbers: "70% at weekends" means
                // something different over 3 weekend days than over 12.
                statRow(NSLocalizedString("Weekdays (Sun–Thu)", comment: "Stat"),
                        String(format: NSLocalizedString("%1$@ · %2$d days", comment: "Stat with day count"),
                               Self.percent(weekday), viewModel.stats.days.weekdayCount))
                // The days are named in the label because the split is FIXED at
                // Fri–Sat and no longer follows the device region — so the reader
                // can see which days each number is actually made of.
                statRow(NSLocalizedString("Weekends (Fri–Sat)", comment: "Stat"),
                        String(format: NSLocalizedString("%1$@ · %2$d days", comment: "Stat with day count"),
                               Self.percent(weekend), viewModel.stats.days.weekendCount))
            }
            Text("Only days with a reasonable amount of sensor data are counted.", comment: "Days caveat")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Safety — lows and nights

    private var safetyTile: some View {
        tile {
            tileTitle(NSLocalizedString("Lows", comment: "Tile title"))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(viewModel.stats.lowEvents.count)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(NSLocalizedString("low events", comment: "Low events label"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if viewModel.stats.lowEvents.level2Count > 0 {
                statRow(NSLocalizedString("Serious (under 54)", comment: "Stat"),
                        "\(viewModel.stats.lowEvents.level2Count)")
            }
            if let duration = viewModel.stats.lowEvents.averageDuration {
                statRow(NSLocalizedString("Typical length", comment: "Stat"), Self.minutes(duration))
            }
            if viewModel.stats.lowEvents.perWeek > 0 {
                statRow(NSLocalizedString("Per week", comment: "Stat"),
                        String(format: "%.1f", viewModel.stats.lowEvents.perWeek))
            }
            if viewModel.stats.nights.total > 0 {
                statRow(NSLocalizedString("Nights with a low", comment: "Stat"),
                        String(format: NSLocalizedString("%1$d of %2$d", comment: "x of y nights"),
                               viewModel.stats.nights.withLow, viewModel.stats.nights.total))
            }
            if viewModel.stats.highEvents.count > 0 {
                Divider().opacity(0.4)
                statRow(NSLocalizedString("Highs over 250", comment: "Stat"),
                        "\(viewModel.stats.highEvents.count)")
                if let duration = viewModel.stats.highEvents.averageDuration {
                    statRow(NSLocalizedString("Typical length", comment: "Stat"), Self.minutes(duration))
                }
            }
            Text("Counted the way the CGM consensus defines an event: at least 15 minutes past the threshold to start one, and 15 minutes back to end it — so a single stray reading isn't a low.", comment: "Event definition explanation")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Meal windows

    private var mealWindowsTile: some View {
        tile {
            tileTitle(NSLocalizedString("Which Meal", comment: "Tile title"))
            Text("Average rise after each meal of the day. Breakfast often behaves differently from the rest — an all-meals average hides exactly that.", comment: "Meal windows explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            let maximum = viewModel.stats.mealWindows.map(\.averageRise).max() ?? 1
            ForEach(viewModel.stats.mealWindows) { window in
                comparisonRow(window.name,
                              rise: window.averageRise,
                              count: window.count,
                              maximum: maximum,
                              color: Color.accentColor)
            }
        }
    }

    // MARK: Risk indices

    private var riskTile: some View {
        tile {
            tileTitle(NSLocalizedString("Risk Indices", comment: "Tile title"))
            Text("Published measures that weight readings by how dangerous they are, rather than counting them equally — 50 mg/dL is far worse than twice as bad as 65.", comment: "Risk indices explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let gri = viewModel.stats.risk.gri {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.0f", gri))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("GRI", comment: "Glycemia Risk Index abbreviation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.griZone(gri))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.loopControlTint))
                    }
                    // The split matters more than the total: it says WHICH end is
                    // driving the score, and the two need opposite responses.
                    if let hypo = viewModel.stats.risk.griHypoComponent,
                       let hyper = viewModel.stats.risk.griHyperComponent {
                        Text(String(format: NSLocalizedString("Driven by lows %1$.0f · highs %2$.0f", comment: "GRI components"),
                                    hypo, hyper))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Glycemia Risk Index, 0–100, lower is better. It weights severe lows and highs harder than mild ones, and tracked specialists' own ranking of CGM traces more closely than time in range did.", comment: "GRI explanation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Divider().opacity(0.4)
            }

            riskRow(NSLocalizedString("Low risk (LBGI)", comment: "Stat"),
                    value: viewModel.stats.risk.lbgi,
                    bands: [(1.1, NSLocalizedString("minimal", comment: "")),
                            (2.5, NSLocalizedString("low", comment: "")),
                            (5.0, NSLocalizedString("moderate", comment: ""))],
                    aboveLabel: NSLocalizedString("high", comment: ""))
            riskRow(NSLocalizedString("High risk (HBGI)", comment: "Stat"),
                    value: viewModel.stats.risk.hbgi,
                    bands: [(4.5, NSLocalizedString("low", comment: "")),
                            (9.0, NSLocalizedString("moderate", comment: ""))],
                    aboveLabel: NSLocalizedString("high", comment: ""))
            if let adrr = viewModel.stats.risk.adrr {
                riskRow(NSLocalizedString("Daily swing (ADRR)", comment: "Stat"),
                        value: adrr,
                        bands: [(20, NSLocalizedString("low", comment: "")),
                                (40, NSLocalizedString("moderate", comment: ""))],
                        aboveLabel: NSLocalizedString("high", comment: ""))
            }
            Text("Categories are the conventional published bands, not a judgement about you.", comment: "Risk bands caveat")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// A value plus the band it falls in, so the number means something without
    /// the reader having to know the literature.
    private func riskRow(_ label: String, value: Double,
                         bands: [(Double, String)], aboveLabel: String) -> some View {
        let category = bands.first { value < $0.0 }?.1 ?? aboveLabel
        return HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(category)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.loopControlTint))
            Text(String(format: "%.1f", value))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    // MARK: Variability & recovery

    private var variabilityTile: some View {
        tile {
            tileTitle(NSLocalizedString("Stability", comment: "Tile title"))
            if let modd = viewModel.stats.risk.modd {
                labelledStat(NSLocalizedString("Day-to-day repeatability", comment: "Stat"),
                             String(format: "%.0f mg/dL", modd),
                             NSLocalizedString("Typical gap between the same time on consecutive days. Smaller means your days look alike — which is what makes anything predictable.", comment: "MODD explanation"))
            }
            if let mage = viewModel.stats.risk.mage {
                labelledStat(NSLocalizedString("Swing size (MAGE)", comment: "Stat"),
                             String(format: "%.0f mg/dL", mage),
                             NSLocalizedString("Average size of your significant rises and falls.", comment: "MAGE explanation"))
            }
            if let conga = viewModel.stats.risk.conga2 {
                labelledStat(NSLocalizedString("2-hour instability", comment: "Stat"),
                             String(format: "%.0f mg/dL", conga),
                             NSLocalizedString("How different a reading typically is from two hours earlier.", comment: "CONGA explanation"))
            }
            if let rebound = viewModel.stats.recovery.lowsFollowedByHigh {
                labelledStat(NSLocalizedString("Lows chased by a high", comment: "Stat"),
                             Self.percent(rebound),
                             String(format: NSLocalizedString("Of %d lows, this share climbed above 180 within two hours — the usual sign of over-treating.", comment: "Rebound explanation"),
                                    viewModel.stats.recovery.lowsAnalysed))
            }
            if let recoveryTime = viewModel.stats.recovery.medianHighRecovery {
                labelledStat(NSLocalizedString("Recovery from a high", comment: "Stat"),
                             Self.minutes(recoveryTime),
                             String(format: NSLocalizedString("Typical time from above 250 back under 180, over %d excursions.", comment: "High recovery explanation"),
                                    viewModel.stats.recovery.highExcursions))
            }
        }
    }

    private func labelledStat(_ label: String, _ value: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 2)
    }

    // MARK: Supply

    private var supplyTile: some View {
        tile {
            statRow(NSLocalizedString("Insulin per day", comment: "Stat"),
                    String(format: "%.1f U", viewModel.stats.insulin.dailyAverage))
            statRow(NSLocalizedString("Given as bolus", comment: "Stat"),
                    String(format: "%.0f%%", viewModel.stats.insulin.bolusShare * 100))
            statRow(NSLocalizedString("Insulin Loop gave itself", comment: "Stat"),
                    String(format: "%.0f%%", viewModel.stats.insulin.totalUnits > 0
                           ? viewModel.stats.insulin.automaticUnits / viewModel.stats.insulin.totalUnits * 100 : 0))
            statRow(NSLocalizedString("Carbs per day", comment: "Stat"),
                    String(format: "%.0f g", viewModel.stats.meals.dailyAverageGrams))
            statRow(NSLocalizedString("Meals per day", comment: "Stat"),
                    String(format: "%.1f", viewModel.stats.mealsPerDay))
            statRow(NSLocalizedString("Carbs per meal", comment: "Stat"),
                    String(format: "%.0f g", viewModel.stats.gramsPerMeal))
            if let delay = viewModel.stats.meals.medianLoggingDelay {
                statRow(NSLocalizedString("Typical logging delay", comment: "Stat"), Self.minutes(delay))
            }
            if viewModel.stats.sensorGaps.count > 0 {
                Divider().opacity(0.4)
                statRow(NSLocalizedString("Sensor gaps", comment: "Stat"),
                        "\(viewModel.stats.sensorGaps.count)")
                if let longest = viewModel.stats.sensorGaps.longest {
                    statRow(NSLocalizedString("Longest gap", comment: "Stat"), Self.minutes(longest))
                }
            }
            if viewModel.stats.pods.count > 0 {
                Divider().opacity(0.4)
                statRow(NSLocalizedString("Pod sessions", comment: "Stat"), "\(viewModel.stats.pods.count)")
                statRow(NSLocalizedString("Average pod life", comment: "Stat"),
                        String(format: "%.0f h", viewModel.stats.pods.meanHours))
                statRow(NSLocalizedString("Insulin discarded", comment: "Stat"),
                        String(format: "%.0f U", viewModel.stats.pods.wastedUnits))
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Observations

    @ViewBuilder
    private var observationsTile: some View {
        let observations = Self.observations(for: viewModel.stats)
        if !observations.isEmpty {
            tile {
                tileTitle(NSLocalizedString("Worth Noticing", comment: "Observations title"))
                ForEach(observations, id: \.self) { text in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 6)
                        Text(text).font(.subheadline)
                    }
                }
                Text("These describe patterns in your own data over the period shown. They are not medical advice and do not suggest settings — take them to your care team.", comment: "Observations caveat")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Deliberately few, deliberately conservative, and every one states the
    /// number it rests on. None recommends a setting change.
    static func observations(for stats: HistoryStatistics) -> [String] {
        var result: [String] = []

        if let overnight = stats.glucose.overnightMean,
           let daytime = stats.glucose.daytimeMean,
           abs(overnight - daytime) >= 20 {
            let higher = overnight > daytime
            result.append(String(
                format: NSLocalizedString("Overnight readings averaged %1$.0f mg/dL against %2$.0f in the day — %3$@ overnight.", comment: "Observation: overnight vs daytime"),
                overnight, daytime,
                higher ? NSLocalizedString("consistently higher", comment: "") : NSLocalizedString("consistently lower", comment: "")))
        }

        if let prompt = stats.postMeal.promptRise, let late = stats.postMeal.lateRise,
           late - prompt >= 15 {
            result.append(String(
                format: NSLocalizedString("Meals logged within 15 minutes rose %1$.0f mg/dL on average; meals logged later rose %2$.0f.", comment: "Observation: logging delay effect"),
                prompt, late))
        }

        if stats.glucose.count > 0, stats.glucose.coefficientOfVariation > 36 {
            result.append(String(
                format: NSLocalizedString("Glucose variability was %.0f%%. Above about 36%% is generally described as high, meaning readings swing widely around the average.", comment: "Observation: high CV"),
                stats.glucose.coefficientOfVariation))
        }

        let belowRange = stats.glucose.veryLow + stats.glucose.low
        if stats.glucose.count > 0, belowRange > 0.04 {
            result.append(String(
                format: NSLocalizedString("You were below 70 mg/dL for %.0f%% of readings. The commonly cited target is under 4%%.", comment: "Observation: time below range"),
                belowRange * 100))
        }

        if let rise = stats.dawn.averageRise, stats.dawn.daysMeasured >= 5, rise >= 25 {
            result.append(String(
                format: NSLocalizedString("Glucose climbed %1$.0f mg/dL on average between 3am and 8am, across %2$d days — a dawn pattern.", comment: "Observation: dawn phenomenon"),
                rise, stats.dawn.daysMeasured))
        }

        if let weekday = stats.days.weekdayInRange, let weekend = stats.days.weekendInRange,
           abs(weekday - weekend) >= 0.08 {
            let better = weekday > weekend
            result.append(String(
                format: NSLocalizedString("Time in range was %1$.0f%% across %2$d weekdays against %3$.0f%% across %4$d weekend days — %5$@ tend to go better.", comment: "Observation: weekday vs weekend"),
                weekday * 100, stats.days.weekdayCount,
                weekend * 100, stats.days.weekendCount,
                better ? NSLocalizedString("weekdays", comment: "") : NSLocalizedString("weekends", comment: "")))
        }

        if stats.coverage.expected > 0, stats.coverage.fraction < 0.7 {
            result.append(String(
                format: NSLocalizedString("Only %.0f%% of expected sensor readings were recorded, so treat the numbers above as a rough picture rather than a precise one.", comment: "Observation: low coverage"),
                stats.coverage.fraction * 100))
        }

        if stats.pods.count >= 5, stats.pods.faultRate > 0.2 {
            result.append(String(
                format: NSLocalizedString("%1$.0f%% of your %2$d pod sessions ended in a fault.", comment: "Observation: pod fault rate"),
                stats.pods.faultRate * 100, stats.pods.count))
        }

        return result
    }

    // MARK: Share

    @ViewBuilder
    private var shareButton: some View {
        if !isExporting {
            VStack(spacing: 10) {
                Button {
                    shareFullReport()
                } label: {
                    Label(isPreparingFullReport
                          ? NSLocalizedString("Preparing…", comment: "Full report is being built")
                          : NSLocalizedString("Share Full Report", comment: "Share the whole statistics screen"),
                          systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle(.primary))
                .disabled(isPreparingFullReport || !viewModel.hasData)

                Text("A single web page holding every section — and every time period, so whoever opens it can switch between 7 days and all history for themselves. Individual sections share as a picture, fixed at the period you are looking at now.",
                     comment: "Explanation of the two share shapes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ShareLink(item: Self.summaryText(viewModel.stats, period: viewModel.period)) {
                    Label(NSLocalizedString("Share Text Summary", comment: "Share the statistics summary as text"),
                          systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle(.secondary))

                liveReportBlock
            }
            .padding(.top, 4)
        }
    }

    /// The self-updating copy.
    ///
    /// ⚠️ THE COPY HERE IS DELIBERATELY UNGLAMOROUS about what this does. It is
    /// not hosting, there is no link that stays fresh on its own, and it stops
    /// updating the moment the phone does. Every one of those is a way a reader
    /// could be misled into trusting an old number, so each is stated rather than
    /// left for them to discover.
    private var liveReportBlock: some View {
        tile {
            Toggle(isOn: $liveReport.isEnabled) {
                Text("Keep A Live Copy", comment: "Live report toggle")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!HistoryLogStore.shared.isEnabled)

            Text("Loop rewrites one file — “\(StatsLiveReport.fileName)” — in the same folder as your history log. Share that file once and it keeps showing current numbers instead of the day you sent it.",
                 comment: "Live report explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !HistoryLogStore.shared.isEnabled {
                Label(NSLocalizedString("Turn on the history log first — that is what decides where the file goes.", comment: "Live report needs the log"),
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if liveReport.isEnabled {
                if let error = liveReport.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let written = liveReport.lastWritten {
                    statRow(NSLocalizedString("Last written", comment: "Stat"),
                            Self.exportStampFormatter.string(from: written))
                }
                if !liveReport.isInICloud {
                    // Saying this plainly beats letting someone wonder why the
                    // file never appears on their other device.
                    Label(NSLocalizedString("Saved inside Loop rather than iCloud Drive, so it can only be shared from this phone.", comment: "Live report is local"),
                          systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if liveReport.isWaitingForBattery {
                    // Named plainly. A feature that quietly does nothing is
                    // indistinguishable from a broken one, and the reason here is
                    // one the user can actually act on.
                    Label(String(format: NSLocalizedString("Paused below %.0f%% battery — it will update as soon as you charge.", comment: "Live report is waiting for battery"),
                                 StatsLiveReport.batteryFloor * 100),
                          systemImage: "battery.25")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("It updates about every 2 hours while Loop is running, and only while your battery is above 40% — this phone is running your pump, and a statistics file does not get to spend that charge. It does not update while your phone is asleep; the page says so itself, next to the time it was written.",
                     comment: "Live report update cadence")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    liveReport.refresh(force: true)
                } label: {
                    Label(liveReport.isRefreshing
                          ? NSLocalizedString("Updating…", comment: "Live report is refreshing")
                          : NSLocalizedString("Update Now", comment: "Force a live report refresh"),
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle(.secondary))
                .disabled(liveReport.isRefreshing)

                if let url = liveReport.fileURL, liveReport.lastWritten != nil {
                    ShareLink(item: url) {
                        Label(NSLocalizedString("Send The Live File", comment: "Share the live report file"),
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillActionButtonStyle(.secondary))
                }
            }
        }
    }

    // MARK: Preparing a share

    /// Share one chapter.
    ///
    /// Picture or web page is decided by the CHAPTER, not by a menu: a chapter
    /// carrying a control with several options (Compare Periods) cannot be
    /// honestly flattened into one image, so it goes as HTML where its controls
    /// still work. Everything else is a picture, which is what people actually
    /// want to paste into a message.
    private func share(_ section: StatsReportModel.SectionID) {
        guard preparingSection == nil, !isPreparingFullReport else { return }
        preparingSection = section

        // A hop through the main queue so the spinner is on screen before the
        // render begins — `ImageRenderer` is synchronous and blocks it.
        Task { @MainActor in
            await Task.yield()
            defer { preparingSection = nil }

            if section.needsInteractivity {
                let model = viewModel.currentReportModel()
                let html = StatsHTMLReport.section(section,
                                                   model: model,
                                                   weeklyComparison: viewModel.weeklyComparison,
                                                   monthlyComparison: viewModel.monthlyComparison,
                                                   generated: Date())
                guard let url = StatsShareRenderer.write(Data(html.utf8),
                                                         named: "loop-\(section.rawValue)",
                                                         extension: "html") else {
                    shareFailed = true
                    return
                }
                sharePayload = StatsSharePayload(urls: [url], text: nil)
            } else {
                guard let url = StatsShareRenderer.image(of: section, viewModel: viewModel) else {
                    shareFailed = true
                    return
                }
                sharePayload = StatsSharePayload(urls: [url], text: nil)
            }
        }
    }

    /// The whole screen, every period, as one web page.
    private func shareFullReport() {
        guard !isPreparingFullReport, preparingSection == nil else { return }
        isPreparingFullReport = true

        Task { @MainActor in
            defer { isPreparingFullReport = false }
            let models = await viewModel.fullReportModels()
            let html = StatsHTMLReport.full(
                models: models.map { (id: $0.id, title: $0.title, longTitle: $0.longTitle, model: $0.model) },
                weeklyComparison: viewModel.weeklyComparison,
                monthlyComparison: viewModel.monthlyComparison,
                selected: viewModel.period.rawValue,
                generated: Date())
            guard let url = StatsShareRenderer.write(Data(html.utf8),
                                                     named: "loop-statistics",
                                                     extension: "html") else {
                shareFailed = true
                return
            }
            sharePayload = StatsSharePayload(
                urls: [url],
                text: Self.summaryText(viewModel.stats, period: viewModel.period))
        }
    }

    static func summaryText(_ stats: HistoryStatistics,
                            period: HistoryStatisticsViewModel.Period) -> String {
        var lines = ["Loop history summary — \(period.title)"]
        if let first = stats.firstDate, let last = stats.lastDate {
            lines.append("\(dayFormatter.string(from: first)) – \(dayFormatter.string(from: last))")
        }
        lines.append("")
        if stats.glucose.count > 0 {
            lines.append("Glucose (\(stats.glucose.count) readings)")
            lines.append(String(format: "  In range 70–180: %.0f%%", stats.glucose.inRange * 100))
            lines.append(String(format: "  Below 70: %.0f%%   Above 180: %.0f%%",
                                (stats.glucose.veryLow + stats.glucose.low) * 100,
                                (stats.glucose.high + stats.glucose.veryHigh) * 100))
            lines.append(String(format: "  Average: %.0f mg/dL   GMI: %.1f%%   CV: %.0f%%",
                                stats.glucose.mean, stats.glucose.gmi,
                                stats.glucose.coefficientOfVariation))
        }
        if let rise = stats.postMeal.averageRise {
            lines.append(String(format: "  Post-meal rise: +%.0f mg/dL over %d meals",
                                rise, stats.postMeal.mealsAnalysed))
        }
        if stats.nights.total > 0 {
            lines.append(String(format: "  Nights with a low: %d of %d",
                                stats.nights.withLow, stats.nights.total))
        }
        lines.append("")
        lines.append(String(format: "Insulin: %.1f U/day (%.0f%% bolus)",
                            stats.insulin.dailyAverage, stats.insulin.bolusShare * 100))
        lines.append(String(format: "Carbs: %.0f g/day over %d entries",
                            stats.meals.dailyAverageGrams, stats.meals.entryCount))
        if stats.pods.count > 0 {
            lines.append(String(format: "Pods: %d sessions, %.0f h average, %.0f U discarded",
                                stats.pods.count, stats.pods.meanHours, stats.pods.wastedUnits))
        }
        lines.append("")
        lines.append("Not medical advice. Discuss any changes with your care team.")
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// GRI quintile zones from the published GRI Grid: best (0–20th percentile)
    /// through worst (81st–100th).
    static func griZone(_ gri: Double) -> String {
        switch gri {
        case ..<20:  return NSLocalizedString("best zone", comment: "GRI zone")
        case ..<40:  return NSLocalizedString("2nd zone", comment: "GRI zone")
        case ..<60:  return NSLocalizedString("3rd zone", comment: "GRI zone")
        case ..<80:  return NSLocalizedString("4th zone", comment: "GRI zone")
        default:     return NSLocalizedString("worst zone", comment: "GRI zone")
        }
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func hourLabel(_ hour: Int) -> String {
        StatsReportModel.hourLabel(hour)
    }

    private static func minutes(_ interval: TimeInterval) -> String {
        let total = Int(interval / 60)
        if total < 60 { return String(format: NSLocalizedString("%d min", comment: "Minutes"), total) }
        return String(format: NSLocalizedString("%1$d h %2$d min", comment: "Hours and minutes"),
                      total / 60, total % 60)
    }
}

// MARK: - Week glucose chart

/// The last 7 days of glucose, 24 hours at a time. Scroll sideways through the
/// week; the line in the middle stays put and the reading under it is shown
/// above the chart, like scrubbing the main screen's chart.
struct GlucoseWeekChartView: View {
    @ObservedObject var viewModel: HistoryStatisticsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var points: [HistoryStatisticsViewModel.GlucosePoint]?
    /// Leading edge of the visible 24 hours. Opens with the middle line on now.
    @State private var scrollPosition = Date().addingTimeInterval(-Self.visibleLength / 2)

    private static let visibleLength: TimeInterval = 24 * 60 * 60
    /// A reading further than this from the middle line is not "at" it.
    private static let nearestReadingLimit: TimeInterval = 10 * 60

    /// Today and the 6 days before it, like the "7d" statistics.
    private let start: Date = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86400)
    }()
    private let end = Date()

    /// Half a window of room at each end, so the middle line can reach the first
    /// and the latest reading rather than stopping 12 hours short of them.
    private var domain: ClosedRange<Date> {
        start.addingTimeInterval(-Self.visibleLength / 2)...end.addingTimeInterval(Self.visibleLength / 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let points {
                        if points.isEmpty {
                            Text("No glucose readings in the last 7 days.", comment: "Week chart with no data")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            readout(points)
                            chart(points)
                            summary(points)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text("Last 7 Days", comment: "Title of the week glucose chart"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done", comment: "Close the week glucose chart").fontWeight(.semibold)
                    }
                }
            }
            .task {
                points = await viewModel.glucose(since: start)
            }
        }
    }

    private var middle: Date { scrollPosition.addingTimeInterval(Self.visibleLength / 2) }

    /// The reading closest to the middle line, if one is close enough.
    private func reading(at date: Date, in points: [HistoryStatisticsViewModel.GlucosePoint]) -> HistoryStatisticsViewModel.GlucosePoint? {
        // Binary search: the first reading at or after `date`, then its neighbour.
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { points.indices.contains($0) }.map { points[$0] }
        guard let nearest = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= Self.nearestReadingLimit else { return nil }
        return nearest
    }

    private func readout(_ points: [HistoryStatisticsViewModel.GlucosePoint]) -> some View {
        let current = reading(at: middle, in: points)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let current {
                    Text(current.mgdl, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.color(for: current.mgdl))
                    Text("mg/dL", comment: "Glucose unit").foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("No reading", comment: "Week chart: no reading at the middle line").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text((current?.date ?? middle).formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ points: [HistoryStatisticsViewModel.GlucosePoint]) -> some View {
        let top = max(300, ((points.map(\.mgdl).max() ?? 0) / 50).rounded(.up) * 50)
        let selected = reading(at: middle, in: points)
        return Chart {
            RectangleMark(xStart: .value("Start", domain.lowerBound), xEnd: .value("End", domain.upperBound),
                          yStart: .value("Low", 70), yEnd: .value("High", 180))
                .foregroundStyle(GlucoseBandColor.inRange.opacity(0.12))

            ForEach(points.indices, id: \.self) { index in
                PointMark(x: .value("Time", points[index].date), y: .value("Glucose", points[index].mgdl))
                    .symbolSize(14)
                    .foregroundStyle(Self.color(for: points[index].mgdl))
            }

            // The middle line: its date follows the scroll position, so it stays
            // in the middle of the visible 24 hours while the chart moves.
            RuleMark(x: .value("Middle", middle))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(Color.primary.opacity(0.75))

            if let selected {
                PointMark(x: .value("Time", selected.date), y: .value("Glucose", selected.mgdl))
                    .symbolSize(90)
                    .foregroundStyle(Self.color(for: selected.mgdl))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 40...top)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: Self.visibleLength)
        .chartScrollPosition(x: $scrollPosition)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
            // Day markers: a stronger line at each midnight and the day's name in a
            // second row under the hours, starting at that line (a label centred on
            // its day would be cut off whenever the middle of the day is off screen).
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), verticalSpacing: 22)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [54, 70, 180, 250]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 300)
        .accessibilityLabel(Text("Glucose chart, last 7 days", comment: "Accessibility label of the week glucose chart"))
    }

    private func summary(_ points: [HistoryStatisticsViewModel.GlucosePoint]) -> some View {
        let values = points.map(\.mgdl)
        let inRange = Double(values.filter { $0 >= 70 && $0 <= 180 }.count) / Double(values.count)
        let average = values.reduce(0, +) / Double(values.count)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("In range", comment: "Week chart summary: time in range").font(.caption).foregroundStyle(.secondary)
                Text(inRange, format: .percent.precision(.fractionLength(0))).font(.title3.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Average", comment: "Week chart summary: average glucose").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(average.rounded())) mg/dL").font(.title3.weight(.semibold))
            }
        }
        .monospacedDigit()
    }

    private static func color(for mgdl: Double) -> Color {
        switch mgdl {
        case ..<54: return GlucoseBandColor.veryLow
        case ..<70: return GlucoseBandColor.low
        case ...180: return GlucoseBandColor.inRange
        case ...250: return GlucoseBandColor.high
        default: return GlucoseBandColor.veryHigh
        }
    }
}
