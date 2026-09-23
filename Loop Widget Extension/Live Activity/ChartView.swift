//
//  ChartValues.swift
//  Loop Widget Extension
//
//  Created by Bastiaan Verhaar on 25/06/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI
import Charts

@available(iOS 16.2, *)
/// Colors of the Live Activity's graphics (chart, loop ring, glucose number).
///
/// Light mode keeps the colors the Live Activity always had. Dark mode uses
/// slightly darker ones; its green is the Time in Range green from Statistics
/// (#2FA84F). Text that is not status-colored (axis numbers, mg/dL, the change
/// since the last reading) is deliberately NOT part of this palette.
struct LiveActivityPalette {
    let inRange: Color
    let belowRange: Color
    let aboveRange: Color
    let glucose: Color
    let fresh: Color
    let warning: Color
    let stale: Color
    let rangeOpacity: Double
    let overrideOpacity: Double
    /// The chart's grid lines: system gray in both modes.
    let axis = Color(.systemGray)

    static let light = LiveActivityPalette(
        inRange: .green, belowRange: .red, aboveRange: .orange,
        glucose: Color("glucose"), fresh: Color("fresh"), warning: Color("warning"), stale: .red,
        rangeOpacity: 0.3, overrideOpacity: 0.6)

    static let dark = LiveActivityPalette(
        inRange: rgb(0x2FA84F), belowRange: rgb(0xB8322B), aboveRange: rgb(0xC46A10),
        glucose: rgb(0x2F7BC4), fresh: rgb(0x2FA84F), warning: rgb(0xC9A300), stale: rgb(0xB8322B),
        rangeOpacity: 0.15, overrideOpacity: 0.3)

    static func forScheme(_ scheme: ColorScheme) -> LiveActivityPalette {
        scheme == .dark ? .dark : .light
    }

    private static func rgb(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

struct ChartView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let glucoseSampleData: [ChartValues]
    private let predicatedData: [ChartValues]
    private let glucoseRanges: [GlucoseRangeValue]
    private let preset: Preset?
    private let yAxisMarks: [Double]
    private let useLimits: Bool
    private let lowerLimit: Double
    private let upperLimit: Double
    private let predictedLow: Double
    private let predictedHigh: Double
    /// The Dynamic Island is always black, so it always uses the dark palette.
    var alwaysDark = false
    /// The target-range band (not overrides). Hidden on the Lock Screen.
    var showsTargetBand = true

    private var palette: LiveActivityPalette {
        alwaysDark ? .dark : .forScheme(colorScheme)
    }

    private static let gridLineWidth: CGFloat = 2
    /// Dashed grid: with round ends each dash shows as ~10 pt and each gap as ~3 pt.
    private static let gridDash: [CGFloat] = [8, 5]
    /// Space between a line's end and its numbers.
    private static let gridGapToLabels: CGFloat = 9
    /// How far every line runs past the outermost line it crosses, on both ends.
    private static let gridOverhang: CGFloat = 6
    /// Height kept below the chart for the hour numbers. The numbers are drawn by hand so
    /// they sit exactly on their lines on every iOS version.
    private static let xLabelHeight: CGFloat = 14
    /// Wide enough to lay out any y number; only positions them, takes no room.
    private static let yLabelSlot: CGFloat = 60
    private static let windowLength: TimeInterval = 6 * 60 * 60

    /// The chart always spans 6 hours: the last 6 hours of readings, or, with the
    /// prediction line on, 2 hours of readings and 4 hours of prediction.
    private var timeWindow: ClosedRange<Date> {
        if let predictionStart = predicatedData.first?.x {
            let start = predictionStart.addingTimeInterval(-2 * 60 * 60)
            return start...start.addingTimeInterval(Self.windowLength)
        }
        let end = glucoseSampleData.map(\.x).max() ?? Date()
        return end.addingTimeInterval(-Self.windowLength)...end
    }

    /// Every full hour inside the window.
    private var hourMarks: [Date] {
        let window = timeWindow
        let calendar = Calendar.current
        guard var hour = calendar.nextDate(after: window.lowerBound, matching: DateComponents(minute: 0, second: 0),
                                           matchingPolicy: .nextTime) else { return [] }
        var marks: [Date] = []
        while hour <= window.upperBound {
            marks.append(hour)
            hour = hour.addingTimeInterval(60 * 60)
        }
        return marks
    }

    // Infer chartable increment from yAxisMarks: mmol/L values are always below 40, mg/dL above 54.
    private var chartableIncrement: Double { (yAxisMarks.max() ?? 100) < 40 ? 1.0/25.0 : 1.0 }

    // When min == max the rectangle has zero height and is invisible. Mirror the main app's
    // doubleRangeWithMinimumIncrement logic by expanding by one chartable increment each side.
    private func adjustedRange(min minValue: Double, max maxValue: Double) -> (min: Double, max: Double) {
        guard (maxValue - minValue) < .ulpOfOne else { return (minValue, maxValue) }
        return (minValue - 3 * chartableIncrement, maxValue + 3 * chartableIncrement)
    }

    init(glucoseSamples: [GlucoseSampleAttributes], predicatedGlucose: [Double], predicatedStartDate: Date?, predicatedInterval: TimeInterval?, useLimits: Bool, lowerLimit: Double, upperLimit: Double, glucoseRanges: [GlucoseRangeValue], preset: Preset?, yAxisMarks: [Double]) {
        self.glucoseSampleData = ChartValues.convert(data: glucoseSamples, useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit)
        self.predicatedData = ChartValues.convert(
            data: predicatedGlucose,
            startDate: predicatedStartDate ?? Date.now,
            interval: predicatedInterval ?? .minutes(5),
            useLimits: useLimits,
            lowerLimit: lowerLimit,
            upperLimit: upperLimit
        )
        self.useLimits = useLimits
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.predictedLow = predicatedGlucose.min() ?? 1
        self.predictedHigh = predicatedGlucose.max() ?? 1
        self.preset = preset
        self.glucoseRanges = glucoseRanges
        self.yAxisMarks = yAxisMarks
    }
    
    init(glucoseSamples: [GlucoseSampleAttributes], useLimits: Bool, lowerLimit: Double, upperLimit: Double, glucoseRanges: [GlucoseRangeValue], preset: Preset?, yAxisMarks: [Double]) {
        self.glucoseSampleData = ChartValues.convert(data: glucoseSamples, useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit)
        self.predicatedData = []
        self.preset = preset
        self.glucoseRanges = glucoseRanges
        self.yAxisMarks = yAxisMarks
        self.useLimits = useLimits
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.predictedLow = 1
        self.predictedHigh = 1
    }

    private static func getGradient(palette: LiveActivityPalette, useLimits: Bool, lowerLimit: Double, upperLimit: Double, lowestValue: Double, highestValue: Double) -> LinearGradient {
        let colorInRange = palette.inRange
        let colorBelowRange = palette.belowRange
        let colorAboveRange = palette.aboveRange

        var stops: [Gradient.Stop] = [Gradient.Stop(color: palette.glucose, location: 0)]
        if useLimits {
            // For applying a color gradient to line data, the range of the plotted
            // data maps to the space 0 to 1 for setting gradient stops, so normalize:
            // Normalize the transition points to 0-1 space of the plotted range:
            let lowerStop = (lowerLimit - lowestValue) / (highestValue - lowestValue)
            let upperStop = (upperLimit - lowestValue) / (highestValue - lowestValue)
            // Build up a set of stops, only using those in the 0-1 range:
            stops = []
            var stopColor: Color
            // Get the color for glucose at the minimum of the line:
            if lowestValue < lowerLimit {
                stopColor = colorBelowRange
            } else if lowestValue < upperLimit {
                stopColor = colorInRange
            } else {
                stopColor = colorAboveRange
            }
            stops.append(Gradient.Stop(color: stopColor, location: 0))
            // Add the transition stops if they are in the visible range:
            if lowerStop > 0, lowerStop < 1 {
                stops.append(Gradient.Stop(color: colorBelowRange, location: lowerStop))
                stops.append(Gradient.Stop(color: colorInRange, location: lowerStop + 0.01))
            }
            if upperStop > 0, upperStop < 1 {
                stops.append(Gradient.Stop(color: colorInRange, location: upperStop))
                stops.append(Gradient.Stop(color: colorAboveRange, location: upperStop + 0.01))
            }
            
        }
        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: .bottom,
            endPoint: .top
        )
    }
    
    var body: some View {
        let palette = self.palette
        // Charts draws marks outside the x domain too, so keep everything inside the 6 hours.
        let window = timeWindow
        let clamp = { (date: Date) in min(max(date, window.lowerBound), window.upperBound) }
        let colorGradient = predicatedData.isEmpty
            ? LinearGradient(colors: [], startPoint: .bottom, endPoint: .top)
            : Self.getGradient(palette: palette, useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit,
                               lowestValue: predictedLow, highestValue: predictedHigh)
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .top)){
            // The chart takes exactly the room it draws in: the lines' overhang on the left and
            // the widest y number on the right, so the layouts around it can centre it.
            HStack(alignment: .top, spacing: Self.gridOverhang + Self.gridGapToLabels) {
                Chart {
                    if let preset = self.preset, (preset.minValue > 0 || preset.maxValue > 0), predicatedData.count > 0, preset.endDate > Date.now.addingTimeInterval(.hours(-6)) {
                        let (presetMin, presetMax) = adjustedRange(min: preset.minValue, max: preset.maxValue)
                        RectangleMark(
                            xStart: .value("Start", clamp(preset.startDate)),
                            xEnd: .value("End", clamp(preset.endDate)),
                            yStart: .value("Preset override", presetMin),
                            yEnd: .value("Preset override", presetMax)
                        )
                        .foregroundStyle(.primary)
                        .opacity(palette.overrideOpacity)
                    }
                
                    ForEach(glucoseRanges.filter { showsTargetBand || $0.isOverride }) { item in
                        let (rangeMin, rangeMax) = adjustedRange(min: item.minValue, max: item.maxValue)
                        RectangleMark(
                            xStart: .value("Start", clamp(item.startDate)),
                            xEnd: .value("End", clamp(item.endDate)),
                            yStart: .value("Glucose range", rangeMin),
                            yEnd: .value("Glucose range", rangeMax)
                        )
                        .foregroundStyle(.primary)
                        .opacity(item.isOverride ? palette.overrideOpacity : palette.rangeOpacity)
                    }
                
                    ForEach(glucoseSampleData.filter { window.contains($0.x) }) { item in
                        PointMark (x: .value("Date", item.x),
                                   y: .value("Glucose level", item.y)
                        )
                        .symbolSize(10)
                        .foregroundStyle(by: .value("Color", item.color))
                    }
                
                    ForEach(predicatedData.filter { window.contains($0.x) }) { item in
                        LineMark (x: .value("Date", item.x),
                                  y: .value("Glucose level", item.y)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .foregroundStyle(colorGradient)
                    }
                }
                .chartForegroundStyleScale([
                    "Good": palette.inRange,
                    "High": palette.aboveRange,
                    "Low": palette.belowRange,
                    "Default": palette.glucose
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: [yAxisMarks.first ?? 0, yAxisMarks.last ?? 0])
                // Always the full window, even when readings are missing for part of it.
                .chartXScale(domain: timeWindow)
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                // Open, "floating" grid drawn by hand behind the data: one thick round-ended
                // line per number. Every line runs a little past the outermost line it crosses
                // on both ends, so no line ends on another one, and its numbers sit a gap beyond.
                .chartBackground { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let plot = geometry[plotFrame]
                            let labelOffset = Self.gridOverhang + Self.gridGapToLabels
                            Path { path in
                                for value in yAxisMarks {
                                    guard let y = proxy.position(forY: value) else { continue }
                                    path.move(to: CGPoint(x: plot.minX - Self.gridOverhang, y: plot.minY + y))
                                    path.addLine(to: CGPoint(x: plot.maxX + Self.gridOverhang, y: plot.minY + y))
                                }
                                for hour in hourMarks {
                                    guard let x = proxy.position(forX: hour) else { continue }
                                    path.move(to: CGPoint(x: plot.minX + x, y: plot.minY - Self.gridOverhang))
                                    path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY + Self.gridOverhang))
                                }
                            }
                            .stroke(palette.axis, style: StrokeStyle(lineWidth: Self.gridLineWidth, lineCap: .round,
                                                                 dash: Self.gridDash))

                            ForEach(yAxisMarks, id: \.self) { value in
                                if let y = proxy.position(forY: value) {
                                    Text(value, format: .number)
                                        .font(.caption2)
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .frame(width: Self.yLabelSlot, alignment: .leading)
                                        .position(x: plot.maxX + labelOffset + Self.yLabelSlot / 2, y: plot.minY + y)
                                }
                            }
                            ForEach(hourMarks, id: \.self) { hour in
                                if let x = proxy.position(forX: hour) {
                                    Text(hour, format: .dateTime.hour(.twoDigits(amPM: .narrow)))
                                        .font(.caption2)
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .frame(height: Self.xLabelHeight, alignment: .top)
                                        .position(x: plot.minX + x, y: plot.maxY + labelOffset + Self.xLabelHeight / 2)
                                }
                            }
                        }
                    }
                }
                // Room for the lines' overhang (and round end) on the left and the hour numbers below.
                .padding(.leading, Self.gridOverhang + Self.gridLineWidth / 2)
                .padding(.bottom, Self.gridOverhang + Self.gridGapToLabels + Self.xLabelHeight)

                // Invisible copy of the y numbers: keeps exactly the width of the widest one.
                ZStack {
                    ForEach(yAxisMarks, id: \.self) { value in
                        Text(value, format: .number)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                .fixedSize()
                .hidden()
            }
            
            if let preset = self.preset, preset.endDate > Date.now {
                Text(preset.title)
                    .font(.footnote)
                    .padding(.trailing, 5)
                    .padding(.top, 2)
            }
        }
    }
}

extension ChartView {
    /// For the Dynamic Island, which is black in light and dark mode alike.
    func alwaysDarkPalette() -> ChartView {
        var copy = self
        copy.alwaysDark = true
        return copy
    }

    /// For the Lock Screen: no target-range band (override bands still show).
    func hidingTargetBand() -> ChartView {
        var copy = self
        copy.showsTargetBand = false
        return copy
    }
}

/// Hands its content the palette for the current light/dark appearance.
struct LiveActivityPaletteReader<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: (LiveActivityPalette) -> Content

    var body: some View {
        content(.forScheme(colorScheme))
    }
}

struct ChartValues: Identifiable {
    public let id: UUID
    public let x: Date
    public let y: Double
    public let color: String
    
    init(x: Date, y: Double, color: String) {
        self.id = UUID()
        self.x = x
        self.y = y
        self.color = color
    }
    
    static func convert(data: [Double], startDate: Date, interval: TimeInterval, useLimits: Bool, lowerLimit: Double, upperLimit: Double) -> [ChartValues] {
        let cutoff = adjustedChartEnd(startDate.addingTimeInterval(.hours(4)))

        return data.enumerated().filter { (index, item) in
            return startDate.addingTimeInterval(interval * Double(index)) < cutoff
        }.map { (index, item) in
            return ChartValues(
                x: startDate.addingTimeInterval(interval * Double(index)),
                y: item,
                color: "Default" // Color is handled by the gradient
            )
        }
    }

    private static func adjustedChartEnd(_ date: Date) -> Date {
        let minute = Calendar.current.component(.minute, from: date)
        guard minute < 30 else { return date }
        let startOfHour = Calendar.current.dateInterval(of: .hour, for: date)!.start
        return startOfHour.addingTimeInterval(.minutes(30))
    }
    
    static func convert(data: [GlucoseSampleAttributes], useLimits: Bool, lowerLimit: Double, upperLimit: Double) -> [ChartValues] {
        return data.map { item in
            return ChartValues(
                x: item.x,
                y: item.y,
                color: !useLimits ? "Default" : item.y < lowerLimit ? "Low" : item.y > upperLimit ? "High" : "Good"
            )
        }
    }
}
