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
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d clean nights (midnight–7am) with no food and no manual bolus in or before them. So far: %2$d.", comment: "Basal insufficient data"),
                                     TherapyInsights.minimumNights,
                                     insights.cleanNightCount))
            } else {
                Text(String(format: NSLocalizedString("From %d nights between midnight and 7am with no food and no manual insulin in or before them, so the curve reflects basal alone. Automatic dosing keeps running — it is what the loop does every night — so read the direction here, not a rate.", comment: "Basal explanation"),
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
                                     ? NSLocalizedString("First half of the night", comment: "Basal window")
                                     : NSLocalizedString("Second half of the night", comment: "Basal window"))
                                    .font(.subheadline.weight(.medium))
                                Text(String(format: NSLocalizedString("around %1$02d:00–%2$02d:00", comment: "Approximate hours"),
                                            window.startHour, window.endHour))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(String(format: "%@%.0f mg/dL",
                                        window.medianDrift >= 0 ? "+" : "", window.medianDrift))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(color(for: window.verdict))
                        }
                        Text(verdictText(window))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func color(for drift: TherapyInsights.Drift) -> Color {
        switch drift {
        case .steady:  return guidanceColors.acceptable
        case .rising:  return guidanceColors.warning
        case .falling: return guidanceColors.critical
        }
    }

    private func verdictText(_ window: TherapyInsights.BasalWindow) -> String {
        switch window.verdict {
        case .steady:
            return String(format: NSLocalizedString("Held steady across %d nights.", comment: "Basal steady"),
                          window.cleanNights)
        case .rising:
            return String(format: NSLocalizedString("Rose over this window on %d nights. Worth asking whether basal is low here.", comment: "Basal rising"),
                          window.cleanNights)
        case .falling:
            return String(format: NSLocalizedString("Fell over this window on %d nights. Worth asking whether basal is high here.", comment: "Basal falling"),
                          window.cleanNights)
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
                Text(String(format: NSLocalizedString("From %d corrections given with no food around them, starting above 150 mg/dL, watched for 4 hours.", comment: "ISF method"),
                            sensitivity.evidence.samples))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let have = insights.sensitivity?.evidence.samples ?? 0
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d isolated corrections — a bolus with no carbs near it, from a high starting point. So far: %2$d.", comment: "ISF insufficient"),
                                     TherapyInsights.minimumCorrections, have))
            }
        }
    }

    // MARK: Carb ratio

    private var carbRatioTile: some View {
        tile {
            tileTitle(NSLocalizedString("Carb Ratio", comment: "Tile title"))
            if let ratio = insights.carbRatio,
               ratio.evidence.isSufficient,
               ratio.daysSpanned >= TherapyInsights.minimumMealDays,
               ratio.suggested != nil {
                comparisonRow(current: ratio.current,
                              observed: ratio.observed,
                              suggested: ratio.suggested,
                              wasCapped: ratio.wasCapped,
                              unit: NSLocalizedString("grams per unit", comment: "Carb ratio unit"))
                statLine(NSLocalizedString("Typical 5-hour change after a meal", comment: "Meal excursion"),
                         String(format: "%@%.0f mg/dL",
                                ratio.medianExcursion >= 0 ? "+" : "", ratio.medianExcursion))
                Text(String(format: NSLocalizedString("From %1$d bolused meals over %2$d days. Meals with anything else in the following 5 hours are left out.", comment: "Carb ratio method"),
                            ratio.evidence.samples, ratio.daysSpanned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let ratio = insights.carbRatio
                notEnoughData(String(format: NSLocalizedString("Needs at least %1$d clean bolused meals spread over at least %2$d days. So far: %3$d meals over %4$d days.", comment: "Carb ratio insufficient"),
                                     TherapyInsights.minimumMeals,
                                     TherapyInsights.minimumMealDays,
                                     ratio?.evidence.samples ?? 0,
                                     ratio?.daysSpanned ?? 0))
            }
        }
    }

    // MARK: Shared pieces

    /// Current vs observed vs a capped suggestion. The suggestion is always
    /// shown NEXT TO the current value, never alone, so it reads as a comparison
    /// rather than an answer.
    private func comparisonRow(current: Double?, observed: Double,
                               suggested: Double?, wasCapped: Bool,
                               unit: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                valueColumn(NSLocalizedString("Your setting", comment: "Label"),
                            current.map { String(format: "%.0f", $0) } ?? "—")
                valueColumn(NSLocalizedString("Your data says", comment: "Label"),
                            String(format: "%.0f", observed))
                if let suggested {
                    valueColumn(NSLocalizedString("To discuss", comment: "Label"),
                                String(format: "%.0f", suggested),
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
                       NSLocalizedString("Only from nights with no food or bolus for at least 4 hours beforehand and none during. Any night with a gap in sensor data is dropped rather than patched.", comment: "Basal method"))
            methodLine(NSLocalizedString("Sensitivity", comment: "Method"),
                       NSLocalizedString("Only from corrections with no carbs on either side and no second bolus stacked on top.", comment: "ISF method detail"))
            methodLine(NSLocalizedString("Carb ratio", comment: "Method"),
                       NSLocalizedString("Only from meals that were bolused for and followed by nothing else for 5 hours, and only once there are at least 30 days of them.", comment: "Ratio method detail"))
            methodLine(NSLocalizedString("Limits", comment: "Method"),
                       NSLocalizedString("Any figure shown to discuss is held within 20% of your current setting, the same ceiling automatic tuning tools place on themselves.", comment: "Caps"))
            // The ordering caveat matters more than any single number here: a
            // carb ratio computed through a wrong ISF is wrong too, and acting
            // on it while basal is off would make things worse, not better.
            methodLine(NSLocalizedString("Read these in order", comment: "Method"),
                       NSLocalizedString("Basal first, then sensitivity, then carb ratio. Each one is only meaningful once the one before it is right — the carb ratio here is literally calculated through your sensitivity setting. If the basal section is flagging drift, treat the two below it as unreliable for now.", comment: "Dependency ordering"))
            methodLine(NSLocalizedString("Windows", comment: "Method"),
                       NSLocalizedString("These use every night and meal in your log, not the period you picked on the statistics screen.", comment: "Windows"))
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
