import HermesServeKit
import SwiftUI

/// Backend list + editor. Flat rows on the canvas, group headers in caption, one hairline per group boundary.
@MainActor
struct ConnectionSettingsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @State private var editing: BackendProfile?
    @State private var isAdding = false
    @State private var actionTarget: BackendProfile?
    @State private var confirmingSignOut = false
    @State private var confirmingRemove = false

    var body: some View {
        // No inner NavigationStack, no Done button; the stack's back gesture is the exit.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                backendsGroup
                if let status = app.serverStatus {
                    connectedGroup(status)
                }
                demoGroup
                diagnosticsGroup
                actionsGroup
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Backend")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .sheet(item: $editing) { profile in
            ProfileEditorView(profile: profile)
        }
        .sheet(isPresented: $isAdding) {
            ProfileEditorView(profile: BackendProfile())
        }
        .sheet(item: $actionTarget) { profile in
            profileActions(profile)
        }
        .confirmationDialog(
            "Sign out of \(app.activeProfile?.displayName ?? "this backend")?",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address and the name stay on this device. The stored credential does not, and you will be asked for it again.")
        }
        .confirmationDialog(
            "Remove \(app.activeProfile?.displayName ?? "this backend")?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove backend", role: .destructive) {
                guard let id = app.activeProfile?.id else { return }
                app.deleteProfile(id: id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This forgets the backend and its stored credential on this device. Nothing on the backend itself changes.")
        }
        #if DEBUG
        // FEAT-030 capture harness: -hermesScreenshotRoute backend-editor opens the editor on this screen.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-hermesScreenshotRoute"),
                  ProcessInfo.processInfo.arguments.contains("backend-editor")
            else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            isAdding = true
        }
        #endif
    }

    // MARK: Backends

    private var backendsGroup: some View {
        SettingsGroup(
            title: "Backends",
            // One definition, two screens (FEAT-003): Home's first-run state says the same sentence.
            footer: AppModel.backendExplainer
        ) {
            ForEach(app.profiles) { profile in
                Button {
                    editing = profile
                } label: {
                    ProfileRow(profile: profile, isActive: profile.id == app.signedInProfile?.id)
                }
                .buttonStyle(.plain)
                .onLongPressGesture(minimumDuration: 0.4) {
                    HapticFeedback.selection()
                    actionTarget = profile
                }
            }
            Button {
                isAdding = true
            } label: {
                FlatRow(showsHairline: false) {
                    Label("Add a backend", systemImage: "plus")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.action)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Demo (FEAT-020)

    /// Offered whether or not a backend exists — it is also how the App Store captures are produced.
    private var demoGroup: some View {
        SettingsGroup(title: "Demo", footer: AppModel.demoInvitation) {
            Button {
                Task { await app.enterDemo() }
            } label: {
                FlatRow(showsHairline: false) {
                    Label("Try the demo", systemImage: "play.rectangle")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.action)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .disabled(app.isDemoActive)
            .accessibilityIdentifier("demo.enter.settings")
        }
    }

    // MARK: Diagnostics

    private var diagnosticsGroup: some View {
        SettingsGroup(
            title: "Diagnostics",
            footer: "The connection's state, what the backend supports, and a log of recent requests with secrets removed."
        ) {
            NavigationLink(value: AppRoute.settingsDiagnostics) {
                FlatRow(showsHairline: false) {
                    Text("Diagnostics")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                } trailing: {
                    HStack(spacing: Space.s2) {
                        Text(diagnosticsValue)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text3)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.text4)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var diagnosticsValue: String {
        if app.isDemoActive { return "Demo" }
        if let status = app.serverStatus, !status.version.isEmpty { return "v\(status.version)" }
        return app.connectionState.isOpen ? "Connected" : "Not connected"
    }

    // MARK: Connected backend

    private func connectedGroup(_ status: ServerStatus) -> some View {
        SettingsGroup(title: "Connected backend") {
            infoRow("Version", app.isDemoActive ? "Demo" : status.version)
            infoRow("Gateway", status.gatewayState.isEmpty ? "unknown" : status.gatewayState)
            infoRow("Health", status.overall.isEmpty ? "unknown" : status.overall)
            infoRow("Sign-in", status.authRequired ? "Required" : "Not required")
            infoRow("Active sessions", "\(status.activeSessions)")
            if let identity = app.identity {
                infoRow("Signed in as", identity.bestName)
            }
        }
    }

    // MARK: Sign out / Remove (FEAT-030 §4, BUG-119)

    /// The two departures, said in the words that distinguish them.
    private var actionsGroup: some View {
        SettingsGroup(
            footer: "Credentials are stored only in this iPhone's Keychain. Signing out deletes them here; a token already issued stops working when it expires, because the backend cannot cancel one early."
        ) {
            Button {
                confirmingSignOut = true
            } label: {
                FlatRow {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text("Sign out")
                            .font(HermesFont.callout)
                            .foregroundStyle(canSignOut ? t.danger : t.danger.opacity(0.4))
                        Text("Forgets the credential. Keeps the address.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSignOut)
            .accessibilityIdentifier("backend.signout")

            Button {
                confirmingRemove = true
            } label: {
                FlatRow(showsHairline: false) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text("Remove backend")
                            .font(HermesFont.callout)
                            .foregroundStyle(canRemove ? t.danger : t.danger.opacity(0.4))
                        Text("Forgets the backend and its credential entirely.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityIdentifier("backend.remove")
        }
    }

    /// Gated on a signed-in backend rather than on `app.auth != nil`: `auth` is nil for the whole length of the demo.
    private var canSignOut: Bool { app.signedInProfile != nil }

    private var canRemove: Bool { app.activeProfile != nil }

    // MARK: Long-press actions — the swipe replacement

    private func profileActions(_ profile: BackendProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(profile.displayName)
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
                .lineLimit(1)
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s6)
                .padding(.bottom, Space.s5)

            Button {
                actionTarget = nil
                editing = profile
            } label: {
                FlatRow {
                    Text("Edit").font(HermesFont.callout).foregroundStyle(t.text1)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Space.s4) {
                HoldToConfirmButton("Hold to delete") {
                    let target = profile
                    actionTarget = nil
                    app.deleteProfile(id: target.id)
                }
                Text("This removes the backend and its stored credentials from this device.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            .padding(Space.s6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        FlatRow(showsHairline: false) {
            Text(label).font(HermesFont.callout).foregroundStyle(t.text2)
        } trailing: {
            Text(value)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - A flat settings group

/// Header in caption, flat content on the canvas, one hairline on the bottom boundary.
@MainActor
struct SettingsGroup<Content: View>: View {
    @Environment(\.hermes) private var t
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .hermesCaption()
                    .foregroundStyle(t.text3)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s8)
                    .padding(.bottom, Space.s3)
            }
            content()
            if let footer {
                Text(.init(footer))
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s3)
                    .padding(.bottom, Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(height: Space.s5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline()
    }
}

@MainActor
private struct ProfileRow: View {
    @Environment(\.hermes) private var t
    let profile: BackendProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(profile.displayName)
                    .font(isActive ? HermesFont.calloutStrong : HermesFont.callout)
                    .foregroundStyle(t.text1)
                Text(profile.baseURLString.isEmpty ? "No address" : profile.baseURLString)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Space.s3) {
                    // A signed-out backend says so; the method it used is one tap away in the editor.
                    Text(profile.signedOut ? "Signed out" : BackendAuthMethod.from(profile.authMode).title)
                        .font(HermesFont.footnote)
                        .foregroundStyle(profile.signedOut ? t.warn : t.text3)
                    if !profile.lastKnownVersion.isEmpty {
                        Text("v\(profile.lastKnownVersion)")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                    }
                }
            }
            Spacer(minLength: Space.s4)
            if isActive {
                Circle().fill(t.ok).frame(width: 8, height: 8)
                    .accessibilityLabel("Active")
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(minHeight: Hit.commit)
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

/// Add / edit one backend: the address probes as you type, 600 ms after the last keystroke, against the public `GET /api/status`.
@MainActor
struct ProfileEditorView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var profile: BackendProfile
    @State private var sessionToken = ""
    @State private var bearerToken = ""
    @State private var password = ""

    @State private var probe: BackendProbeState = .idle
    @State private var testResult: TestResult?
    /// The failure of Save's own password login, shown under the password field.
    @State private var credentialError: String?
    /// Whether the method on screen is a choice rather than a suggestion; a probe pre-fills the method only while this is false, and it starts true when editing a saved profile.
    @State private var userChoseAuthMode: Bool
    /// The address the debounced task last saw, so an edit can be told from the task's own first run at appear time.
    @State private var lastProbedAddress: String?
    /// Whether the Keychain already holds this method's secret, loaded rather than read inline because the Keychain lives behind an actor.
    @State private var hasStoredCredential = false

    private let isNew: Bool

    init(profile: BackendProfile) {
        _profile = State(initialValue: profile)
        let isNew = profile.baseURLString.isEmpty
        self.isNew = isNew
        _userChoseAuthMode = State(initialValue: !isNew)
    }

    private enum TestResult: Equatable {
        case running
        case success(String)
        case failure(String)
    }

    // MARK: Derived

    private var method: BackendAuthMethod {
        BackendAuthMethod.from(profile.authMode)
    }

    private var methodBinding: Binding<BackendAuthMethod> {
        Binding(
            get: { method },
            set: { picked in
                guard picked != method else { return }
                profile.authMode = picked.authMode
                userChoseAuthMode = true
                credentialError = nil
                Task { await refreshStoredCredential() }
            }
        )
    }

    private var typedCredential: String {
        switch method {
        case .password: return password
        case .bearer: return bearerToken
        case .sessionToken: return sessionToken
        case .none: return ""
        }
    }

    private var saveDecision: BackendSaveDecision {
        BackendSaveDecision.decide(
            addressParses: profile.isUsable,
            method: method,
            typedCredential: typedCredential,
            hasStoredCredential: hasStoredCredential
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    addressGroup
                    authGroup
                    hermesProfileGroup
                    saveGroup
                    testGroup
                }
                .padding(.bottom, Space.s10)
            }
            .background(t.canvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "Add backend" : "Edit backend")
            .navigationBarTitleDisplayMode(.inline)
            .hermesTopBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(t.text2)
                }
            }
        }
        // `.task(id:)` cancels the running task the instant the id changes, so the next keystroke kills both the sleep and any probe in flight.
        .task(id: profile.baseURLString) {
            let address = profile.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only an edit clears the latch: this task also runs once at appear time, where clearing it would let the probe overwrite a saved method.
            if lastProbedAddress != nil { userChoseAuthMode = false }
            lastProbedAddress = address
            guard !address.isEmpty else {
                probe = .idle
                return
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await detect()
        }
        .task { await refreshStoredCredential() }
        #if DEBUG
        // FEAT-030 capture harness: `-hermesSeedEditorAddress <addr>` fills the address so the probe's states can be photographed.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-hermesSeedEditorAddress"),
                  index + 1 < arguments.count
            else { return }
            profile.baseURLString = arguments[index + 1]
        }
        #endif
    }

    // MARK: Groups

    private var addressGroup: some View {
        SettingsGroup(title: "Backend address") {
            field {
                TextField(text: $profile.baseURLString, prompt: Text(verbatim: BackendEditorCopy.addressPlaceholder)) {
                    Text("Address")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("backend.address")
                .onSubmit { Task { await detect() } }
            }
            if probe.statusLine == nil {
                helpText(BackendEditorCopy.addressHelp)
            }
            probeStatusLine
            field {
                TextField(namePlaceholder, text: $profile.name)
                    .accessibilityIdentifier("backend.name")
            }
        }
    }

    /// The name field's placeholder is the host once one is known, since the name is genuinely optional.
    private var namePlaceholder: String {
        if let configuration = try? profile.makeConfiguration(), !configuration.displayHost.isEmpty {
            return configuration.displayHost
        }
        return "Name (optional)"
    }

    /// One line under the address, in all four states, tappable to probe again.
    @ViewBuilder
    private var probeStatusLine: some View {
        if let line = probe.statusLine {
            Button {
                Task { await detect() }
            } label: {
                // `.top` because a spinner has no text baseline to sit on and the not-found line often runs to two lines.
                HStack(alignment: .top, spacing: Space.s3) {
                    if probe.isProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: probe.didFind ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(HermesFont.footnote)
                            .foregroundStyle(probe.didFind ? t.ok : t.warn)
                            .padding(.top, 1)
                    }
                    Text(line)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(probe.isProbing)
            .accessibilityIdentifier("backend.probe.status")
            .accessibilityHint("Checks this address again")
        }
    }

    private var authGroup: some View {
        SettingsGroup(title: "Authentication") {
            FlatRow(showsHairline: false) {
                Text("Method")
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text2)
                    .lineLimit(1)
                    // BUG-118: the value may not wrap or compress, so the label is the part that yields — that is what the lower layout priority says.
                    .layoutPriority(0)
                    .minimumScaleFactor(0.8)
            } trailing: {
                Picker("", selection: methodBinding) {
                    ForEach(BackendAuthMethod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(t.action)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityIdentifier("backend.method")
                .accessibilityLabel("Authentication method")
            }
            credentialFields
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch method {
        case .sessionToken:
            field {
                secure(hasStoredCredential ? "Session token (stored)" : "Session token", text: $sessionToken)
                    .accessibilityIdentifier("backend.credential")
            }
            if let credentialError {
                errorText(credentialError)
            }
            helpText(BackendEditorCopy.sessionTokenHelp)

        case .bearer:
            field {
                secure(hasStoredCredential ? "Access token (stored)" : "Access token", text: $bearerToken)
                    .accessibilityIdentifier("backend.credential")
            }
            if let credentialError {
                errorText(credentialError)
            }
            helpText(BackendEditorCopy.accessTokenHelp)

        case .password:
            field {
                TextField("Provider (optional)", text: $profile.providerName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field {
                TextField("Username", text: $profile.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field {
                SecureField(hasStoredCredential ? "Password (stored)" : "Password", text: $password)
                    .accessibilityIdentifier("backend.credential")
            }
            if let credentialError {
                errorText(credentialError)
            }
            helpText(BackendEditorCopy.passwordHelp)

        case .none:
            helpText(BackendEditorCopy.noneHelp)
        }
    }

    private var hermesProfileGroup: some View {
        SettingsGroup(
            title: "Hermes profile",
            footer: BackendEditorCopy.profileFooter
        ) {
            field {
                TextField("Hermes profile (optional)", text: $profile.hermesProfile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    /// Save, and the sentence that answers "must I test first".
    private var saveGroup: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: Space.s3) {
                Button("Save") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!saveDecision.isEnabled)
                    .accessibilityIdentifier("backend.save")
                if let reason = saveDecision.reason {
                    Text(reason)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(BackendSaveDecision.caption)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s4)
        }
    }

    private var testGroup: some View {
        SettingsGroup(
            footer: BackendEditorCopy.testFooter
        ) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: Space.s3) {
                        Text("Test connection")
                        if testResult == .running {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: Hit.commit))
                .disabled(!profile.isUsable || testResult == .running)
                .accessibilityIdentifier("backend.test")
                testResultView
            }
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s4)
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testResult {
        case .none, .some(.running):
            EmptyView()
        case .some(.success(let message)):
            noteRow(message, tint: t.ok, icon: "checkmark.circle.fill")
        case .some(.failure(let message)):
            noteRow(message, tint: t.danger, icon: "xmark.octagon.fill")
        }
    }

    // MARK: Building blocks

    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(HermesFont.body)
            .foregroundStyle(t.text1)
            .padding(Space.s5)
            .frame(minHeight: Hit.min)
            .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s4)
    }

    private func secure(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func helpText(_ text: String) -> some View {
        Text(.init(text))
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(HermesFont.footnote)
            .foregroundStyle(t.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("backend.credential.error")
    }

    private func noteRow(_ message: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Image(systemName: icon).foregroundStyle(tint).padding(.top, 1)
            Text(message)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text2)
        }
        .padding(.bottom, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("backend.test.result")
    }

    // MARK: Actions

    /// Probe the public `/api/status` and pick the auth mode from `auth_required` — the exact rule the desktop uses (`authModeFromStatus`, reference §2.3).
    @MainActor
    private func detect() async {
        guard let configuration = try? profile.makeConfiguration() else {
            probe = .notFound(reason: "that address is not a valid http(s) URL")
            return
        }
        probe = .probing
        let auth = AuthenticationClient(configuration: configuration, profileID: profile.id.uuidString)
        let rest = RestAPI(auth: auth)
        do {
            let status = try await rest.getStatus()
            guard !Task.isCancelled else { return }
            probe = .found(version: status.version, authRequired: status.authRequired)
            profile.lastKnownVersion = status.version
            if !userChoseAuthMode {
                profile.authMode = status.suggestedAuthMode
                await refreshStoredCredential()
            }
            // `/auth/password-login` rejects a blank `provider` with 422, so adopt the only one advertised.
            if profile.providerName.isEmpty, status.authProviders.count == 1 {
                profile.providerName = status.authProviders[0]
            }
        } catch {
            guard !Task.isCancelled else { return }
            probe = .notFound(reason: BackendProbeReason.short(for: error))
        }
    }

    /// Full round trip: status → credential → WebSocket → `gateway.ready`.
    @MainActor
    private func test() async {
        guard let configuration = try? profile.makeConfiguration() else { return }
        testResult = .running
        // Testing is not saving: this client writes no credential back, so `save()` is the only thing that persists.
        let auth = AuthenticationClient(
            configuration: configuration,
            profileID: profile.id.uuidString,
            persistsSecrets: false
        )
        do {
            try await storeCredentials(into: auth, configuration: configuration)
            let rest = RestAPI(auth: auth)
            let status = try await rest.getStatus()
            let client = HermesClient(auth: auth, rest: rest, log: app.log)
            try await client.connect()
            let identity = try? await auth.identity()
            await client.disconnect()
            if let identity, !identity.bestName.isEmpty {
                testResult = .success("Connected as \(identity.bestName) · Hermes \(status.version)")
            } else {
                testResult = .success("Connected · Hermes \(status.version)")
            }
        } catch {
            testResult = .failure(BackendProbeReason.short(for: error))
        }
    }

    @MainActor
    private func save() async {
        guard let configuration = try? profile.makeConfiguration() else { return }
        credentialError = nil
        // Bound to this profile id so the Keychain namespacing stays correct even when another backend is active.
        let target = AuthenticationClient(configuration: configuration, profileID: profile.id.uuidString)
        let credentialsChanged: Bool
        do {
            credentialsChanged = try await storeCredentials(into: target, configuration: configuration)
        } catch {
            credentialError = BackendProbeReason.short(for: error)
            return
        }

        // Signed in again whether or not a secret was just written: `BackendSaveDecision` enables Save only with a typed credential, a stored one, or a method that needs none, and sign-out erases every stored secret, so a signed-out profile reaches this line only with a fresh credential or with no credential to need (BUG-146).
        profile.signedOut = false

        if app.profiles.contains(where: { $0.id == profile.id }) {
            app.update(profile, credentialsChanged: credentialsChanged)
            // BUG-119: sign-out clears the active id, so `update` alone would connect nothing — and only when nothing else is active, so saving a second backend does not switch onto it.
            if app.activeProfileID == nil {
                await app.activate(profileID: profile.id, connect: true)
            }
        } else {
            app.addProfile(profile)
            await app.activate(profileID: profile.id, connect: true)
        }
        dismiss()
    }

    /// Whether this method's secret is already in the Keychain for this profile.
    @MainActor
    private func refreshStoredCredential() async {
        guard !isNew,
              app.profiles.contains(where: { $0.id == profile.id }),
              let configuration = try? profile.makeConfiguration()
        else {
            hasStoredCredential = false
            return
        }
        let auth = AuthenticationClient(
            configuration: configuration,
            profileID: profile.id.uuidString,
            persistsSecrets: false
        )
        switch method {
        case .password: hasStoredCredential = await auth.hasSecret(.password)
        case .bearer: hasStoredCredential = await auth.hasSecret(.bearerToken)
        case .sessionToken: hasStoredCredential = await auth.hasSecret(.sessionToken)
        case .none: hasStoredCredential = true
        }
    }

    /// Returns whether a secret was actually written: a credential edit is invisible to any comparison of the profile rows, and it is the one edit that must rebuild the connection (BUG-025).
    @discardableResult
    @MainActor
    private func storeCredentials(
        into auth: AuthenticationClient,
        configuration: BackendConfiguration
    ) async throws -> Bool {
        switch method {
        case .sessionToken:
            guard let token = BackendCredentialInput.secretToStore(sessionToken, for: .sessionToken) else { return false }
            try await auth.setSecret(token, kind: .sessionToken)
            return true
        case .bearer:
            guard let token = BackendCredentialInput.secretToStore(bearerToken, for: .bearer) else { return false }
            try await auth.setSecret(token, kind: .bearerToken)
            return true
        case .password:
            // `await` cannot appear inside `||`'s autoclosed right operand.
            let hasStoredPassword = await auth.hasSecret(.password)
            guard !password.isEmpty || hasStoredPassword else {
                throw HermesError.missingCredential("Enter the password for \(profile.username).")
            }
            guard !password.isEmpty else { return false }
            try await auth.passwordLogin(
                provider: profile.providerName,
                username: profile.username,
                password: password
            )
            return true
        case .none:
            return false
        }
    }
}
