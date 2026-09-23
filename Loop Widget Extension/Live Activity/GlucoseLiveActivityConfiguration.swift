//
//  LiveActivityConfiguration.swift
//  Loop Widget Extension
//
//  Created by Bastiaan Verhaar on 23/06/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import ActivityKit
import Charts
import HealthKit
import LoopCore
import LoopKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct GlucoseLiveActivityConfiguration: Widget {
    var body: some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return ActivityConfiguration(for: GlucoseActivityAttributes.self) {
                context in
                lockScreenView(context: context)
            } dynamicIsland: { context in
                dynamicIslandView(context: context)
            }
            .supplementalActivityFamilies([.small])
        } else {
            return ActivityConfiguration(for: GlucoseActivityAttributes.self) {
                context in
                lockScreenView(context: context)
            } dynamicIsland: { context in
                dynamicIslandView(context: context)
            }
        }
    }
    

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        // Create the presentation that appears on the Lock Screen and as a
        // banner on the Home Screen of devices that don't support the Dynamic Island.
        if #available(iOS 18.0, *) {
            AdaptiveLockScreenView(context: context)
        } else {
            fullLockScreenView(context: context)
        }
    }

    @available(iOS 18.0, *)
    struct AdaptiveLockScreenView: View {
        let context: ActivityViewContext<GlucoseActivityAttributes>
        @Environment(\.activityFamily) private var activityFamily

        var body: some View {
            if activityFamily == .small {
                // WatchOS & CarPlay supplemental view - show only bottom row
                compactLockScreenView(context: context)
            } else {
                // Lock screen - show full view with chart
                fullLockScreenView(context: context)
            }
        }

        @ViewBuilder
        private func fullLockScreenView(
            context: ActivityViewContext<GlucoseActivityAttributes>
        ) -> some View {
            GlucoseLiveActivityConfiguration().fullLockScreenView(
                context: context
            )
        }

        @ViewBuilder
        private func compactLockScreenView(
            context: ActivityViewContext<GlucoseActivityAttributes>
        ) -> some View {
            GlucoseLiveActivityConfiguration().compactLockScreenView(
                context: context
            )
        }
    }

    @ViewBuilder
    private func fullLockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        LiveActivityPaletteReader { palette in
            fullLockScreenContent(context: context, palette: palette)
        }
    }

    @ViewBuilder
    private func fullLockScreenContent(
        context: ActivityViewContext<GlucoseActivityAttributes>,
        palette: LiveActivityPalette
    ) -> some View {
        ZStack {
            VStack {
                    // 15 pt like the card's own margin, plus the part of the ring's stroke
                    // that falls outside its frame, so the chart sits centred beside the ring.
                    HStack(spacing: 20) {
                        loopIcon(context, palette: palette)
                        if context.attributes.addPredictiveLine {
                            ChartView(
                                glucoseSamples: context.state.glucoseSamples,
                                predicatedGlucose: context.state
                                    .predicatedGlucose,
                                predicatedStartDate: context.state
                                    .predicatedStartDate,
                                predicatedInterval: context.state
                                    .predicatedInterval,
                                useLimits: context.attributes.useLimits,
                                lowerLimit: context.state.isMmol
                                ? context.attributes.lowerLimitChartMmol
                                : context.attributes.lowerLimitChartMg,
                                upperLimit: context.state.isMmol
                                ? context.attributes.upperLimitChartMmol
                                : context.attributes.upperLimitChartMg,
                                glucoseRanges: context.state.glucoseRanges,
                                preset: context.state.preset,
                                yAxisMarks: context.state.yAxisMarks
                            )
                            .hidingTargetBand()
                            .frame(height: 85)
                        } else {
                            ChartView(
                                glucoseSamples: context.state.glucoseSamples,
                                useLimits: context.attributes.useLimits,
                                lowerLimit: context.state.isMmol
                                ? context.attributes.lowerLimitChartMmol
                                : context.attributes.lowerLimitChartMg,
                                upperLimit: context.state.isMmol
                                ? context.attributes.upperLimitChartMmol
                                : context.attributes.upperLimitChartMg,
                                glucoseRanges: context.state.glucoseRanges,
                                preset: context.state.preset,
                                yAxisMarks: context.state.yAxisMarks
                            )
                            .hidingTargetBand()
                            .frame(height: 85)
                        }
                    }

                HStack {
                    bottomSpacer(border: false)
                    
                    let endIndex = context.state.bottomRow.endIndex - 1
                    ForEach(
                        Array(context.state.bottomRow.enumerated()),
                        id: \.element
                    ) { (index, item) in
                        switch item.type {
                        case .generic:
                            bottomItemGeneric(
                                title: item.label,
                                value: item.value,
                                unit: LocalizedString(
                                    item.unit,
                                    comment: "No comment"
                                )
                            )
                            
                        case .basal:
                            BasalViewActivity(
                                percent: item.percentage,
                                rate: item.rate
                            )
                            
                        case .currentBg:
                            bottomItemCurrentBG(
                                value: item.value,
                                trend: item.trend,
                                context: context,
                                palette: palette
                            )
                        }
                        
                        if index != endIndex {
                            bottomSpacer(border: true)
                        }
                    }
                    
                    bottomSpacer(border: false)
                }
            }
            if context.state.ended {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(
                            NSLocalizedString(
                                "Open the app to update the widget",
                                comment: "No comment"
                            )
                        )
                        Spacer()
                    }
                    Spacer()
                }
                .background(.ultraThinMaterial.opacity(0.8))
                .padding(.all, -15)
            }
        }
        .privacySensitive()
        .padding(.all, 15)
        .background(BackgroundStyle.background.opacity(0.4))
        .activityBackgroundTint(Color.clear)
    }

    @ViewBuilder
    private func compactLockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        LiveActivityPaletteReader { palette in
            compactLockScreenContent(context: context, palette: palette)
        }
    }

    @ViewBuilder
    private func compactLockScreenContent(
        context: ActivityViewContext<GlucoseActivityAttributes>,
        palette: LiveActivityPalette
    ) -> some View {
        let glucoseFormatter = NumberFormatter.glucoseFormatter(
            for: context.state.isMmol
                ? HKUnit.millimolesPerLiter
                : HKUnit.milligramsPerDeciliter
        )
        let unit = context.state.isMmol
            ? HKUnit.millimolesPerLiter.localizedShortUnitString
            : HKUnit.milligramsPerDeciliter.localizedShortUnitString
        
        let glucoseColor = !context.attributes.useLimits ? .primary : getGlucoseColor(context: context, palette: palette)
        let currentBG = (glucoseFormatter.string(from: context.state.currentGlucose) ?? "??") + getArrowImage(context.state.trendType)
        let eventualBG = formatEventualBG(value: context.state.eventualGlucose, formatter: glucoseFormatter)
        
        HStack(spacing: 10) {
            loopIcon(context, palette: palette, size: 24)
            
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(currentBG)
                        .font(.headline)
                        .foregroundStyle(glucoseColor)
                    Text(context.state.delta + " " + unit)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.7))
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text(eventualBG)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // Allow HStack to use full available width
        .privacySensitive()
        .padding(.all, 14)
        .background(Color.clear)
    }
    
    private func formatEventualBG(value: Double?, formatter: NumberFormatter) -> String {
        guard let value = value else {
            return "??"
        }
        
        return formatter.string(from: NSNumber(value: value)) ?? "??"
    }

    // MARK: - Dynamic Island View

    private func dynamicIslandView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> DynamicIsland {
        let glucoseFormatter = NumberFormatter.glucoseFormatter(
            for: context.state.isMmol
                ? HKUnit.millimolesPerLiter : HKUnit.milligramsPerDeciliter
        )

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HStack(alignment: .center) {
                    // 44 pt: the ring (36 pt) plus its 8 pt stroke, so the stroke stays inside the
                    // region (anything outside it can be cut off) while the row sits as high as it can.
                    loopIcon(context, palette: .dark)
                        .frame(width: 44, height: 44, alignment: .trailing)
                    Spacer()
                    Text(
                        "\(glucoseFormatter.string(from: context.state.currentGlucose) ?? "??")\(getArrowImage(context.state.trendType))"
                    )
                    .foregroundStyle(getGlucoseColor(context: context, palette: .dark))
                    .font(.headline)
                    .fontWeight(.heavy)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                HStack {
                    Text(context.state.delta)
                        .foregroundStyle(Color(white: 0.9))
                        .font(.headline)
                    Text(
                        context.state.isMmol
                            ? HKUnit.millimolesPerLiter.localizedShortUnitString
                            : HKUnit.milligramsPerDeciliter
                                .localizedShortUnitString
                    )
                    .foregroundStyle(Color(white: 0.7))
                    .font(.subheadline)
                }
                // Same height as the ring's row on the left, so both are centred on one line.
                .frame(height: 44)
            }
            DynamicIslandExpandedRegion(.bottom) {
                if context.attributes.addPredictiveLine {
                    ChartView(
                        glucoseSamples: context.state.glucoseSamples,
                        predicatedGlucose: context.state.predicatedGlucose,
                        predicatedStartDate: context.state.predicatedStartDate,
                        predicatedInterval: context.state.predicatedInterval,
                        useLimits: context.attributes.useLimits,
                        lowerLimit: context.state.isMmol
                            ? context.attributes.lowerLimitChartMmol
                            : context.attributes.lowerLimitChartMg,
                        upperLimit: context.state.isMmol
                            ? context.attributes.upperLimitChartMmol
                            : context.attributes.upperLimitChartMg,
                        glucoseRanges: context.state.glucoseRanges,
                        preset: context.state.preset,
                        yAxisMarks: context.state.yAxisMarks
                    )
                    .alwaysDarkPalette()
                    .frame(height: 75)
                } else {
                    ChartView(
                        glucoseSamples: context.state.glucoseSamples,
                        useLimits: context.attributes.useLimits,
                        lowerLimit: context.state.isMmol
                            ? context.attributes.lowerLimitChartMmol
                            : context.attributes.lowerLimitChartMg,
                        upperLimit: context.state.isMmol
                            ? context.attributes.upperLimitChartMmol
                            : context.attributes.upperLimitChartMg,
                        glucoseRanges: context.state.glucoseRanges,
                        preset: context.state.preset,
                        yAxisMarks: context.state.yAxisMarks
                    )
                    .alwaysDarkPalette()
                    .frame(height: 75)
                }
            }
        } compactLeading: {
            Text(
                "\(glucoseFormatter.string(from: context.state.currentGlucose) ?? "??")\(getArrowImage(context.state.trendType))"
            )
            .foregroundStyle(
                getGlucoseColor(context: context, palette: .dark)
            )
            .minimumScaleFactor(0.1)
        } compactTrailing: {
            Text(context.state.delta)
                .foregroundStyle(Color(white: 0.9))
                .minimumScaleFactor(0.1)
        } minimal: {
            Text(
                glucoseFormatter.string(from: context.state.currentGlucose)
                    ?? "??"
            )
            .foregroundStyle(
                getGlucoseColor(context: context, palette: .dark)
            )
            .minimumScaleFactor(0.1)
        }
    }

    @ViewBuilder
    private func loopIcon(
        _ context: ActivityViewContext<GlucoseActivityAttributes>,
        palette: LiveActivityPalette,
        size: CGFloat = 36
    ) -> some View {
        Circle()
            .trim(from: context.state.isCloseLoop ? 0 : 0.2, to: 1)
            .stroke(getLoopColor(context.state.lastCompleted, palette: palette), lineWidth: size/4.5)
            .rotationEffect(Angle(degrees: -126))
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func bottomItemGeneric(title: String, value: String, unit: String)
        -> some View
    {
        VStack(alignment: .center) {
            Text("\(value)\(unit)")
                .font(.headline)
                .foregroundStyle(.primary)
                .fontWeight(.heavy)
                .font(Font.body.leading(.tight))
            Text(title)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func bottomItemCurrentBG(
        value: String,
        trend: GlucoseTrend?,
        context: ActivityViewContext<GlucoseActivityAttributes>,
        palette: LiveActivityPalette
    ) -> some View {
        VStack(alignment: .center) {
            HStack {
                Text(value + getArrowImage(trend))
                    .font(.title)
                    .foregroundStyle(
                        !context.attributes.useLimits
                            ? .primary
                            : getGlucoseColor(context: context, palette: palette)
                    )
                    .fontWeight(.heavy)
                    .font(Font.body.leading(.tight))
            }
        }
    }

    @ViewBuilder
    private func bottomItemLoopCircle(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        VStack(alignment: .center) {
            loopIcon(context, palette: .forScheme(.light))
        }
    }

    @ViewBuilder
    private func bottomSpacer(border: Bool) -> some View {
        Spacer()
        if border {
            Divider()
                .background(.secondary)
            Spacer()
        }

    }

    private func getArrowImage(_ trendType: GlucoseTrend?) -> String {
        switch trendType {
        case .upUpUp:
            return "\u{2191}\u{2191}"  // ↑↑
        case .upUp:
            return "\u{2191}"  // ↑
        case .up:
            return "\u{2197}"  // ↗
        case .flat:
            return "\u{2192}"  // →
        case .down:
            return "\u{2198}"  // ↘
        case .downDown:
            return "\u{2193}"  // ↓
        case .downDownDown:
            return "\u{2193}\u{2193}"  // ↓↓
        case .none:
            return ""
        }
    }

    private func getLoopColor(_ age: Date?, palette: LiveActivityPalette) -> Color {
        var freshness: LoopCompletionFreshness = .stale
        if let age = age {
            freshness = LoopCompletionFreshness(
                age: abs(min(0, age.timeIntervalSinceNow))
            )
        }

        switch freshness {
        case .fresh:
            return palette.fresh
        case .aging:
            return palette.warning
        case .stale:
            return palette.stale
        }
    }

    private func getGlucoseColor(context: ActivityViewContext<GlucoseActivityAttributes>, palette: LiveActivityPalette) -> Color {
        guard context.attributes.useLimits else {
            return .primary
        }
        
        let value = context.state.currentGlucose
        if context.state.isMmol
            && value < context.attributes.lowerLimitChartMmol
            || !context.state.isMmol
                && value < context.attributes.lowerLimitChartMg
        {
            return palette.belowRange
        }

        if context.state.isMmol
            && value > context.attributes.upperLimitChartMmol
            || !context.state.isMmol
                && value > context.attributes.upperLimitChartMg
        {
            return palette.aboveRange
        }

        return palette.inRange
    }
    

}
