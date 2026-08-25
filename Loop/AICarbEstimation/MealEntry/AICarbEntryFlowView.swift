//
//  AICarbEntryFlowView.swift
//  Loop
//
//  AI entry point container (§4): composer (text and/or photo) → pipeline →
//  pre-filled meal entry screen. Cancelling the composer returns to the home
//  screen. It NEVER saves — MealEntryView's submit is the only save path.
//

import SwiftUI

struct AICarbEntryFlowView: View {
    @ObservedObject var viewModel: MealEntryViewModel
    let coordinator: CarbEstimationCoordinator

    @Environment(\.dismissAction) private var dismiss

    enum Phase { case compose, working, entry }
    @State private var phase: Phase = .compose
    @State private var note: String = ""
    @State private var images: [UIImage] = []
    @State private var errorMessage: String?
    @State private var pulse = false
    @State private var captionIndex = 0

    /// Rotating captions for the working screen — purely cosmetic, no bearing
    /// on the estimate itself.
    private static let workingCaptions: [String] = [
        NSLocalizedString("Estimating carbs…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Counting calories…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Consulting the food oracle…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Splitting fast vs. slow carbs…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Eyeballing portion sizes…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Considering the protein…", comment: "Progress label while AI estimates carbs"),
        NSLocalizedString("Shaping up the numbers…", comment: "Progress label while AI estimates carbs")
    ]

    var body: some View {
        switch phase {
        case .compose:
            AICarbComposerView(
                note: $note,
                images: $images,
                onContinue: runEstimate,
                onCancel: dismiss           // cancelling AI returns to the home screen
            )
        case .working:
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                    .opacity(pulse ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                ProgressView()
                Text(Self.workingCaptions[captionIndex])
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .id(captionIndex)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .padding(36)
            .onAppear {
                pulse = true
                captionIndex = 0
            }
            .task {
                // Rotate captions while the estimate is in flight; harmless if
                // this outlives the phase since the view is gone by then.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        captionIndex = (captionIndex + 1) % Self.workingCaptions.count
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: phase)
        case .entry:
            MealEntryView(viewModel: viewModel)
                .alert(
                    Text("Estimation Unavailable", comment: "AI estimation failure alert title"),
                    isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
                ) {
                    Button(NSLocalizedString("OK", comment: "OK"), role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    private func runEstimate() {
        phase = .working
        let imageDatas = images.compactMap { $0.jpegData(compressionQuality: 0.7) }
        let noteToSend = note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note
        // The first photo becomes the meal's photo automatically (user can change it).
        if let first = images.first {
            viewModel.mealImage = first
            viewModel.usesPhoto = true
        }
        Task { @MainActor in
            do {
                let estimate = try await coordinator.estimate(images: imageDatas, note: noteToSend)
                viewModel.applyEstimate(estimate)
                if let noteToSend, viewModel.mealName.isEmpty { viewModel.mealName = noteToSend }
            } catch {
                errorMessage = (error as? CarbEstimationError)?.errorDescription
                    ?? NSLocalizedString("Enter your meal manually.", comment: "Fallback message")
            }
            phase = .entry   // fall through to editable manual entry either way
        }
    }
}
