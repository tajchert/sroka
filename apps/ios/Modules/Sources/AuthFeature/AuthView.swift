import SrokaCore
import SrokaDesign
import SwiftUI

/// Sign-in flow: email step, then code step (also the "sign in again" screen). The app root owns the
/// view model and reacts to `AuthIntent`.
public struct AuthView: View {
    @Bindable var model: AuthViewModel

    public init(model: AuthViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch model.step {
                    case .email: EmailStepView(model: model)
                    case .code:
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                model.useAnotherEmailTapped()
                            } label: {
                                Label {
                                    Text("Back", bundle: #bundle)
                                } icon: {
                                    Image(systemName: "chevron.left")
                                }
                                .foregroundStyle(SrokaColor.brand)
                            }
                            .accessibilityIdentifier("auth.backButton")
                            CodeStepView(model: model)
                        }
                    }
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 22)
                .padding(.top, model.step == .email ? 36 : 14)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(SrokaColor.background)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(SrokaColor.brand)
        .sheet(isPresented: $model.isShowingServerSheet) {
            ServerURLSheet(model: model)
        }
        .task { await model.task() }
        .animation(.default, value: model.step)
    }
}

// MARK: - Email step

struct EmailStepView: View {
    @Bindable var model: AuthViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandMark()
            Text("Sign in to Sroka", bundle: #bundle)
                .font(.brandHeading(.title))
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle, bundle: #bundle)
                .font(.subheadline)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 6) {
                TextField(text: $model.email) {
                    Text("Email", bundle: #bundle)
                }
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit { Task { await model.sendCodeTapped() } }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(SrokaColor.surfaceLowest, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(model.error == nil ? SrokaColor.outlineVariant : SrokaColor.error)
                }
                .accessibilityIdentifier("auth.emailField")
                if let message = model.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.error)
                        .accessibilityIdentifier("auth.error")
                }
            }
            SendCodeButton(model: model)
            SelfHostingButton(model: model)
        }
        .sensoryFeedback(.error, trigger: model.failureCount)
    }

    private var subtitle: LocalizedStringKey {
        model.isSigningInAgain
            ? "Sign in again to sync your library. We’ll email you a 6-digit code."
            : "We’ll email you a 6-digit code. No password needed."
    }
}

private struct SendCodeButton: View {
    let model: AuthViewModel

    var body: some View {
        Button {
            Task { await model.sendCodeTapped() }
        } label: {
            Group {
                if model.isLoading {
                    ProgressView()
                } else {
                    Text(Vocabulary.sendCode)
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(SrokaColor.brand)
        .disabled(model.isLoading)
        .padding(.top, 2)
        .accessibilityIdentifier("auth.sendCodeButton")
    }
}

private struct SelfHostingButton: View {
    let model: AuthViewModel

    var body: some View {
        Button {
            Task { await model.selfHostingTapped() }
        } label: {
            if let host = model.customServerHost {
                Text("Self-hosting? · \(host)", bundle: #bundle)
            } else {
                Text("Self-hosting?", bundle: #bundle)
            }
        }
        .font(.subheadline)
        .tint(SrokaColor.brand)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityIdentifier("auth.selfHostingButton")
    }
}

// MARK: - Code step

struct CodeStepView: View {
    @Bindable var model: AuthViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check your inbox", bundle: #bundle)
                .font(.brandHeading(.title))
                .accessibilityAddTraits(.isHeader)
            Text("Enter the code sent to **\(model.email)**", bundle: #bundle)
                .font(.subheadline)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
            CodeField(code: $model.code, failureCount: model.failureCount, isDisabled: model.isLoading)
                .onChange(of: model.code) { _, value in
                    Task { await model.codeChanged(value) }
                }
            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.error)
                    .accessibilityIdentifier("auth.error")
            }
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ResendButton(model: model)
            Button {
                model.useAnotherEmailTapped()
            } label: {
                Text("Use another email", bundle: #bundle)
            }
            .font(.subheadline)
            .tint(SrokaColor.brand)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("auth.changeEmailButton")
        }
        .sensoryFeedback(.error, trigger: model.failureCount)
    }
}

private struct ResendButton: View {
    let model: AuthViewModel

    var body: some View {
        Group {
            if model.resendSeconds > 0 {
                Text("Resend code in \(model.resendSeconds) s", bundle: #bundle)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
            } else {
                Button {
                    Task { await model.resendTapped() }
                } label: {
                    Text("Resend code", bundle: #bundle)
                }
                .tint(SrokaColor.brand)
                .disabled(model.isLoading)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityIdentifier("auth.resendButton")
    }
}

/// Six cells backed by one hidden field, so the keyboard offers the code from Mail
/// (`.oneTimeCode`) and a paste lands in one piece.
struct CodeField: View {
    @Binding var code: String
    let failureCount: Int
    let isDisabled: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<AuthViewModel.codeLength, id: \.self) { index in
                    CodeCell(
                        digit: digit(at: index),
                        isCurrent: isFocused && index == min(code.count, AuthViewModel.codeLength - 1)
                    )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .disabled(isDisabled)
                .accessibilityLabel(Text("6-digit code", bundle: #bundle))
                .accessibilityIdentifier("auth.codeField")
        }
        .frame(height: 48)
        .keyframeAnimator(initialValue: 0.0, trigger: failureCount) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            LinearKeyframe(0, duration: 0)
            LinearKeyframe(-8, duration: 0.05)
            LinearKeyframe(8, duration: 0.08)
            LinearKeyframe(-5, duration: 0.07)
            LinearKeyframe(0, duration: 0.05)
        }
        .task { isFocused = true }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

private struct CodeCell: View {
    let digit: String
    let isCurrent: Bool

    var body: some View {
        Text(digit)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(SrokaColor.surfaceLowest, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isCurrent ? SrokaColor.brand : SrokaColor.outlineVariant,
                        lineWidth: isCurrent ? 2 : 1
                    )
            }
    }
}

// MARK: - Server sheet

/// "Self-hosting?": server URL entry. Saved through `SettingsRepository`.
struct ServerURLSheet: View {
    @Bindable var model: AuthViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $model.serverURLText) {
                        Text("Server URL", bundle: #bundle)
                    }
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await model.saveServerTapped() } }
                    .onChange(of: model.serverURLText) { model.serverURLEdited() }
                    .accessibilityIdentifier("auth.serverField")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.isServerURLInvalid {
                            Text("Enter a valid http:// or https:// address.", bundle: #bundle)
                                .foregroundStyle(SrokaColor.error)
                        }
                        Text(
                            "Only change this if you run your own Sroka server. Leave empty to use the default.",
                            bundle: #bundle
                        )
                    }
                }
            }
            .navigationTitle(Text("Server", bundle: #bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        model.cancelServerTapped()
                    } label: {
                        Text("Cancel", bundle: #bundle)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.saveServerTapped() }
                    } label: {
                        Text("Save", bundle: #bundle)
                    }
                    .accessibilityIdentifier("auth.serverSaveButton")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Brand mark

/// The black bookmark-magpie on a white tile (`scripts/make-icons.mjs`, "6a"), drawn in code so
/// the feature needs no image asset.
struct BrandMark: View {
    var body: some View {
        Canvas { context, size in
            let k = size.width / 100
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            func polygon(_ points: [(Double, Double)]) -> Path {
                var path = Path()
                path.move(to: point(points[0].0, points[0].1))
                for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
                path.closeSubpath()
                return path
            }
            var body = Path()
            body.move(to: point(30, 20))
            body.addLine(to: point(62, 20))
            body.addQuadCurve(to: point(70, 28), control: point(70, 20))
            body.addLine(to: point(70, 82))
            body.addLine(to: point(50, 77))
            body.addLine(to: point(30, 82))
            body.closeSubpath()
            context.fill(body, with: .color(Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255)))
            context.fill(
                polygon([(30, 56), (70, 46), (70, 58), (30, 68)]),
                with: .color(Color(red: 0x1E / 255, green: 0x6F / 255, blue: 0x8F / 255))
            )
            context.fill(
                polygon([(69, 27), (83, 33), (69, 39)]),
                with: .color(Color(red: 0xF2 / 255, green: 0xC8 / 255, blue: 0x4B / 255))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: 54 * k, y: 28 * k, width: 8 * k, height: 8 * k)),
                with: .color(.white)
            )
        }
        .frame(width: 60, height: 60)
        .background(.white)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        .accessibilityHidden(true)
    }
}
