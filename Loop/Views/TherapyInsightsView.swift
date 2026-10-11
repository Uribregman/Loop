//
//  TherapyInsightsView.swift
//  Loop
//
//  Shows what the history log suggests about basal, sensitivity and carb ratio.
//
//  NOTHING ON THIS SCREEN CHANGES ANY SETTING. There is no apply button, no
//  toggle, no deep link into the therapy editors. That is deliberate: a settings
//  change should be a decision the user makes deliberately, with their care
//  team, in the place settings are normally edited — not a tap taken while
//  reading a summary. See TherapyInsights.swift for the analysis and its limits.
//

import SwiftUI
import LoopKitUI

/// The Settings Review tiles, shown INLINE on the statistics screen.
///
/// Not its own screen any more, but the disclaimer still comes first and travels
/// with the tiles — these numbers must never appear without it.
struct TherapyInsightsSection: View {
    let insights: TherapyInsights
    /// True while this is being rendered into a shareable PNG.
    ///
    /// 🐛 WITHOUT THIS THE WHOLE SECTION EXPORTED AS AN UNREADABLE BLACK SLAB.
    /// `loopTileGlass` is a live compositing effect: it samples what is behind it
    /// on a real screen, and `ImageRenderer` has no screen. Every other tile on
    /// the statistics screen goes through `loopExportableTileBackground`, which
    /// swaps in a solid fill for exactly this reason — this section builds its
    /// own tiles and was missed, so it was the one card that came out black.
    ///
    /// ⚠️ Any new tile style anywhere on that screen has to come through the same
    /// modifier. The trap is silent: it looks perfect in the app.
    var isExporting: Bool = false
    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        VStack(spacing: 16) {
            disclaimerTile
            basalTile
            sensitivityTile
            carbRatioTile
            methodTile
        }
    }

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .loopExportableTileBackground(isExporting)
    }

    private func tileTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Disclaimer — first, not last

    private var disclaimerTile: some View {
        tile {
            Label {
                Text("Nothing here changes your settings", comment: "Therapy insights disclaimer title")
                    .font(.headline)
            } icon: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(guidanceColors.warning)
            }
            Text("This page looks for patterns in your own recorded data and reports them. It cannot and does not adjust anything, and it is not medical advice. Insulin settings are a clinical decision — bring anything here to your care team rather than acting on it directly.", comment: "Therapy insights disclaimer body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Basal

    private var basalTile: some View {
        tile {
            tileTitle(NSLocalizedString("Overnight Basal", comment: "Tile title"))
            if insights.basalWindows.isEmpty {
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d clean stretches of the same part of the night (midnight–3am or 3am–7am): starting in range, with no food still absorbing and no bolus of your own in it or in the 4 hours before. So far: %2$d before 3am and %3$d after.", comment: "Basal insufficient data"),
                                     TherapyInsights.minimumNights,
                                     insights.cleanEarlyNightCount,
                                     insights.cleanLateNightCount))
            } else {
                Text(String(format: NSLocalizedString("From %d nights. Each part of the night is judged on its own, and only when it starts in range with no food still absorbing and no bolus of your own in it or in the 4 hours before. Loop keeps dosing through the night and corrects a drift as it starts, so each part shows what glucose did AND how much Loop gave to get there. Read the direction, not a rate.", comment: "Basal explanation"),
                            insights.cleanNightCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // ⚠️ See the note on `explanation` below — without this the
                    // exported card cuts this sentence off mid-word.
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(insights.basalWindows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(window.half == 0
                                     ? NSLocalizedString("First part of the night", comment: "Basal window")
                                     : NSLocalizedString("Second part of the night", comment: "Basal window"))
                                    .font(.subheadline.weight(.medium))
                                Text(String(format: NSLocalizedString("%1$02d:00–%2$02d:00", comment: "Hours of a part of the night"),
                                            window.startHour, window.endHour))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(String(format: "%@%.0f mg/dL",
                                        window.medianDrift >= 0 ? "+" : "", window.medianDrift))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(color(for: window.finding))
                        }
                        Text(verdictText(window))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 2)
                }
                Text("A fasting window that holds within about 30 mg/dL is usually taken as basal being about right for that stretch.", comment: "Basal 30 mg/dL rule")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(for finding: TherapyInsights.Finding) -> Color {
        switch finding {
        case .steady, .unclear:                return guidanceColors.acceptable
        case .rising, .steadyWithMore:         return guidanceColors.warning
        case .falling, .steadyWithLess:        return guidanceColors.critical
        }
    }

    /// The direction, how many nights it is the middle of, and what Loop gave
    /// meanwhile — see `TherapyInsights.BasalWindow.finding` for why the three
    /// are read together.
    private func verdictText(_ window: TherapyInsights.BasalWindow) -> String {
        let loop = window.loopShare.map {
            String(format: NSLocalizedString(" Loop gave %.0f%% of your programmed basal over these hours (basal plus its automatic boluses).", comment: "Basal window: Loop's delivery"), $0 * 100)
        } ?? ""
        switch window.finding {
        case .steady:
            return String(format: NSLocalizedString("Held steady, typically, across %d nights.", comment: "Basal steady"),
                          window.cleanNights) + loop
        case .steadyWithMore:
            return String(format: NSLocalizedString("Held steady across %d nights, but only with Loop adding insulin. Worth asking whether basal is low here.", comment: "Basal steady, Loop adding"),
                          window.cleanNights) + loop
        case .steadyWithLess:
            return String(format: NSLocalizedString("Held steady across %d nights, but only with Loop holding insulin back. Worth asking whether basal is high here.", comment: "Basal steady, Loop holding back"),
                          window.cleanNights) + loop
        case .rising:
            return String(format: NSLocalizedString("Typically rose over these hours (%d nights). Worth asking whether basal is low here.", comment: "Basal rising"),
                          window.cleanNights) + loop
        case .falling:
            return String(format: NSLocalizedString("Typically fell over these hours (%d nights). Worth asking whether basal is high here.", comment: "Basal falling"),
                          window.cleanNights) + loop
        case .unclear:
            return String(format: NSLocalizedString("Moved the way Loop was pushing it (%d nights), so this says nothing about basal either way.", comment: "Basal unclear"),
                          window.cleanNights) + loop
        }
    }

    // MARK: Sensitivity

    private var sensitivityTile: some View {
        tile {
            tileTitle(NSLocalizedString("Insulin Sensitivity", comment: "Tile title"))
            if let sensitivity = insights.sensitivity, sensitivity.evidence.isSufficient {
                comparisonRow(current: sensitivity.current,
                              observed: sensitivity.observed,
                              suggested: sensitivity.suggested,
                              wasCapped: sensitivity.wasCapped,
                              unit: NSLocalizedString("mg/dL per unit", comment: "ISF unit"))
                Text(String(format: NSLocalizedString("From %d corrections given with no food around them and no other bolus of your own within 4 hours, starting above 150 mg/dL, watched for 4 hours. The fall is divided by your bolus plus what Loop added or held back.", comment: "ISF method"),
                            sensitivity.evidence.samples))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let have = insights.sensitivity?.evidence.samples ?? 0
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d isolated corrections — a bolus of your own with no carbs and no other bolus of yours within 4 hours of it, from a high starting point. So far: %2$d. With Loop correcting highs by itself these are rare, so this may stay empty.", comment: "ISF insufficient"),
                                     TherapyInsights.minimumCorrections, have))
            }
        }
    }

    // MARK: Carb ratio

    private var carbRatioTile: some View {
        tile {
            tileTitle(NSLocalizedString("Carb Ratio", comment: "Tile title"))
            if let ratio = insights.carbRatio,
               let observed = ratio.observed,
               ratio.suggested != nil {
                comparisonRow(current: ratio.current,
                              observed: observed,
                              suggested: ratio.suggested,
                              wasCapped: ratio.wasCapped,
                              unit: NSLocalizedString("grams per unit", comment: "Carb ratio unit"),
                              decimals: 1)
                statLine(NSLocalizedString("Typical change by the time a meal is absorbed", comment: "Meal excursion"),
                         String(format: "%@%.0f mg/dL",
                                ratio.medianExcursion >= 0 ? "+" : "", ratio.medianExcursion))
                Text(String(format: NSLocalizedString("From %1$d bolused meals over %2$d days. Boluses of your own from 30 minutes before a meal to 45 minutes after count as its bolus; a meal with another bolus or more food before it has finished absorbing (4 hours at least) is left out. The insulin counted includes what Loop added or held back.", comment: "Carb ratio method"),
                            ratio.evidence.samples, ratio.daysSpanned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let ratio = insights.carbRatio, ratio.evidence.isSufficient,
                      ratio.daysSpanned >= TherapyInsights.minimumMealDays, ratio.observed == nil {
                // Enough meals, but the leftover rise cannot be turned into
                // insulin without a sensitivity setting to convert it with.
                statLine(NSLocalizedString("Typical change by the time a meal is absorbed", comment: "Meal excursion"),
                         String(format: "%@%.0f mg/dL",
                                ratio.medianExcursion >= 0 ? "+" : "", ratio.medianExcursion))
                notEnoughData(String(format: NSLocalizedString("From %1$d bolused meals over %2$d days. Working out a ratio from them needs your insulin sensitivity setting, which this screen was opened without: open Statistics from the main screen.", comment: "Carb ratio: no ISF"),
                                     ratio.evidence.samples, ratio.daysSpanned))
            } else {
                let ratio = insights.carbRatio
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d clean bolused meals spread over at least %2$d days, on at least %3$d different days. So far: %4$d meals over %5$d days, on %6$d different days.", comment: "Carb ratio insufficient"),
                                     TherapyInsights.minimumMeals,
                                     TherapyInsights.minimumMealDays,
                                     TherapyInsights.minimumDistinctMealDays,
                                     ratio?.evidence.samples ?? 0,
                                     ratio?.daysSpanned ?? 0,
                                     ratio?.distinctDays ?? 0))
            }
        }
    }

    // MARK: Shared pieces

    /// Current vs observed vs a capped suggestion. The suggestion is always
    /// shown NEXT TO the current value, never alone, so it reads as a comparison
    /// rather than an answer.
    ///
    /// `decimals` matters for a carb ratio: 6.4 g/U shown as "6" reads as 25%
    /// below a setting of 8, on a page that promises to stay within 20%.
    private func comparisonRow(current: Double?, observed: Double,
                               suggested: Double?, wasCapped: Bool,
                               unit: String, decimals: Int = 0) -> some View {
        let format = "%.\(decimals)f"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                valueColumn(NSLocalizedString("Your setting", comment: "Label"),
                            current.map { String(format: format, $0) } ?? "—")
                valueColumn(NSLocalizedString("Your data says", comment: "Label"),
                            String(format: format, observed))
                if let suggested {
                    valueColumn(NSLocalizedString("To discuss", comment: "Label"),
                                String(format: format, suggested),
                                emphasised: true)
                }
            }
            Text(unit).font(.caption).foregroundStyle(.tertiary)

            if wasCapped {
                Label(NSLocalizedString("Your data sits further from the setting than this page will suggest moving. That gap is itself worth raising with your care team.", comment: "Capped explanation"),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(guidanceColors.warning)
            }
        }
    }

    private func valueColumn(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasised ? Color.accentColor : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func notEnoughData(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Method

    private var methodTile: some View {
        tile {
            tileTitle(NSLocalizedString("How This Is Worked Out", comment: "Tile title"))
            methodLine(NSLocalizedString("Basal", comment: "Method"),
                       NSLocalizedString("Each part of the night (midnight–3am, 3am–7am) on its own, and only when it starts in range with no food still absorbing and no bolus of your own in it or in the 4 hours before. A part with a gap in sensor data is dropped rather than patched.", comment: "Basal method"))
            methodLine(NSLocalizedString("Sensitivity", comment: "Method"),
                       NSLocalizedString("Only from corrections with no carbs on either side and no other bolus of your own within 4 hours before or after. The insulin counted is your bolus plus what Loop added or held back in those 4 hours.", comment: "ISF method detail"))
            methodLine(NSLocalizedString("Carb ratio", comment: "Method"),
                       NSLocalizedString("Only from meals that were bolused for and followed by nothing else until they have finished absorbing (4 hours at least), and only once there are at least 30 days of them. The insulin counted is your bolus plus what Loop added or held back.", comment: "Ratio method detail"))
            methodLine(NSLocalizedString("Limits", comment: "Method"),
                       NSLocalizedString("Any figure shown to discuss is held within 20% of your current setting, the same ceiling automatic tuning tools place on themselves.", comment: "Caps"))
            // The ordering caveat matters more than any single number here: a
            // carb ratio computed through a wrong ISF is wrong too, and acting
            // on it while basal is off would make things worse, not better.
            methodLine(NSLocalizedString("Read these in order", comment: "Method"),
                       NSLocalizedString("Basal first, then sensitivity, then carb ratio. Each one is only meaningful once the one before it is right — the carb ratio here is literally calculated through your sensitivity setting. If the basal section is flagging drift, treat the two below it as unreliable for now.", comment: "Dependency ordering"))
            methodLine(NSLocalizedString("Windows", comment: "Method"),
                       NSLocalizedString("These use every night and meal in your log, not the period you picked on the statistics screen. \"Your setting\" is the average of your schedule over the day, and Loop's basal is worked out from your current basal schedule.", comment: "Windows"))
        }
    }

    private func methodLine(_ label: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline.weight(.medium))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}
