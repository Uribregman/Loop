//
//  AIPromptEditorView.swift
//  Loop
//
//  Editor for the AI prompt template (free-language instructions) with undo/
//  redo, versioned history (rename / delete / preview / copy / restore).
//  Entirely offline: backed by CarbPromptStore (UserDefaults only); nothing in
//  this screen can reach the network.
//
//  The JSON output contract and the user's meal note are appended by
//  CarbEstimateWireFormat at request time and are NOT editable here — that
//  keeps the app always able to parse the model's reply.
//

import SwiftUI

/// Bridges the editor's UITextView so undo/redo use the view's NATIVE undo
/// manager — cursor position and scroll offset are preserved (no jumping).
final class PromptTextController: ObservableObject {
    weak var textView: UITextView?
    @Published var canUndo = false
    @Published var canRedo = false

    func undo() { textView?.undoManager?.undo(); refresh() }
    func redo() { textView?.undoManager?.redo(); refresh() }
    /// Deferred + change-gated: refresh() is called from updateUIView/delegate
    /// callbacks, i.e. during a SwiftUI view update — publishing there triggers
    /// "Publishing changes from within view updates is not allowed".
    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let undoManager = self.textView?.undoManager
            let newCanUndo = undoManager?.canUndo ?? false
            let newCanRedo = undoManager?.canRedo ?? false
            if self.canUndo != newCanUndo { self.canUndo = newCanUndo }
            if self.canRedo != newCanRedo { self.canRedo = newCanRedo }
        }
    }
}

/// UITextView-backed editor (SwiftUI's TextEditor resets the caret/scroll on
/// programmatic text replacement, which made undo/redo jump).
struct PromptTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: PromptTextController

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.text = text
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        controller.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Only replace on EXTERNAL changes (load / history restore) — while the
        // user types or undoes, the view is already the source of truth.
        if textView.text != text {
            textView.text = text
            textView.undoManager?.removeAllActions()
        }
        controller.refresh()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: PromptTextView
        init(_ parent: PromptTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.controller.refresh()
        }
    }
}

struct AIPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let store = CarbPromptStore.shared

    @State private var text: String = ""
    @State private var savedText: String = ""
    @StateObject private var textController = PromptTextController()
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PromptTextView(text: $text, controller: textController)
                .padding(8)
                .background(Color.loopScreenBackground.ignoresSafeArea())

            Text("The JSON output format and your meal note are added automatically and can't be edited, so Loop can always read the AI's answer.",
                 comment: "Footer of the AI prompt editor")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .navigationTitle(Text("AI Prompt", comment: "Title of the AI prompt editor"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()   // Back discards unsaved edits
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                        Text("Back", comment: "Back button in AI prompt editor")
                    }
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { textController.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!textController.canUndo)
                    .accessibilityLabel(Text("Undo", comment: "Undo button"))
                Button { textController.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!textController.canRedo)
                    .accessibilityLabel(Text("Redo", comment: "Redo button"))
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel(Text("History", comment: "Prompt history button"))
                Button {
                    save()
                    dismiss()
                } label: {
                    Text("Done", comment: "Done button in AI prompt editor").fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: load)
        .background(
            // Hidden push link (works inside NavigationView, like MealEntryView).
            NavigationLink(isActive: $showHistory) {
                AIPromptHistoryView(onActivePromptChanged: load)
            } label: { EmptyView() }
            .frame(width: 0, height: 0).opacity(0)
        )
    }

    private func load() {
        savedText = store.activeTemplate()
        text = savedText
    }

    private func save() {
        guard text != savedText else { return }
        store.saveNewVersion(text: text)
        savedText = text
    }
}

// MARK: - History

struct AIPromptHistoryView: View {
    var onActivePromptChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let store = CarbPromptStore.shared

    @State private var versions: [PromptVersion] = []
    @State private var renameTarget: PromptVersion?
    @State private var renameText = ""
    @State private var deleteTarget: PromptVersion?

    var body: some View {
        List {
            // Newest first; the top entry is the active prompt.
            ForEach(Array(versions.reversed().enumerated()), id: \.element.id) { index, version in
                NavigationLink {
                    AIPromptPreviewView(version: version, isActive: index == 0) {
                        store.restore(versionID: version.id)
                        reload()
                        onActivePromptChanged()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.name)
                            if index == 0 {
                                Text("Active", comment: "Badge on the active AI prompt version")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(version.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if versions.count > 1 {
                        Button(role: .destructive) {
                            deleteTarget = version
                        } label: {
                            Label(NSLocalizedString("Delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                    Button {
                        renameTarget = version
                        renameText = version.name
                    } label: {
                        Label(NSLocalizedString("Rename", comment: "Rename"), systemImage: "pencil")
                    }
                }
            }
        }
        .navigationTitle(Text("Prompt History", comment: "Title of the AI prompt history screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                        Text("Back", comment: "Back button in prompt history")
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .alert(
            Text("Rename Version", comment: "Rename prompt version alert title"),
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField(NSLocalizedString("Name", comment: "Version name field"), text: $renameText)
            Button(NSLocalizedString("Save", comment: "Save")) {
                if let target = renameTarget {
                    store.rename(versionID: target.id, to: renameText)
                    reload()
                }
                renameTarget = nil
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) { renameTarget = nil }
        }
        .alert(
            Text("Delete this version?", comment: "Delete prompt version alert title"),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button(NSLocalizedString("Delete", comment: "Delete"), role: .destructive) {
                if let target = deleteTarget {
                    store.delete(versionID: target.id)
                    reload()
                    onActivePromptChanged()
                }
                deleteTarget = nil
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Other versions are kept; this cannot be undone.", comment: "Delete prompt version alert body")
        }
    }

    private func reload() {
        var chain = store.versions()
        if chain.isEmpty {
            // Never edited: show the built-in default as the (virtual) original.
            chain = [PromptVersion(
                id: "builtin-default",
                name: NSLocalizedString("Original", comment: "Name of the built-in AI prompt version"),
                date: Date(),
                fullText: CarbPromptStore.defaultTemplate,
                delta: nil
            )]
        }
        versions = chain
    }
}

// MARK: - Preview / restore

struct AIPromptPreviewView: View {
    let version: PromptVersion
    let isActive: Bool
    let onRestore: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let store = CarbPromptStore.shared

    @State private var showRestoreConfirm = false
    @State private var copied = false
    /// Diff vs. the previous version, shown by default when one exists.
    /// UI-ONLY: the stored text, the Copy button, and what the AI receives are
    /// always the clean text — the diff never leaves this screen.
    @State private var showDiff = true

    private var fullText: String {
        version.fullText ?? store.text(of: version.id) ?? CarbPromptStore.defaultTemplate
    }

    /// Text of the version just before this one in the chain (nil for the base).
    private var previousText: String? {
        let chain = store.versions()
        guard let idx = chain.firstIndex(where: { $0.id == version.id }), idx > 0 else { return nil }
        return store.text(of: chain[idx - 1].id)
    }

    /// Code-style diff: unchanged prefix/suffix, the removed middle as red
    /// "shadow writing" (struck through), the added middle marked green.
    private func diffText(against previous: String) -> AttributedString {
        let delta = CarbPromptStore.delta(from: previous, to: fullText)
        let oldChars = Array(previous)
        let newChars = Array(fullText)

        var result = AttributedString(String(newChars[0..<delta.prefixCount]))

        let removedMiddle = String(oldChars[delta.prefixCount..<(oldChars.count - delta.suffixCount)])
        if !removedMiddle.isEmpty {
            var removed = AttributedString(removedMiddle)
            removed.foregroundColor = .red
            removed.strikethroughStyle = .single
            removed.backgroundColor = Color.red.opacity(0.14)
            result += removed
        }
        if !delta.replacement.isEmpty {
            var added = AttributedString(delta.replacement)
            added.backgroundColor = Color.green.opacity(0.2)
            result += added
        }
        result += AttributedString(String(newChars[(newChars.count - delta.suffixCount)...]))
        return result
    }

    var body: some View {
        ScrollView {
            Group {
                if showDiff, let previous = previousText, previous != fullText {
                    Text(diffText(against: previous))
                } else {
                    Text(fullText)
                }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color.loopScreenBackground.ignoresSafeArea())
        .navigationTitle(version.name)
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                        Text("Back", comment: "Back button in prompt preview")
                    }
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let previous = previousText, previous != fullText {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showDiff.toggle() }
                    } label: {
                        Image(systemName: showDiff ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(Text("Show or hide changes", comment: "Toggle diff highlighting in prompt preview"))
                }
                Button {
                    UIPasteboard.general.string = fullText   // always the clean text
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy", comment: "Copy prompt text"))
                if !isActive {
                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Text("Restore", comment: "Restore prompt version button")
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .alert(
            Text("Restore this version?", comment: "Restore prompt version alert title"),
            isPresented: $showRestoreConfirm
        ) {
            Button(NSLocalizedString("Restore", comment: "Restore")) {
                onRestore()
                dismiss()
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text("It will become the prompt that feeds the AI. Newer versions stay in the history.",
                 comment: "Restore prompt version alert body")
        }
    }
}
