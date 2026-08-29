//
//  FollowSettingsView.swift
//  Loop
//
//  Settings → Follow. The patient invites, names, and revokes followers here.
//  This is the ONLY place a follower connection can be created — there is no
//  follower-side "request access", because that would be an inbound message and
//  the feed is strictly one-way.
//
//  Read-only, one-way, and nothing here touches dosing.
//

import CloudKit
import SwiftUI
import UIKit

struct FollowSettingsView: View {
    @ObservedObject private var manager = FollowerShareManager.shared

    // The invite draft lives on the manager, not here — see the note beside
    // `draftName`. This view is re-initialised whenever the Settings list
    // re-renders, so any `@State` it owns is unreliable across a typing session.
    @State private var shareToPresent: CKShare?
    @State private var containerForShare: CKContainer?
    @State private var errorMessage: String?
    @State private var pendingRevoke: FollowerConnection?

    /// The label being edited, held here only while its alert is up. Safe as
    /// `@State` precisely because an alert is not torn down by the parent's
    /// republishing — see the note on `labelSection`.
    @State private var isEditingLabel = false
    @State private var labelDraft = ""

    /// The master switch from §15.2 rule 4. Mirrored into `@State` so the toggle
    /// animates; `HistoryLogger` remains the source of truth.
    @State private var isFeedEnabled = HistoryLogger.shared.isFollowerFeedEnabled

    @ObservedObject private var publisher = FollowerPublisher.shared

    var body: some View {
        List {
            explanationSection
            feedSection
            if isFeedEnabled {
                labelSection
                statusSection
            }
            followersSection
            addSection
        }
        .navigationTitle(Text("Follow", comment: "Title of the follower settings screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .task { await manager.refreshStatus() }
        .alert("Remove this follower?",
               isPresented: Binding(get: { pendingRevoke != nil },
                                    set: { if !$0 { pendingRevoke = nil } })) {
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
            Button("Remove", role: .destructive) {
                if let target = pendingRevoke {
                    Task { await manager.revoke(target); pendingRevoke = nil }
                }
            }
        } message: {
            Text("They will stop receiving your data. It can take a little while to take effect on their device.",
                 comment: "Revoke confirmation message")
        }
        .alert("Couldn't do that",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { shareToPresent != nil },
                                    set: { if !$0 { shareToPresent = nil } })) {
            if let share = shareToPresent, let container = containerForShare {
                CloudSharingView(share: share, container: container,
                                 onFailure: { message in
                                     // Surfaced through the same alert as every
                                     // other failure on this screen, so there is
                                     // exactly one place an invite can go wrong
                                     // and stay quiet about it: nowhere.
                                     shareToPresent = nil
                                     errorMessage = message
                                 },
                                 onDismiss: {
                                     Task { await manager.refreshStatus() }
                                 })
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Sections

    /// The one switch that turns the whole follower feed off (§15.2 rule 4:
    /// "so if anything about it ever looks wrong the fix is one toggle, not an
    /// emergency rebuild").
    ///
    /// It gates BOTH the status records and the publishing, at the source: with
    /// it off, `HistoryLogger.record(status:)` returns before doing anything, so
    /// nothing is written and nothing is sent.
    ///
    /// ⚠️ Defaults OFF, and the app must work perfectly with it off — that is
    /// the normal state for most of this feature's life (§15.2 rule 5).
    private var feedSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isFeedEnabled },
                set: {
                    isFeedEnabled = $0
                    HistoryLogger.shared.isFollowerFeedEnabled = $0
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share My Loop", comment: "Toggle enabling the follower feed")
                    if !HistoryLogger.shared.isEnabled {
                        // The feed reads from the history log, so the log has to
                        // be on too. Saying so beats a toggle that silently does
                        // nothing.
                        Text("Turn on History Log first — the feed is built from it.",
                             comment: "Warning when the history log is off")
                            .font(.footnote)
                            .foregroundColor(.critical)
                    }
                }
            }
        } footer: {
            Text("When this is off, nothing is recorded for followers and nothing is sent. Your loop runs exactly the same either way.",
                 comment: "Footer for the follower feed toggle")
        }
    }

    /// §14.4 — what the follower's app calls you.
    ///
    /// Was being read by the publisher and never set by anything, so every
    /// follower would have shown the neutral fallback "Loop".
    ///
    /// ⚠️ Deliberately NOT defaulted from the Apple ID name or the device name.
    /// This string lands on someone else's phone; the patient chooses what it
    /// says about them. Blank is a valid answer.
    ///
    /// Held on the manager, not in `@State` — same reason as the invite draft.
    /// 🐛 SAME DISEASE AS THE FOLLOWER NAME FIELD, AND THE EVIDENCE WAS SITTING
    /// IN THE UI: this field contained a lone "H" — the first letter of a name
    /// somebody typed before the parent list republished and took the keyboard
    /// away. An inline `TextField` on this screen cannot hold focus, because the
    /// Settings list re-initialises this view every loop cycle.
    ///
    /// So it is a row that opens an alert, like the invite. Tapping it is one
    /// extra step; being able to type more than one character is worth it.
    private var labelSection: some View {
        Section {
            Button {
                labelDraft = manager.patientLabel
                isEditingLabel = true
            } label: {
                HStack {
                    Text(manager.patientLabel.isEmpty
                         ? NSLocalizedString("e.g. Uri's Loop", comment: "Patient display label placeholder")
                         : manager.patientLabel)
                        .foregroundStyle(manager.patientLabel.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alert(Text("What they'll see", comment: "Patient label alert title"),
                   isPresented: $isEditingLabel) {
                TextField(NSLocalizedString("e.g. Uri's Loop", comment: "Patient display label placeholder"),
                          text: $labelDraft)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { }
                Button(NSLocalizedString("Save", comment: "Save the patient label")) {
                    manager.patientLabel = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } message: {
                Text("Shown at the top of your followers' screens. Leave it blank and they'll just see \"Loop\".",
                     comment: "Patient label alert message")
            }
        } header: {
            Text("What they'll see", comment: "Patient label section header")
        } footer: {
            Text("The name shown at the top of your followers' screens. Leave it blank and they'll just see \"Loop\".",
                 comment: "Patient label footer")
        }
    }

    /// Whether publishing is actually working.
    ///
    /// Without this the feature is a black box: publishing happens on a
    /// background queue and swallows its own errors, so the only way to tell
    /// whether anything left the phone was to read the console. That is no use
    /// when you are standing next to the second phone wondering why it is empty.
    private var statusSection: some View {
        Section {
            HStack {
                Text("Last sent", comment: "Publish status row")
                Spacer()
                if let at = publisher.lastPublishedAt {
                    Text(at, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text("Never", comment: "Never published").foregroundStyle(.secondary)
                }
            }
            if let bytes = publisher.lastPayloadBytes {
                HStack {
                    Text("Size", comment: "Publish size row")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
            if let error = publisher.lastPublishError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.critical)
            }
            Button {
                // Forced: the automatic path is rate-limited to one publish
                // every four minutes, which is right for normal running and
                // maddening when you are testing.
                FollowerPublisher.shared.publish(force: true)
            } label: {
                HStack {
                    Text(publisher.isPublishing
                         ? NSLocalizedString("Sending…", comment: "Publish in progress")
                         : NSLocalizedString("Send Now", comment: "Manual publish button"))
                    if publisher.isPublishing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(publisher.isPublishing || !isFeedEnabled)
        } header: {
            Text("Sending", comment: "Publish status section header")
        } footer: {
            // ⚠️ CONCRETE NUMBERS. "Every few minutes" left the honest question
            // "so how long until they see this?" unanswerable, which is how a
            // working feature still feels broken.
            Text("Your Loop sends an update after a loop cycle, at most once every 4 minutes. Their app re-reads every 5 minutes while it is open, so an update normally appears within about 5 minutes and at worst about 9. Send Now and their own refresh both skip the wait. Nothing is sent while Share My Loop is off.",
                 comment: "Publish status footer")
        }
    }

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Followers can see your Loop, and can change nothing.",
                     comment: "Follow feature explanation headline")
                    .font(.subheadline.weight(.semibold))
                Text("They see your glucose, insulin and settings, exactly as you see them. They cannot enter carbs, bolus, change your settings, or send anything back to this phone. The only thing they control is their own alerts.",
                     comment: "Follow feature explanation body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var followersSection: some View {
        Section(header: Text("Followers", comment: "Follower list section header")) {
            if manager.connections.isEmpty {
                Text("Nobody is following you.", comment: "Empty follower list")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.connections) { connection in
                    row(for: connection)
                }
            }
        }
    }

    private func row(for connection: FollowerConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.body)
                HStack(spacing: 6) {
                    statusDot(for: connection.status)
                    Text(statusText(for: connection.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if connection.status == .removed {
                Button("Forget") { manager.forget(connection) }
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else {
                Button("Remove", role: .destructive) { pendingRevoke = connection }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func statusDot(for status: FollowerConnection.Status) -> some View {
        Circle()
            .fill(status == .active ? Color.green : (status == .invited ? Color.orange : Color.secondary))
            .frame(width: 7, height: 7)
    }

    private func statusText(for status: FollowerConnection.Status) -> String {
        switch status {
        case .invited: return NSLocalizedString("Invited — waiting for them to accept",
                                                comment: "Follower status: invited")
        case .active:  return NSLocalizedString("Connected", comment: "Follower status: active")
        case .removed: return NSLocalizedString("Removed", comment: "Follower status: removed")
        }
    }

    /// 🐛 THE NAME FIELD USED TO LIVE IN THIS SECTION, AND IT COULD NOT BE TYPED
    /// INTO AT ALL. This screen is a `NavigationLink` destination inside the
    /// Settings list, and that list republishes constantly — every loop cycle,
    /// every device update. SwiftUI re-initialises the destination each time, so
    /// the inline `TextField` was destroyed and rebuilt within a second of being
    /// tapped: FOCUS CANNOT SURVIVE THAT, however carefully the value is stored.
    ///
    /// The draft was already moved onto the singleton so the VALUE survived (see
    /// `draftName`), and that fix was real but incomplete — a field that keeps
    /// its text and loses the keyboard is still a field you cannot type in. The
    /// symptom was "Create Invitation" staying greyed out forever and the button
    /// doing nothing, because the name never got past one character. The
    /// patient-label field above shows the same fingerprint: a lone "H".
    ///
    /// ⚠️ AN ALERT, NOT AN INLINE ROW, AND THAT IS THE FIX. A presented alert is
    /// not re-initialised when the parent list republishes, so its text field
    /// keeps focus. Do not move this back inline to tidy the layout up.
    private var addSection: some View {
        Section(footer: footerText) {
            Button {
                manager.isNamingFollower = true
            } label: {
                Label(NSLocalizedString("Add Follower", comment: "Add follower button"),
                      systemImage: "person.badge.plus")
            }
            .disabled(!manager.canAddFollower || manager.isBusy)
            // ⚠️ ATTACHED HERE, NOT TO THE LIST, AND THAT IS NOT A STYLE CHOICE.
            // The list already carries two `.alert` modifiers (revoke, and the
            // failure alert). SwiftUI honours ONE alert per view: a third simply
            // never presents, silently — tapping Add Follower did nothing at all,
            // which is the same symptom this whole fix set out to remove. Hanging
            // it off the button gives it its own view to be presented from.
            .alert(Text("Invite a follower", comment: "Naming alert title"),
                   isPresented: $manager.isNamingFollower) {
                TextField(NSLocalizedString("Their name, e.g. Mum", comment: "Follower name field placeholder"),
                          text: $manager.draftName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { manager.clearDraft() }
                Button(NSLocalizedString("Create Invitation", comment: "Create invitation button")) { invite() }
            } message: {
                Text("Give them a name so you can tell your followers apart later. It is stored on this phone only and never sent to them.",
                     comment: "Naming alert message")
            }
        }
    }

    private var footerText: some View {
        // The limit and the one-way promise are both stated where the action is,
        // not buried in a help screen.
        Text("Up to 3 followers. You invite them from here — they can never request access themselves, and nothing they do can reach this phone.",
             comment: "Follow settings footer")
    }

    /// Trimmed the same way `makeShare` trims it, so the button's enabled state
    /// and the manager's validation can never disagree. They used to: the button
    /// trimmed `.whitespaces` and the manager trimmed `.whitespacesAndNewlines`,
    /// so a name of only a newline enabled the button and then failed.
    private var trimmedDraftName: String {
        manager.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func invite() {
        let name = trimmedDraftName
        // Belt and braces. The button is disabled when this is empty, but if it
        // ever is, do NOT call through and surface "give this follower a name" —
        // that message is only honest when the field is genuinely empty, and it
        // was the symptom of the draft being wiped out from under the user.
        guard !name.isEmpty else {
            // Reopening the alert in silence looks exactly like the bug this
            // screen just had. Say what is missing.
            errorMessage = NSLocalizedString("Give this follower a name first — it is how you tell them apart when you come back to revoke one.",
                                             comment: "Empty follower name")
            return
        }
        Task {
            do {
                let (share, container) = try await manager.makeShare(forFollowerNamed: name)
                containerForShare = container
                shareToPresent = share
                manager.clearDraft()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Thin wrapper over `UICloudSharingController` — Apple's own invite UI.
///
/// Used rather than a hand-rolled invite flow because it already handles the
/// permission model correctly. Permission is pinned to READ-ONLY here: this is
/// CloudKit's own enforcement of the one-way rule, underneath the app-level
/// guarantee that the follower app links no writing code at all.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onFailure: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // ⚠️ Read-only, and no public link. Do not relax either.
        controller.availablePermissions = [.allowReadOnly, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let onFailure: (String) -> Void
        private let onDismiss: () -> Void
        init(onFailure: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
            self.onFailure = onFailure
            self.onDismiss = onDismiss
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            // Deliberately not the patient's name — this string shows up in share
            // sheets, messages and screenshots.
            NSLocalizedString("Loop Follower Feed", comment: "Share sheet item title")
        }

        /// 🐛 THIS USED TO CALL `onDismiss()` AND NOTHING ELSE — the invite sheet
        /// simply closed and the screen went back to how it was. Every reason an
        /// invite can fail (no iCloud account on the device, iCloud Drive off,
        /// the container not enabled on this App ID, no network) landed here and
        /// produced the same silent nothing, which is indistinguishable from the
        /// button not working. "It doesn't share a link" is exactly what that
        /// looks like from the outside.
        ///
        /// ⚠️ Never swallow this again. A pairing flow that fails quietly is a
        /// pairing flow nobody can debug — not the user, and not us.
        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            onFailure(Self.explain(error))
        }

        /// CloudKit's own messages are accurate and useless ("Couldn't Save
        /// Record"). The common causes each have a specific thing the user has to
        /// go and do, so say that instead.
        private static func explain(_ error: Error) -> String {
            let fallback = error.localizedDescription
            guard let ckError = error as? CKError else { return fallback }
            switch ckError.code {
            case .notAuthenticated:
                return NSLocalizedString("This iPhone is not signed in to iCloud. Sign in under Settings → your name → iCloud, then try again.",
                                         comment: "Share failure: not signed in")
            case .networkUnavailable, .networkFailure:
                return NSLocalizedString("No connection to iCloud right now. The invite needs the network once, to create the link.",
                                         comment: "Share failure: offline")
            case .quotaExceeded:
                return NSLocalizedString("This iCloud account is out of storage, so the shared feed cannot be created.",
                                         comment: "Share failure: quota")
            case .permissionFailure, .badContainer, .missingEntitlement:
                return NSLocalizedString("This build cannot reach its iCloud container. The Follow feature needs the iCloud capability on the app's App ID, which a free Apple ID cannot grant.",
                                         comment: "Share failure: entitlement")
            case .managedAccountRestricted:
                return NSLocalizedString("This Apple Account is managed and is not allowed to share iCloud data.",
                                         comment: "Share failure: managed account")
            default:
                return String(format: NSLocalizedString("iCloud refused to create the invite: %@", comment: "Share failure: other"),
                              fallback)
            }
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onDismiss()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss()
        }
    }
}
