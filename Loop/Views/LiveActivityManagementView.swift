//
//  LiveActivityManagementView.swift
//  Loop
//
//  Created by Bastiaan Verhaar on 04/07/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI
import LoopCore
import HealthKit

struct LiveActivityManagementView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @StateObject private var viewModel = LiveActivityManagementViewModel()
    @State private var previousViewModel = LiveActivityManagementViewModel()
    
    @State private var isDirty = false
   
    var body: some View {
        VStack {
            List {
                Section {
                    Toggle(NSLocalizedString("Enabled", comment: "Title for enable live activity toggle"), isOn: $viewModel.enabled)
                        .onChange(of: viewModel.enabled) { _ in
                            self.isDirty = previousViewModel.enabled != viewModel.enabled
                        }
                } header: {
                    Text("Lock Screen / Dynamic Island / CarPlay")
                } footer: {
                    Text("Shows a live glucose activity on your Lock Screen, in the Dynamic Island (the pill around the front camera on iPhone 14 Pro and later), and on CarPlay. It updates automatically as new readings arrive. Tap and hold the Dynamic Island to expand it.", comment: "Explanation of the live activity master toggle")
                }

                Section {
                    ExpandableSetting(
                        isEditing: $viewModel.isEditingMode,
                        leadingValueContent: {
                            Text(NSLocalizedString("Mode", comment: "Title for mode live activity toggle"))
                                .foregroundStyle(viewModel.isEditingMode ? .blue : .primary)
                        },
                        trailingValueContent: {
                            Text(viewModel.mode.name())
                                .foregroundStyle(viewModel.isEditingMode ? .blue : .primary)
                        },
                        expandedContent: {
                            ResizeablePicker(selection: self.$viewModel.mode.animation(),
                                             data: LiveActivityMode.all,
                                             formatter: { $0.name() })
                        }
                    )
                    .onChange(of: viewModel.mode) { _ in
                        self.isDirty = previousViewModel.mode != viewModel.mode
                    }
                } header: {
                    Text("Lock Screen Layout")
                } footer: {
                    Text("“Large” shows a full glucose chart on the Lock Screen; “Small” shows a compact single-line summary. This only affects the Lock Screen — the Dynamic Island and CarPlay layouts are fixed.", comment: "Explanation of the live activity mode picker")
                }

            }
            .animation(.easeInOut, value: UUID())
            .insetGroupedListStyle()
            
            Spacer()
            Button(action: save) {
                Text(NSLocalizedString("Save", comment: ""))
            }
            .buttonStyle(PillActionButtonStyle())
            .disabled(!isDirty)
            .padding([.bottom, .horizontal])
        }
            .navigationBarTitle(Text(NSLocalizedString("Live activity", comment: "Live activity screen title")))
            .loopSoftTopEdge()
    }
    
    @ViewBuilder
    private func TextInput(label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "no comment"))
            Spacer()
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
            Text(self.displayGlucosePreference.unit.localizedShortUnitString)
        }
    }
    
    private func save() {
        var settings = UserDefaults.standard.liveActivity ?? LiveActivitySettings()
        settings.enabled = viewModel.enabled
        settings.mode = viewModel.mode
        settings.addPredictiveLine = viewModel.addPredictiveLine
        settings.useLimits = viewModel.useLimits
        settings.upperLimitChartMmol = viewModel.upperLimitChartMmol
        settings.lowerLimitChartMmol = viewModel.lowerLimitChartMmol
        settings.upperLimitChartMg = viewModel.upperLimitChartMg
        settings.lowerLimitChartMg = viewModel.lowerLimitChartMg
        
        UserDefaults.standard.liveActivity = settings
        NotificationCenter.default.post(name: .LiveActivitySettingsChanged, object: settings)
        
        self.isDirty = false
        previousViewModel = LiveActivityManagementViewModel()
    }
}
