import SrokaCore
import SrokaDesign
import SwiftUI

/// The settings sheet (Android `SettingsScreen`). The app root presents it as a sheet, owns the view
/// model and reacts to `SettingsIntent`.
public struct SettingsView: View {
    @Bindable var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            Form {
                ReadingSection(model: model)
                SwipeSection(model: model)
                LibrarySection(model: model)
                PrivacySection(model: model)
                AccountSection(model: model)
            }
            .scrollContentBackground(.hidden)
            .background(SrokaColor.background)
            .navigationTitle(Text("Settings", bundle: #bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.doneTapped() }
                    } label: {
                        Text("Done", bundle: #bundle)
                    }
                    .accessibilityIdentifier("settings.doneButton")
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .server:
                    ServerSettingsView(
                        model: ServerSettingsViewModel(currentServer: model.serverURL) { outcome in
                            switch outcome {
                            case .saved: model.path.removeAll()
                            case .switched: await model.serverSwitched()
                            }
                        })
                case .export: ExportView()
                case .import: ImportView()
                }
            }
        }
        .tint(SrokaColor.brand)
        .overlay(alignment: .bottom) { MessageToast(message: model.message) }
        .animation(.default, value: model.message != nil)
        .disabled(model.isBusy)
        .task { await model.task() }
        .confirmationDialog(
            Text("Sign out", bundle: #bundle),
            isPresented: $model.isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.signOutConfirmed() }
            } label: {
                Text("Sign out", bundle: #bundle)
            }
        } message: {
            Text(
                "Signing out removes your saved articles and downloads from this device. They stay in your account and come back when you sign in again. Changes not yet synced will be lost.",
                bundle: #bundle
            )
        }
        .confirmationDialog(
            Text("Remove downloaded articles", bundle: #bundle),
            isPresented: $model.isConfirmingRemoveDownloads,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.removeDownloadsConfirmed() }
            } label: {
                Text("Remove", bundle: #bundle)
            }
        } message: {
            Text(
                "Articles stay in your list but will need to be downloaded again to read offline.",
                bundle: #bundle
            )
        }
        .alert(
            Text("Delete your account?", bundle: #bundle),
            isPresented: $model.isConfirmingDeleteAccount
        ) {
            TextField(text: $model.deleteConfirmationText) {
                Text("Type your email to confirm", bundle: #bundle)
            }
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button(role: .destructive) {
                Task { await model.deleteAccountConfirmed() }
            } label: {
                Text("Delete", bundle: #bundle)
            }
            .disabled(!model.isDeleteConfirmed)
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: #bundle)
            }
        } message: {
            Text(
                "This permanently deletes your library, tags and reading progress on every device. Export first if you want a copy.",
                bundle: #bundle
            )
        }
        .sensoryFeedback(.warning, trigger: model.isConfirmingDeleteAccount) { _, isOn in isOn }
        .sensoryFeedback(.warning, trigger: model.isConfirmingSignOut) { _, isOn in isOn }
    }
}

// MARK: - Sections

private struct ReadingSection: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Section {
            Picker(selection: themeBinding) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Label {
                    Text("Theme", bundle: #bundle)
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                }
            }
            .pickerStyle(.menu)
            Picker(selection: readerThemeBinding) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Text(theme.title).tag(theme)
                }
            } label: {
                Label {
                    Text("Reader theme", bundle: #bundle)
                } icon: {
                    Image(systemName: "book")
                }
            }
            .pickerStyle(.menu)
            Picker(
                selection: Binding(
                    get: { model.nearestTextScaleStep },
                    set: { value in Task { await model.textScaleSelected(value) } }
                )
            ) {
                ForEach(SettingsViewModel.textScaleSteps, id: \.self) { step in
                    Text(textSizeTitle(step)).tag(step)
                }
            } label: {
                Label {
                    Text("Text size", bundle: #bundle)
                } icon: {
                    Image(systemName: "textformat.size")
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Reading", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }

    private func textSizeTitle(_ step: Double) -> LocalizedStringResource {
        let points = SettingsViewModel.textPoints(scale: step)
        if step == 1.0 {
            return LocalizedStringResource("Default · \(points) pt", bundle: #bundle)
        }
        return LocalizedStringResource("\(points) pt", bundle: #bundle)
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(
            get: { model.preferences.themeMode },
            set: { value in Task { await model.themeSelected(value) } }
        )
    }

    private var readerThemeBinding: Binding<ReaderTheme> {
        Binding(
            get: { model.preferences.readerTheme },
            set: { value in Task { await model.readerThemeSelected(value) } }
        )
    }
}

private struct SwipeSection: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { model.preferences.swipeLeftAction },
                    set: { value in Task { await model.swipeLeftSelected(value) } }
                )
            ) {
                ForEach(SwipeAction.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Label {
                    Text("Swipe left", bundle: #bundle)
                } icon: {
                    Image(systemName: "arrow.left")
                }
            }
            .pickerStyle(.menu)
            Picker(
                selection: Binding(
                    get: { model.preferences.swipeRightAction },
                    set: { value in Task { await model.swipeRightSelected(value) } }
                )
            ) {
                ForEach(SwipeAction.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Label {
                    Text("Swipe right", bundle: #bundle)
                } icon: {
                    Image(systemName: "arrow.right")
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Swipe actions", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

private struct LibrarySection: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { model.preferences.downloadPolicy },
                    set: { value in Task { await model.downloadPolicySelected(value) } }
                )
            ) {
                ForEach(DownloadPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline downloads", bundle: #bundle)
                        Text(
                            "\(model.storageBytes.formatted(.byteCount(style: .file))) used",
                            bundle: #bundle
                        )
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .pickerStyle(.menu)
            Button {
                model.downloadAllNowTapped()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download all now", bundle: #bundle)
                        Text("Fetch new articles and save them for offline reading", bundle: #bundle)
                            .font(.footnote)
                            .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                } icon: {
                    Image(systemName: "arrow.down.to.line")
                }
            }
            .accessibilityIdentifier("settings.downloadAll")
            Button(role: .destructive) {
                model.removeDownloadsTapped()
            } label: {
                Label {
                    Text("Remove downloaded articles", bundle: #bundle)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .accessibilityIdentifier("settings.removeDownloads")
            NavigationLink(value: SettingsRoute.import) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import", bundle: #bundle)
                        Text("From Pocket and others", bundle: #bundle)
                            .font(.footnote)
                            .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .accessibilityIdentifier("settings.import")
            NavigationLink(value: SettingsRoute.export) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export library", bundle: #bundle)
                        Text("CSV or JSON", bundle: #bundle)
                            .font(.footnote)
                            .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .accessibilityIdentifier("settings.export")
        } header: {
            Text("Library", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

private struct PrivacySection: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Section {
            if model.isTelemetryAvailable {
                Toggle(
                    isOn: Binding(
                        get: { model.consent.analyticsEnabled },
                        set: { value in Task { await model.analyticsToggled(value) } }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share usage analytics", bundle: #bundle)
                        Text(
                            "Anonymous statistics about which features are used, never what you read",
                            bundle: #bundle
                        )
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                }
                .accessibilityIdentifier("settings.analytics")
                Toggle(
                    isOn: Binding(
                        get: { model.consent.crashReports },
                        set: { value in Task { await model.crashReportsToggled(value) } }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send crash reports", bundle: #bundle)
                        Text("Helps fix bugs; contains no article content", bundle: #bundle)
                            .font(.footnote)
                            .foregroundStyle(SrokaColor.onSurfaceVariant)
                    }
                }
                .accessibilityIdentifier("settings.crashReports")
            }
            Link(destination: SettingsViewModel.privacyPolicyURL) {
                Label {
                    Text("Privacy policy", bundle: #bundle)
                } icon: {
                    Image(systemName: "hand.raised")
                }
            }
            Link(destination: SettingsViewModel.termsURL) {
                Label {
                    Text("Terms of service", bundle: #bundle)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }
        } header: {
            Text("Privacy", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

private struct AccountSection: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Section {
            LabeledContent {
                if let email = model.email {
                    Text(email)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                } else {
                    Text("Not signed in", bundle: #bundle)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                }
            } label: {
                Label {
                    Text("Email", bundle: #bundle)
                } icon: {
                    Image(systemName: "envelope")
                }
            }
            .privacySensitive()
            NavigationLink(value: SettingsRoute.server) {
                LabeledContent {
                    Text(model.serverURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                } label: {
                    Label {
                        Text("Server", bundle: #bundle)
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                }
            }
            .accessibilityIdentifier("settings.server")
            if model.email != nil {
                Button(role: .destructive) {
                    model.signOutTapped()
                } label: {
                    Label {
                        Text("Sign out", bundle: #bundle)
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
                .accessibilityIdentifier("settings.signOut")
                Button(role: .destructive) {
                    model.deleteAccountTapped()
                } label: {
                    Label {
                        Text("Delete account", bundle: #bundle)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.minus")
                    }
                }
                .accessibilityIdentifier("settings.deleteAccount")
            }
            LabeledContent {
                Text(model.appVersion)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
            } label: {
                Label {
                    Text("Version", bundle: #bundle)
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
        } header: {
            Text("Account", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

// MARK: - Toast

struct MessageToast: View {
    let message: LocalizedStringResource?

    var body: some View {
        if let message {
            Text(message)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .floatingGlass()
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("settings.message")
        }
    }
}

// MARK: - Titles

extension ThemeMode {
    var title: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("System", bundle: #bundle)
        case .light: LocalizedStringResource("Light", bundle: #bundle)
        case .dark: LocalizedStringResource("Dark", bundle: #bundle)
        }
    }
}

extension ReaderTheme {
    var title: LocalizedStringResource {
        switch self {
        case .auto: LocalizedStringResource("Auto", bundle: #bundle)
        case .light: LocalizedStringResource("Light", bundle: #bundle)
        case .sepia: LocalizedStringResource("Sepia", bundle: #bundle)
        case .dark: LocalizedStringResource("Dark", bundle: #bundle)
        }
    }
}

extension SwipeAction {
    var title: LocalizedStringResource {
        switch self {
        case .archive: LocalizedStringResource("Archive", bundle: #bundle)
        case .favorite: LocalizedStringResource("Favorite", bundle: #bundle)
        case .tags: LocalizedStringResource("Tags", bundle: #bundle)
        case .none: LocalizedStringResource("None", bundle: #bundle)
        }
    }
}

extension DownloadPolicy {
    var title: LocalizedStringResource {
        switch self {
        case .wifiOnly: LocalizedStringResource("Wi-Fi only", bundle: #bundle)
        case .anyNetwork: LocalizedStringResource("Any network", bundle: #bundle)
        case .manual: LocalizedStringResource("Manual only", bundle: #bundle)
        }
    }
}
