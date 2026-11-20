import AuthFeature
import Dependencies
import SettingsFeature
import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import SettingsFeature

extension DependencyValues {
    /// Fakes plus the real clock (models start timers) and a fixed date.
    fileprivate mutating func useSnapshotFakes(_ fakes: Fakes = Fakes()) {
        useFakes(fakes)
        continuousClock = ContinuousClock()
        date = .constant(Fixtures.now)
    }
}

/// Sign-in, settings, import, export and consent screens: light, dark and one large Dynamic Type size.
@MainActor
@Suite(.snapshots(record: .missing), .serialized)
struct AuthSettingsSnapshotTests {
    init() { SrokaFont.registerFonts() }

    // MARK: Sign in

    @Test func signInEmail() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes(session: .signedOut))
        } operation: {
            AuthViewModel()
        }
        model.email = "reader@example.com"
        check(AuthView(model: model))
    }

    @Test func signInEmailError() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes(session: .signedOut))
        } operation: {
            AuthViewModel()
        }
        model.email = "reader@example"
        await model.sendCodeTapped()
        check(AuthView(model: model), variants: [.light])
    }

    @Test func signInAgain() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes(session: .expired(email: "reader@example.com")))
        } operation: {
            AuthViewModel()
        }
        await model.task()
        check(AuthView(model: model), variants: [.light])
    }

    @Test func signInCode() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes(session: .signedOut))
        } operation: {
            AuthViewModel()
        }
        model.email = "reader@example.com"
        await model.sendCodeTapped()
        await model.codeChanged("482")
        check(AuthView(model: model))
    }

    // MARK: Settings

    @Test func settings() async {
        let fakes = Fakes(preferences: UserPreferences(readerTheme: .sepia, readerTextScale: 1.15))
        let model = withDependencies {
            $0.useSnapshotFakes(fakes)
        } operation: {
            SettingsViewModel(appVersion: "1.0 (1)")
        }
        await load(
            until: { model.email != nil && model.storageBytes > 0 && model.serverURL != "" },
            observing: { await model.task() }
        )
        check(SettingsView(model: model))
    }

    // MARK: Import

    @Test func importIdle() async {
        let fakes = Fakes()
        let model = withDependencies {
            $0.useSnapshotFakes(fakes)
        } operation: {
            ImportViewModel()
        }
        model.fileImported(.success(URL(filePath: "/tmp/ril_export.csv")))
        check(NavigationStack { ImportView(model: model) })
    }

    @Test func importRunning() async {
        let fakes = Fakes()
        fakes.dataTransfer.active.send(
            ImportJob(
                id: "job",
                status: .running,
                format: .pocketCsv,
                total: 1_200,
                done: 480,
                createdAt: Fixtures.now,
                updatedAt: Fixtures.now
            )
        )
        let model = withDependencies {
            $0.useSnapshotFakes(fakes)
            $0.date = .constant(Fixtures.now)
        } operation: {
            ImportViewModel()
        }
        await load(until: { model.job != nil }, observing: { await model.task() })
        check(NavigationStack { ImportView(model: model) }, variants: [.light])
    }

    @Test func importFinished() async {
        let fakes = Fakes()
        fakes.dataTransfer.active.send(
            ImportJob(
                id: "job",
                status: .done,
                format: .pocketCsv,
                total: 1_200,
                done: 1_200,
                skipped: 20,
                createdAt: Fixtures.now,
                updatedAt: Fixtures.now
            )
        )
        let model = withDependencies {
            $0.useSnapshotFakes(fakes)
            $0.date = .constant(Fixtures.now)
        } operation: {
            ImportViewModel()
        }
        await load(until: { model.job != nil }, observing: { await model.task() })
        check(NavigationStack { ImportView(model: model) }, variants: [.light])
    }

    // MARK: Export

    @Test func exportIdle() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes())
        } operation: {
            ExportViewModel()
        }
        check(NavigationStack { ExportView(model: model) })
    }

    @Test func exportReady() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes())
        } operation: {
            ExportViewModel()
        }
        await model.exportTapped()
        check(NavigationStack { ExportView(model: model) }, variants: [.light])
    }

    // MARK: Consent

    @Test func consentPrompt() async {
        let model = withDependencies {
            $0.useSnapshotFakes(Fakes())
        } operation: {
            ConsentPromptViewModel()
        }
        check(ConsentPromptView(model: model))
    }

    // MARK: Helpers

    enum Variant: String, CaseIterable {
        case light, dark, largeText
    }

    private func check<V: View>(
        _ view: V,
        variants: [Variant] = Variant.allCases,
        testName: String = #function,
        line: UInt = #line
    ) {
        for variant in variants {
            let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
            assertSnapshot(
                of: host,
                as: .image(on: config(variant), precision: 0.98, perceptualPrecision: 0.98),
                named: variant.rawValue,
                testName: testName,
                line: line
            )
        }
    }

    /// iPhone 18 Pro: 402 x 874 pt.
    private func config(_ variant: Variant) -> ViewImageConfig {
        var traits = [UITraitCollection(displayScale: 3), UITraitCollection(userInterfaceIdiom: .phone)]
        switch variant {
        case .light: traits.append(UITraitCollection(userInterfaceStyle: .light))
        case .dark: traits.append(UITraitCollection(userInterfaceStyle: .dark))
        case .largeText:
            traits.append(UITraitCollection(userInterfaceStyle: .light))
            traits.append(UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        }
        return ViewImageConfig(
            safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
            size: CGSize(width: 402, height: 874),
            traits: UITraitCollection(traitsFrom: traits)
        )
    }

    /// Runs an observation loop until `loaded` holds (other snapshot tests keep the main actor busy,
    /// so a fixed wait is not enough), then stops it.
    private func load(
        until loaded: @escaping @MainActor () -> Bool,
        observing observe: @escaping @MainActor () async -> Void
    ) async {
        let task = Task { await observe() }
        for _ in 0..<500 where !loaded() {
            try? await ContinuousClock().sleep(for: .milliseconds(20))
        }
        task.cancel()
    }
}
