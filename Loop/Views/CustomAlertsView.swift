//
//  CustomAlertsView.swift
//  Loop
//
//  Settings for the user-configurable Loop-side alerts (high/low glucose, fast
//  glucose change, sustained trend, low-insulin thresholds).
//
//  Alarms are grouped into SETS ("Day", "Night", …). A set can be switched off or
//  limited to a time-of-day window as a unit, so one toggle silences everything it
//  contains. Every alarm still keeps its own direction/urgency/sound (incl. the
//  bundled Dexcom tones, with in-app preview).
//
//  Persists to CustomAlertSettings (UserDefaults). Read by CustomAlertMonitor;
//  nothing here touches dosing.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

final class CustomAlertsViewModel: ObservableObject {
    @Published var settings: CustomAlertSettings {
        didSet { settings.save() }
    }

    init() {
        self.settings = CustomAlertSettings.load()
    }

    func addSet(_ newSet: AlertSet) { settings.sets.append(newSet) }
    func removeSets(at offsets: IndexSet) { settings.sets.remove(atOffsets: offsets) }
}

// MARK: - Set list

struct CustomAlertsView: View {
    @StateObject private var viewModel = CustomAlertsViewModel()
    @Environment(\.dismiss) private var dismiss

    /// The unit the user reads glucose in. Passed in rather than taken from the
    /// environment: `AlertManagementView` is pushed from `SettingsView` without
    /// `displayGlucosePreference` injected, so an `@EnvironmentObject` here would
    /// crash at runtime. Thresholds are always STORED in mg/dL regardless.
    private let displayGlucoseUnit: HKUnit

    init(displayGlucoseUnit: HKUnit = .milligramsPerDeciliter) {
        self.displayGlucoseUnit = displayGlucoseUnit
    }

    var body: some View {
        List {
            Section {
                // Bound by element identity, NOT by index. An index-keyed ForEach
                // hands each row a `sets[i]` binding that keeps pointing at slot i
                // after a delete — so the row below a deleted set reads a shifted
                // element, and the pushed detail view reads past the end and
                // crashes. Identity bindings can't drift.
                ForEach($viewModel.settings.sets) { $alertSet in
                    setRow($alertSet)
                }
                .onDelete(perform: viewModel.removeSets)
            } header: {
                Text("Alert Sets", comment: "Header for the list of alert sets")
            } footer: {
                Text("Each set holds its own alarms. Switch a set off — or give it a time window — to silence everything in it at once.", comment: "Footer for the alert sets list")
            }

            Section {
                Button { viewModel.addSet(AlertSet()) } label: {
                    Label(NSLocalizedString("Add Set", comment: "Add an empty alert set"),
                          systemImage: "plus.circle")
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("Custom Alerts", comment: "Title of the custom alerts screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    AlertSoundPreviewPlayer.shared.stop()
                    dismiss()
                } label: {
                    Text("Done", comment: "Done button in custom alerts").fontWeight(.semibold)
                }
            }
        }
        .onDisappear { AlertSoundPreviewPlayer.shared.stop() }
    }

    @ViewBuilder
    private func setRow(_ binding: Binding<AlertSet>) -> some View {
        let alertSet = binding.wrappedValue
        NavigationLink {
            AlertSetDetailView(alertSet: binding, displayGlucoseUnit: displayGlucoseUnit)
        } label: {
            HStack {
                // A filled dot means "armed right now" — off and out-of-window
                // sets both read as hollow, which is what actually matters.
                Image(systemName: alertSet.isActive(at: Date()) ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(alertSet.isActive(at: Date()) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alertSet.name)
                        .foregroundStyle(alertSet.enabled ? .primary : .secondary)
                    Text(subtitle(for: alertSet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                binding.wrappedValue.enabled.toggle()
            } label: {
                Label(alertSet.enabled
                        ? NSLocalizedString("Disable", comment: "Swipe action disabling an alert set")
                        : NSLocalizedString("Enable", comment: "Swipe action enabling an alert set"),
                      systemImage: alertSet.enabled ? "bell.slash" : "bell")
            }
            .tint(alertSet.enabled ? .gray : .accentColor)
        }
    }

    private func subtitle(for alertSet: AlertSet) -> String {
        let count = String(format: NSLocalizedString("%d alarms", comment: "Number of alarms in an alert set"),
                           alertSet.alarmCount)
        guard alertSet.enabled else {
            return NSLocalizedString("Off", comment: "An alert set that is switched off") + " · " + count
        }
        guard alertSet.schedule.enabled else {
            return NSLocalizedString("All day", comment: "An alert set with no time window") + " · " + count
        }
        return "\(Self.timeString(alertSet.schedule.startMinutes))–\(Self.timeString(alertSet.schedule.endMinutes)) · \(count)"
    }

    /// Minutes-from-midnight rendered in the user's locale (so 22:00 vs 10 PM).
    static func timeString(_ minutes: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .minute, value: minutes,
                                 to: calendar.startOfDay(for: Date())) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - One set's alarms

struct AlertSetDetailView: View {
    @Binding var alertSet: AlertSet
    let displayGlucoseUnit: HKUnit

    /// Which row's number wheel is open, if any. Same one-at-a-time model the
    /// carb-entry screen uses for its Offset Time / Absorption Time wheels.
    @State private var glucosePickerID: UUID?
    @State private var snoozePickerID: UUID?
    @State private var ratePickerID: UUID?
    @State private var sustainedPickerID: UUID?
    @State private var reservoirPickerID: UUID?

    private let rateOptions: [Double] = Array(stride(from: 1.0, through: 15.0, by: 0.5))
    private let sustainedOptions: [Double] = Array(stride(from: 10.0, through: 180.0, by: 5.0))
    private let reservoirOptions: [Double] = Array(stride(from: 1.0, through: 300.0, by: 1.0))
    private let snoozeOptions: [Double] = Array(stride(from: 5.0, through: 120.0, by: 5.0))

    /// Threshold choices, in mg/dL. In mmol/L the grid is built in mmol (0.1
    /// steps) and converted, so the wheel shows round numbers in the user's unit.
    ///
    /// Built ONCE in init, not computed per body pass: this is 361 values in
    /// mg/dL, and rebuilding it on every redraw of every alarm row made
    /// scrolling and expanding rows visibly stutter.
    private let glucoseOptions: [Double]

    init(alertSet: Binding<AlertSet>, displayGlucoseUnit: HKUnit) {
        self._alertSet = alertSet
        self.displayGlucoseUnit = displayGlucoseUnit
        if displayGlucoseUnit == .millimolesPerLiter {
            self.glucoseOptions = stride(from: 2.2, through: 22.2, by: 0.1).map {
                HKQuantity(unit: .millimolesPerLiter, doubleValue: $0)
                    .doubleValue(for: .milligramsPerDeciliter)
            }
        } else {
            self.glucoseOptions = Array(stride(from: 40.0, through: 400.0, by: 1.0))
        }
    }

    var body: some View {
        List {
            setSection
            glucoseSection
            rateSection
            sustainedSection
            reservoirSection
        }
        .insetGroupedListStyle()
        .navigationTitle(alertSet.name)
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .onDisappear { AlertSoundPreviewPlayer.shared.stop() }
    }

    // MARK: - The set itself

    private var setSection: some View {
        Section {
            TextField(NSLocalizedString("Name", comment: "Label for the alert set name field"),
                      text: $alertSet.name)
            Toggle(NSLocalizedString("Enabled", comment: "Enable the whole alert set"),
                   isOn: $alertSet.enabled)
            Toggle(NSLocalizedString("Only at Certain Times", comment: "Limit an alert set to a time window"),
                   isOn: $alertSet.schedule.enabled)
            if alertSet.schedule.enabled {
                timeRow(NSLocalizedString("From", comment: "Start of an alert set's time window"),
                        minutes: $alertSet.schedule.startMinutes)
                timeRow(NSLocalizedString("Until", comment: "End of an alert set's time window"),
                        minutes: $alertSet.schedule.endMinutes)
            }
        } header: {
            Text("Set", comment: "Header for the alert set's own settings")
        } footer: {
            if alertSet.schedule.enabled && alertSet.schedule.endMinutes <= alertSet.schedule.startMinutes {
                Text("This window runs overnight, past midnight.", comment: "Footer explaining a wrapping alert window")
            } else {
                Text("Everything below only fires while this set is on and inside its window.", comment: "Footer for the alert set section")
            }
        }
    }

    /// Compact, NOT wheel: the system popover dismisses itself, matching the meal
    /// time control in the carb-entry screen.
    private func timeRow(_ label: String, minutes: Binding<Int>) -> some View {
        DatePicker(label, selection: timeBinding(minutes), displayedComponents: [.hourAndMinute])
            .datePickerStyle(.compact)
    }

    /// Bridges minutes-from-midnight (how a schedule is stored, so it means the
    /// same thing every day) to the `Date` a `DatePicker` wants.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                return calendar.date(byAdding: .minute, value: minutes.wrappedValue,
                                     to: calendar.startOfDay(for: Date())) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    // MARK: - High / low glucose

    private var glucoseSection: some View {
        Section {
            ForEach($alertSet.glucoseAlarms) { $alarm in
                glucoseRow($alarm)
            }
            .onDelete { alertSet.glucoseAlarms.remove(atOffsets: $0) }

            addButton(NSLocalizedString("Add High Alert", comment: "Add a high glucose alarm")) {
                alertSet.glucoseAlarms.append(
                    GlucoseAlarm(threshold: 180, isAbove: true, urgency: .normal, sound: .dexHigh))
            }
            addButton(NSLocalizedString("Add Low Alert", comment: "Add a low glucose alarm")) {
                alertSet.glucoseAlarms.append(
                    GlucoseAlarm(threshold: 70, isAbove: false, urgency: .urgent, sound: .dexLow))
            }
        } header: {
            Text("High & Low Glucose", comment: "Header for high/low glucose alerts")
        } footer: {
            Text("Alerts when glucose reaches a level you choose. While you stay above (or below) it, the alert repeats after its snooze.", comment: "Footer for high/low glucose alerts")
        }
    }

    @ViewBuilder
    private func glucoseRow(_ binding: Binding<GlucoseAlarm>) -> some View {
        let alarm = binding.wrappedValue
        DisclosureGroup {
            Toggle(NSLocalizedString("Enabled", comment: "Enable alarm"), isOn: binding.enabled)
            wheelRow(NSLocalizedString("Alert Level", comment: "Label for the high/low glucose threshold"),
                     selection: binding.threshold,
                     options: glucoseOptions,
                     isPresented: presentation($glucosePickerID, id: alarm.id),
                     format: glucoseText)
            wheelRow(NSLocalizedString("Snooze", comment: "Label for how long a high/low alert stays quiet after firing"),
                     selection: binding.snoozeMinutes,
                     options: snoozeOptions,
                     isPresented: presentation($snoozePickerID, id: alarm.id)) {
                "\(Int($0)) min"
            }
            urgencyPicker(selection: binding.urgency)
            soundControls(selection: binding.sound)
        } label: {
            summaryLabel(enabled: alarm.enabled,
                         title: alarm.isAbove
                            ? NSLocalizedString("High", comment: "Title of a high glucose alarm row")
                            : NSLocalizedString("Low", comment: "Title of a low glucose alarm row"),
                         detail: glucoseText(alarm.threshold))
        }
    }

    /// Renders a mg/dL threshold in the user's display unit.
    private func glucoseText(_ mgdl: Double) -> String {
        let converted = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl)
            .doubleValue(for: displayGlucoseUnit)
        let digits = displayGlucoseUnit == .millimolesPerLiter ? 1 : 0
        return String(format: "%.\(digits)f %@", converted, displayGlucoseUnit.shortLocalizedUnitString())
    }

    // MARK: - Fast glucose change

    private var rateSection: some View {
        Section {
            ForEach($alertSet.rateAlarms) { $alarm in
                rateRow($alarm)
            }
            .onDelete { alertSet.rateAlarms.remove(atOffsets: $0) }

            addButton(NSLocalizedString("Add Fast-Change Alarm", comment: "Add rate alarm")) {
                alertSet.rateAlarms.append(RateAlarm())
            }
        } header: {
            Text("Fast Glucose Change", comment: "Header for fast glucose change alerts")
        } footer: {
            Text("Alerts when glucose changes faster than the chosen rate. Add several — each can have its own rate, direction, urgency, and sound.", comment: "Footer for fast glucose change alert")
        }
    }

    @ViewBuilder
    private func rateRow(_ binding: Binding<RateAlarm>) -> some View {
        DisclosureGroup {
            Toggle(NSLocalizedString("Enabled", comment: "Enable alarm"), isOn: binding.enabled)
            wheelRow(NSLocalizedString("Rate", comment: "Label for glucose rate threshold"),
                     selection: binding.threshold,
                     options: rateOptions,
                     isPresented: presentation($ratePickerID, id: binding.wrappedValue.id)) {
                "\(number($0)) mg/dL/min"
            }
            directionPicker(selection: binding.direction)
            urgencyPicker(selection: binding.urgency)
            soundControls(selection: binding.sound)
        } label: {
            summaryLabel(enabled: binding.wrappedValue.enabled,
                         title: binding.wrappedValue.direction.title,
                         detail: "> \(number(binding.wrappedValue.threshold)) mg/dL/min")
        }
    }

    // MARK: - Sustained trend

    private var sustainedSection: some View {
        Section {
            ForEach($alertSet.sustainedAlarms) { $alarm in
                sustainedRow($alarm)
            }
            .onDelete { alertSet.sustainedAlarms.remove(atOffsets: $0) }

            addButton(NSLocalizedString("Add Sustained-Trend Alarm", comment: "Add sustained alarm")) {
                alertSet.sustainedAlarms.append(SustainedAlarm())
            }
        } header: {
            Text("Sustained Trend", comment: "Header for sustained trend alerts")
        } footer: {
            Text("Alerts when glucose keeps moving in one direction for the chosen time. Add several — each can have its own duration, direction, urgency, and sound.", comment: "Footer for sustained trend alert")
        }
    }

    @ViewBuilder
    private func sustainedRow(_ binding: Binding<SustainedAlarm>) -> some View {
        DisclosureGroup {
            Toggle(NSLocalizedString("Enabled", comment: "Enable alarm"), isOn: binding.enabled)
            wheelRow(NSLocalizedString("Duration", comment: "Label for sustained trend duration"),
                     selection: binding.minutes,
                     options: sustainedOptions,
                     isPresented: presentation($sustainedPickerID, id: binding.wrappedValue.id)) {
                "\(Int($0)) min"
            }
            directionPicker(selection: binding.direction)
            urgencyPicker(selection: binding.urgency)
            soundControls(selection: binding.sound)
        } label: {
            summaryLabel(enabled: binding.wrappedValue.enabled,
                         title: binding.wrappedValue.direction.title,
                         detail: "\(Int(binding.wrappedValue.minutes)) min")
        }
    }

    // MARK: - Reservoir thresholds

    private var reservoirSection: some View {
        Section {
            ForEach($alertSet.reservoirThresholds) { $threshold in
                reservoirRow($threshold)
            }
            .onDelete { alertSet.reservoirThresholds.remove(atOffsets: $0) }

            addButton(NSLocalizedString("Add Threshold", comment: "Add reservoir threshold")) {
                let lowest = alertSet.reservoirThresholds.map(\.units).min() ?? 10
                alertSet.reservoirThresholds.append(ReservoirThreshold(units: max(1, (lowest - 5).rounded())))
                alertSet.reservoirThresholds.sort { $0.units > $1.units }
            }
        } header: {
            Text("Low Insulin (Pod)", comment: "Header for low insulin alerts")
        } footer: {
            Text("Alerts as pod insulin remaining crosses each threshold. Add several — each can have its own urgency and sound.", comment: "Footer for low insulin alert")
        }
    }

    @ViewBuilder
    private func reservoirRow(_ binding: Binding<ReservoirThreshold>) -> some View {
        DisclosureGroup {
            Toggle(NSLocalizedString("Enabled", comment: "Enable alarm"), isOn: binding.enabled)
            wheelRow(NSLocalizedString("Threshold", comment: "Label for reservoir threshold"),
                     selection: binding.units,
                     options: reservoirOptions,
                     isPresented: presentation($reservoirPickerID, id: binding.wrappedValue.id)) {
                "\(Int($0)) U"
            }
            urgencyPicker(selection: binding.urgency)
            // Deliberately NOT a picker: low insulin is signalled by the pod's
            // own beep — the same and only alarm this had before the custom
            // alerts existed — so there is nothing to choose between.
            labeledValue(NSLocalizedString("Sound", comment: "Label for alert sound"),
                         AlertSoundChoice.defaultSound.title(isPodAlert: true))
        } label: {
            summaryLabel(enabled: binding.wrappedValue.enabled,
                         title: NSLocalizedString("Below", comment: "Prefix for a reservoir threshold row"),
                         detail: "\(Int(binding.wrappedValue.units)) U")
        }
    }

    // MARK: - Shared controls

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
    }

    private func summaryLabel(enabled: Bool, title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func directionPicker(selection: Binding<TrendDirection>) -> some View {
        Picker(selection: selection) {
            ForEach(TrendDirection.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Direction", comment: "Label for trend direction picker")
        }
    }

    private func urgencyPicker(selection: Binding<AlertUrgency>) -> some View {
        Picker(selection: selection) {
            ForEach(AlertUrgency.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Urgency", comment: "Label for alert urgency picker")
        }
        .pickerStyle(.menu)
    }

    /// Sound picker plus an in-app preview button for the bundled tones.
    /// Only the glucose alarms (level / rate / sustained trend) get a sound
    /// picker — the reservoir row shows a fixed "Pump Beep" instead, so no
    /// `isPodAlert` variant is needed here.
    @ViewBuilder
    private func soundControls(selection: Binding<AlertSoundChoice>) -> some View {
        Picker(selection: selection) {
            ForEach(AlertSoundChoice.allCases) { Text($0.title()).tag($0) }
        } label: {
            Text("Sound", comment: "Label for alert sound picker")
        }
        .pickerStyle(.menu)

        if selection.wrappedValue.bundledResourceName != nil {
            Button {
                AlertSoundPreviewPlayer.shared.play(selection.wrappedValue)
            } label: {
                Label(NSLocalizedString("Preview Sound", comment: "Preview the selected alert sound"),
                      systemImage: "play.circle")
            }
        }
    }

    // MARK: - Number wheel (same interaction as carb entry)

    /// A numeric setting shown as a semibold glass chip that opens a `.wheel`
    /// picker in a self-dismissing popover — deliberately identical to the
    /// Offset Time / Absorption Time controls in `MealEntryView`.
    private func wheelRow(_ label: String,
                          selection: Binding<Double>,
                          options: [Double],
                          isPresented: Binding<Bool>,
                          format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Button { isPresented.wrappedValue = true } label: {
                Text(format(selection.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(GlassButtonStyle(in: Capsule()))
            .popover(isPresented: isPresented) {
                pickerHitShield {
                    Picker("", selection: snapped(selection, to: options)) {
                        ForEach(options, id: \.self) { Text(format($0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                }
                // Without this a popover becomes a sheet on iPhone.
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// The wheel needs its selection to be one of the offered options — a stored
    /// value off the grid (older settings, changed stride, an mmol/L grid that
    /// can't land exactly on a mg/dL default) would otherwise show no selection
    /// at all. Reading snaps to the nearest option; writing is direct.
    private func snapped(_ binding: Binding<Double>, to options: [Double]) -> Binding<Double> {
        Binding(
            get: {
                let v = binding.wrappedValue
                return options.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
            },
            set: { binding.wrappedValue = $0 }
        )
    }

    /// Bridges "which row's wheel is open" (a single optional id, so only one
    /// wheel can be up at a time) to the Bool a `.popover` wants.
    private func presentation(_ open: Binding<UUID?>, id: UUID) -> Binding<Bool> {
        Binding(
            get: { open.wrappedValue == id },
            set: { open.wrappedValue = $0 ? id : nil }
        )
    }

    /// Swallows the drag that would otherwise scroll the List behind the popover,
    /// and gives the wheel a sane fixed size. Mirrors `MealEntryView`.
    private func pickerHitShield<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0))
            content()
                .frame(width: 220, height: 180)
        }
        .frame(width: 260, height: 220)
    }
}
