//
//  ManualEntryDoseView.swift
//  Loop
//
//  Created by Pete Schwamb on 12/29/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Combine
import HealthKit
import SwiftUI
import LoopKit
import LoopKitUI
import LoopUI


struct ManualEntryDoseView: View {

    @ObservedObject var viewModel: ManualEntryDoseViewModel

    @State private var enteredBolusString = ""
    @State private var isInteractingWithChart = false

    @FocusState private var bolusFieldFocused: Bool

    @Environment(\.dismissAction) var dismiss


    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                List {
                    self.chartSection
                    self.summarySection
                }
                .insetGroupedListStyle()
            }
            .navigationBarTitle(self.title)
            .loopSoftTopEdge()
            .supportedInterfaceOrientations(.portrait)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bolusFieldFocused {
                    keyboardAccessory
                } else {
                    actionArea
                }
            }
        }
    }
    
    private var title: Text {
        return Text("Log Dose", comment: "Title for dose logging screen")
    }

    private var chartSection: some View {
        Section {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    activeCarbsLabel
                    Spacer(minLength: 8)
                    currentGlucoseLabel
                    Spacer(minLength: 8)
                    activeInsulinLabel
                }

                // Use a ZStack to allow horizontally clipping the predicted glucose chart,
                // without clipping the point label on highlight, which draws outside the view's bounds.
                ZStack(alignment: .topLeading) {
                    Text("Glucose", comment: "Title for predicted glucose chart on bolus screen")
                        .font(.subheadline)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isInteractingWithChart ? 0 : 1)

                    predictedGlucoseChart
                        .padding(.horizontal, -4)
                        .padding(.top, UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 8) // Leave space for the 'Glucose' label + spacing
                        .clipped()
                }
                .frame(height: ceil(UIScreen.main.bounds.height / 4))
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var activeCarbsLabel: some View {
        LabeledQuantity(
            label: Text("Active Carbs", comment: "Title describing quantity of still-absorbing carbohydrates"),
            quantity: viewModel.activeCarbs,
            unit: .gram()
        )
    }
    
    @ViewBuilder
    private var activeInsulinLabel: some View {
        LabeledQuantity(
            label: Text("Active Insulin", comment: "Title describing quantity of still-absorbing insulin"),
            quantity: viewModel.activeInsulin,
            unit: .internationalUnit(),
            maxFractionDigits: 2
        )
    }
    
    @ViewBuilder
    private var currentGlucoseLabel: some View {
        LabeledQuantity(
            label: Text("Current Glucose", comment: "Title describing current glucose value"),
            quantity: viewModel.glucoseValues.last?.quantity, // latest glucose
            unit: viewModel.glucoseUnit,                      // mg/dL or mmol/L based on view model
            maxFractionDigits: viewModel.glucoseUnit == .milligramsPerDeciliter ? 0 : 1
        )
    }

    private var predictedGlucoseChart: some View {
        PredictedGlucoseChartView(
            chartManager: viewModel.chartManager,
            glucoseUnit: viewModel.glucoseUnit,
            glucoseValues: viewModel.glucoseValues,
            predictedGlucoseValues: viewModel.predictedGlucoseValues,
            targetGlucoseSchedule: viewModel.targetGlucoseSchedule,
            preMealOverride: viewModel.preMealOverride,
            scheduleOverride: viewModel.scheduleOverride,
            dateInterval: viewModel.chartDateInterval,
            isInteractingWithChart: $isInteractingWithChart
        )
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 16) {
                titleText
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)

                datePicker
            }
            .padding(.top, 8)
            
            insulinTypePicker

            bolusEntryRow
        }
    }
    
    private var titleText: Text {
        return Text("Dose Summary", comment: "Title for card to log dose")
    }

    private var glucoseFormatter: NumberFormatter {
        QuantityFormatter(for: viewModel.glucoseUnit).numberFormatter
    }

    private static let doseAmountFormatter: NumberFormatter = {
        let quantityFormatter = QuantityFormatter(for: .internationalUnit())
        return quantityFormatter.numberFormatter
    }()
    
    private var insulinTypePicker: some View {
        ExpandablePicker(
            with: viewModel.insulinTypePickerOptions,
            selectedValue: $viewModel.selectedInsulinType,
            label: NSLocalizedString("Insulin Type", comment: "Insulin type label")
        )
    }
    private var datePicker: some View {
        // Allow 6 hours before & after due to longest DIA
        ZStack(alignment: .topLeading) {
            DatePicker(
                String(""),
                selection: $viewModel.selectedDoseDate,
                in: Date().addingTimeInterval(-.hours(6))...Date().addingTimeInterval(.hours(6)),
                displayedComponents: [.date, .hourAndMinute]
            )
            .pickerStyle(WheelPickerStyle())
            
            Text(NSLocalizedString("Date", comment: "Date picker label"))
        }
    }
    

    private var bolusEntryRow: some View {
        HStack {
            Text("Bolus", comment: "Label for bolus entry row on bolus screen")
            Spacer()
            HStack(alignment: .firstTextBaseline) {
                TextField(Self.doseAmountFormatter.string(from: 0.0)!, text: typedBolusEntry)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.title)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.loopAccent)
                .focused($bolusFieldFocused)
                .onChange(of: enteredBolusString) { newValue in
                    if newValue.count > 5 {
                        enteredBolusString = String(newValue.prefix(5))
                    }
                }
                bolusUnitsLabel
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bolusUnitsLabel: some View {
        Text(QuantityFormatter(for: .internationalUnit()).localizedUnitStringWithPlurality())
            .foregroundColor(Color(.secondaryLabel))
    }

    private var typedBolusEntry: Binding<String> {
        Binding(
            get: { self.enteredBolusString },
            set: { newValue in
                self.viewModel.enteredBolus = HKQuantity(unit: .internationalUnit(), doubleValue: Self.doseAmountFormatter.number(from: newValue)?.doubleValue ?? 0)
                self.enteredBolusString = newValue
            }
        )
    }

    private var enteredBolusAmount: Double {
        Self.doseAmountFormatter.number(from: enteredBolusString)?.doubleValue ?? 0
    }

    private var actionButtonDisabled: Bool {
        enteredBolusAmount <= 0
    }

    /// The row shown in place of the action area while the keypad is up.
    ///
    /// Deliberately NOT a `ToolbarItemGroup(placement: .keyboard)`, which is
    /// what this used to be: that placement welds the button to the keyboard's
    /// top edge, so "Done" sat flush on the keys with nothing between them. As a
    /// bottom safe-area inset it is lifted by the same keyboard avoidance that
    /// moves everything else, and it can keep a deliberate gap above the keys.
    private var keyboardAccessory: some View {
        HStack {
            Spacer()
            Button(action: { bolusFieldFocused = false }) {
                Text("Done", comment: "Button label to dismiss the keypad")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(GlassButtonStyle(in: Capsule()))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, Self.keyboardClearance)
        // ⚠️ NO BACKGROUND. A filled row here paints a grey band across the full
        // width above the keyboard — invisible against the screen background in
        // some places, an obvious block over a tile in others. The Done pill
        // carries its own glass; the row itself is only a position.
    }

    /// Gap between the Done row and the top of the keyboard.
    private static let keyboardClearance: CGFloat = 12

    private var actionArea: some View {
        VStack(spacing: 0) {
            actionButton.disabled(actionButtonDisabled)
        }
        .padding(.bottom) // FIXME: unnecessary on iPhone 8 size devices
        .background(Color(.secondarySystemGroupedBackground).shadow(radius: 5))
    }
            
    private var actionButton: some View {
        Button<Text>(
            action: {
                self.viewModel.saveManualDose(onSuccess: self.dismiss)
            },
            label: {
                return Text("Log Dose", comment: "Button text to log a dose")
            }
        )
        .buttonStyle(PillActionButtonStyle(.primary))
        .padding()
    }
}

extension InsulinType: @retroactive Labeled {
    public var label: String {
        return title
    }
}
