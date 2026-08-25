//
//  CustomAlertsView.swift
//  Loop
//
//  Settings for the user-configurable Loop-side alerts (fast glucose change,
//  sustained trend, low-insulin thresholds). Each TYPE supports multiple alarms,
//  and every alarm has its own direction/urgency/sound (incl. bundled Dexcom
//  tones with in-app preview). Persists to CustomAlertSettings (UserDefaults).
//  Read by CustomAlertMonitor; nothing here touches dosing.
//

import SwiftUI
import LoopKitUI

final class CustomAlertsViewModel: ObservableObject {
    @Published var settings: CustomAlertSettings {
        didSet { settings.save() }
    }

    init() {
        self.settings = CustomAlertSettings.load()
    }

    // MARK: Rate alarms
    func addRateAlarm() { settings.rateAlarms.append(RateAlarm()) }
    func removeRateAlarms(at offsets: IndexSet) { settings.rateAlarms.remove(atOffsets: offsets) }

    // MARK: Sustained alarms
    func addSustainedAlarm() { settings.sustainedAlarms.append(SustainedAlarm()) }
    func removeSustainedAlarms(at offsets: IndexSet) { settings.sustainedAlarms.remove(atOffsets: offsets) }

    // MARK: Reservoir thresholds (kept sorted high→low)
    func addReservoirThreshold() {
        let lowest = settings.reservoirThresholds.map(\.units).min() ?? 10
        let next = max(1, (lowest - 5).rounded())
        settings.reservoirThresholds.append(ReservoirThreshold(units: next))
        settings.reservoirThresholds.sort { $0.units > $1.units }
    }
    func removeReservoirThresholds(at offsets: IndexSet) {
        settings.reservoirThresholds.remove(atOffsets: offsets)
    }
}

struct CustomAlertsView: View {
    @StateObject private var viewModel = CustomAlertsViewModel()

    /// Which row's number wheel is open, if any. Same one-at-a-time model the
    /// carb-entry screen uses for its Offset Time / Absorption Time wheels.
    @State private var ratePickerID: UUID?
    @State private var sustainedPickerID: UUID?
    @State private var reservoirPickerID: UUID?

    private let rateOptions: [Double] = Array(stride(from: 1.0, through: 15.0, by: 0.5))
    private let sustainedOptions: [Double] = Array(stride(from: 10.0, through: 180.0, by: 5.0))
    private let reservoirOptions: [Double] = Array(stride(from: 1.0, through: 300.0, by: 1.0))

    var body: some View {
        List {
            rateSection
            sustainedSection
            reservoirSection
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("Custom Alerts", comment: "Title of the custom alerts screen"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { AlertSoundPreviewPlayer.shared.stop() }
    }

    // MARK: - Fast glucose change

    private var rateSection: some View {
        Section {
            ForEach(viewModel.settings.rateAlarms.indices, id: \.self) { index in
                rateRow(index)
            }
            .onDelete(perform: viewModel.removeRateAlarms)

            addButton(NSLocalizedString("Add Fast-Change Alarm", comment: "Add rate alarm")) {
                viewModel.addRateAlarm()
            }
        } header: {
            Text("Fast Glucose Change", comment: "Header for fast glucose change alerts")
        } footer: {
            Text("Alerts when glucose changes faster than the chosen rate. Add several — each can have its own rate, direction, urgency, and sound.", comment: "Footer for fast glucose change alert")
        }
    }

    @ViewBuilder
    private func rateRow(_ index: Int) -> some View {
        let binding = $viewModel.settings.rateAlarms[index]
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
            ForEach(viewModel.settings.sustainedAlarms.indices, id: \.self) { index in
                sustainedRow(index)
            }
            .onDelete(perform: viewModel.removeSustainedAlarms)

            addButton(NSLocalizedString("Add Sustained-Trend Alarm", comment: "Add sustained alarm")) {
                viewModel.addSustainedAlarm()
            }
        } header: {
            Text("Sustained Trend", comment: "Header for sustained trend alerts")
        } footer: {
            Text("Alerts when glucose keeps moving in one direction for the chosen time. Add several — each can have its own duration, direction, urgency, and sound.", comment: "Footer for sustained trend alert")
        }
    }

    @ViewBuilder
    private func sustainedRow(_ index: Int) -> some View {
        let binding = $viewModel.settings.sustainedAlarms[index]
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
            ForEach(viewModel.settings.reservoirThresholds.indices, id: \.self) { index in
                reservoirRow(index)
            }
            .onDelete(perform: viewModel.removeReservoirThresholds)

            addButton(NSLocalizedString("Add Threshold", comment: "Add reservoir threshold")) {
                viewModel.addReservoirThreshold()
            }
        } header: {
            Text("Low Insulin (Pod)", comment: "Header for low insulin alerts")
        } footer: {
            Text("Alerts as pod insulin remaining crosses each threshold. Add several — each can have its own urgency and sound.", comment: "Footer for low insulin alert")
        }
    }

    @ViewBuilder
    private func reservoirRow(_ index: Int) -> some View {
        let binding = $viewModel.settings.reservoirThresholds[index]
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
    /// value off the grid (older settings, changed stride) would otherwise show
    /// no selection at all. Reading snaps to the nearest option; writing is direct.
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
    /// Only the glucose alarms (rate / sustained trend) get a sound picker —
    /// the reservoir row shows a fixed "Pump Beep" instead, so no `isPodAlert`
    /// variant is needed here.
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
}
