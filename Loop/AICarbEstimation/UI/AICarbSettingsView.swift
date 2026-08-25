//
//  AICarbSettingsView.swift
//  Loop
//
//  Settings card for the optional AI-assisted carb estimation feature.
//  Structure/altitude modeled on the existing service settings screens for
//  consistency (no functional connection to any service).
//
//  Scope of Step A: master toggle, provider selection, and secure key/endpoint
//  entry. The actual estimation pipeline is wired in later steps.
//

import SwiftUI

/// Backs `AICarbSettingsView`. Bridges the value-type `CarbEstimationSettings`
/// and `CarbAIKeychain` into `@Published` state SwiftUI can bind to.
final class AICarbSettingsViewModel: ObservableObject {
    private var settings: CarbEstimationSettings
    private let keychain: CarbAIKeychain

    @Published var isEnabled: Bool {
        didSet { settings.isEnabled = isEnabled }
    }
    @Published var provider: CarbEstimationProviderType {
        didSet {
            settings.provider = provider
            loadKeyForSelectedProvider()
        }
    }
    @Published var customEndpoint: String {
        didSet { settings.customEndpoint = customEndpoint }
    }
    @Published var isWebSearchEnabled: Bool {
        didSet { settings.isWebSearchEnabled = isWebSearchEnabled }
    }

    /// Working copy of the selected provider's API key. Committed to Keychain on commit().
    @Published var apiKey: String = ""

    init(settings: CarbEstimationSettings = CarbEstimationSettings(),
         keychain: CarbAIKeychain = CarbAIKeychain()) {
        self.settings = settings
        self.keychain = keychain
        self.isEnabled = settings.isEnabled
        self.provider = settings.provider
        self.customEndpoint = settings.customEndpoint
        self.isWebSearchEnabled = settings.isWebSearchEnabled
        loadKeyForSelectedProvider()
    }

    private func loadKeyForSelectedProvider() {
        apiKey = keychain.apiKey(for: provider) ?? ""
    }

    /// Persist the API key for the selected provider to the Keychain.
    /// Called when the field loses focus / the view disappears.
    func commitAPIKey() {
        guard provider.requiresAPIKey else { return }
        keychain.setAPIKey(apiKey, for: provider)
    }

    /// Whether the current configuration is usable (for surfacing a warning).
    var isConfigurationComplete: Bool {
        if provider.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if provider.requiresEndpoint && customEndpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }
}

struct AICarbSettingsView: View {
    @StateObject private var viewModel = AICarbSettingsViewModel()
    @State private var showEnableConfirmation = false
    @Environment(\.dismiss) private var dismiss

    /// Turning ON requires confirmation; turning OFF applies immediately
    /// (off is the safe direction — it hard-disconnects the network layer).
    private var confirmedEnableBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isEnabled },
            set: { newValue in
                if newValue {
                    showEnableConfirmation = true
                } else {
                    viewModel.isEnabled = false
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: confirmedEnableBinding) {
                    Text("Enable AI Carb Estimation", comment: "Toggle label for enabling AI carb estimation")
                }
            } footer: {
                Text("When off, Loop behaves exactly as it does today. AI is optional and never saves a carb entry without your confirmation.", comment: "Footer explaining the AI carb estimation master toggle")
            }

            if viewModel.isEnabled {
                providerSection

                if viewModel.provider.requiresEndpoint {
                    endpointSection
                }

                if viewModel.provider.requiresAPIKey {
                    apiKeySection
                }

                if viewModel.provider.supportsWebSearch {
                    webSearchSection
                }
            }

            // Prompt editor is available even while AI is off — editing is
            // fully local and nothing is sent anywhere until AI is enabled.
            promptSection
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("AI Carb Estimation", comment: "Title of the AI carb estimation settings screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.commitAPIKey()
                    dismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                        Text("Back", comment: "Back button in AI carb settings")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    viewModel.commitAPIKey()
                    dismiss()
                } label: {
                    Text("Done", comment: "Done button in AI carb settings").fontWeight(.semibold)
                }
            }
        }
        .onDisappear { viewModel.commitAPIKey() }
        .alert(
            Text("Turn on AI Carb Estimation?", comment: "Title of AI enable confirmation"),
            isPresented: $showEnableConfirmation
        ) {
            Button(NSLocalizedString("Turn On", comment: "Confirm enabling AI")) {
                viewModel.isEnabled = true
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text("Meal photos and notes you submit will be sent to the selected AI provider for estimation. Nothing is ever saved without your confirmation.", comment: "Body of AI enable confirmation")
        }
    }

    private var promptSection: some View {
        Section {
            NavigationLink {
                AIPromptEditorView()
            } label: {
                Label {
                    Text("AI Prompt", comment: "Row opening the AI prompt editor")
                } icon: {
                    Image(systemName: "text.quote")
                }
            }
        } footer: {
            Text("View and edit the instructions sent to the AI, with full version history. Editing is stored only on this device.", comment: "Footer of the AI prompt editor row")
        }
    }

    private var webSearchSection: some View {
        Section {
            Toggle(isOn: $viewModel.isWebSearchEnabled) {
                Text("Look Up Nutrition Facts", comment: "Toggle label for AI web search of nutrition facts")
            }
        } footer: {
            Text("When on, the AI may search the web for published nutrition facts of branded or restaurant foods to improve its estimate. This sends the food's name to the provider's search service and may be slower. Off by default.", comment: "Footer explaining the AI web search toggle")
        }
    }

    private var providerSection: some View {
        Section {
            Picker(selection: $viewModel.provider) {
                ForEach(CarbEstimationProviderType.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            } label: {
                Text("Provider", comment: "Label for AI carb estimation provider picker")
            }
        } footer: {
            Text("Apple On-Device runs privately on supported iPhones with no API key. Other providers send the meal photo to their service.", comment: "Footer describing AI carb providers")
        }
    }

    private var endpointSection: some View {
        Section {
            TextField(
                NSLocalizedString("https://example.com/estimate", comment: "Placeholder for custom AI endpoint URL"),
                text: $viewModel.customEndpoint
            )
            .textContentType(.URL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text("Endpoint", comment: "Header for custom AI endpoint URL field")
        }
    }

    private var apiKeySection: some View {
        Section {
            SecureField(
                NSLocalizedString("API Key", comment: "Placeholder for AI provider API key field"),
                text: $viewModel.apiKey
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { viewModel.commitAPIKey() }
        } header: {
            Text("API Key", comment: "Header for AI provider API key field")
        } footer: {
            Text("Stored securely in the iOS Keychain on this device only.", comment: "Footer explaining API key is stored in Keychain")
        }
    }
}
