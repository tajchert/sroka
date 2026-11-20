import SrokaCore
import SrokaDesign
import SwiftUI

/// Shared layout of the full-screen reader states: icon or spinner, title, message, actions.
private struct ReaderStatusLayout<Icon: View, Message: View, Actions: View>: View {
    let theme: EffectiveTheme
    let title: Text
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let message: () -> Message
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            icon()
            title.font(.headline).multilineTextAlignment(.center)
            message().font(.callout).multilineTextAlignment(.center).opacity(0.75)
            VStack(spacing: 10) { actions() }.padding(.top, 6)
        }
        .foregroundStyle(theme.palette.text)
        .padding(.horizontal, 32)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

/// The package is being fetched.
struct ReaderDownloadingView: View {
    let isPdf: Bool
    let theme: EffectiveTheme

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            if isPdf {
                Text("Downloading PDF…", bundle: #bundle)
            } else {
                Text("Downloading article…", bundle: #bundle)
            }
        }
        .foregroundStyle(theme.palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "Not saved for offline reading": the package is not on the device.
struct ReaderNotDownloadedView: View {
    let reason: NotDownloadedReason
    let isPdf: Bool
    let originalURL: URL?
    let theme: EffectiveTheme
    let onRetry: () -> Void

    var body: some View {
        ReaderStatusLayout(theme: theme, title: Text("Not saved for offline reading", bundle: #bundle)) {
            Image(systemName: "icloud.slash").font(.system(size: 34)).foregroundStyle(.secondary)
        } message: {
            switch reason {
            case .offline:
                Text("Connect to the internet to download this article, or open the original.", bundle: #bundle)
            case .signIn:
                Text("Sign in again to download this article.", bundle: #bundle)
            case .error:
                Text("The article could not be downloaded.", bundle: #bundle)
            }
        } actions: {
            Button(action: onRetry) { Text("Try again", bundle: #bundle) }
                .buttonStyle(.borderedProminent)
                .tint(SrokaColor.brand)
            if !isPdf { OpenOriginalButton(url: originalURL) }
        }
    }
}

/// The server has not finished parsing.
struct ReaderParsePendingView: View {
    let originalURL: URL?
    let theme: EffectiveTheme

    var body: some View {
        ReaderStatusLayout(theme: theme, title: Text("Preparing article", bundle: #bundle)) {
            ProgressView()
        } message: {
            Text("The article is being processed. It will be available after your next fetch.", bundle: #bundle)
        } actions: {
            OpenOriginalButton(url: originalURL)
        }
    }
}

/// The server could not extract the text; shows the plain reason for known failures.
struct ReaderParseFailedView: View {
    let error: String?
    let originalURL: URL?
    let theme: EffectiveTheme
    let onTryAgain: () -> Void

    var body: some View {
        ReaderStatusLayout(theme: theme, title: Text("Couldn’t save the text", bundle: #bundle)) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
        } message: {
            if let reason = Vocabulary.failureReason(error) {
                Text(reason)
            }
        } actions: {
            Button(action: onTryAgain) { Text("Try again", bundle: #bundle) }
                .buttonStyle(.borderedProminent)
                .tint(SrokaColor.brand)
            OpenOriginalButton(url: originalURL)
        }
    }
}

/// The web content process was terminated by the system.
struct ReaderRendererGoneView: View {
    let originalURL: URL?
    let theme: EffectiveTheme
    let onReload: () -> Void

    var body: some View {
        ReaderStatusLayout(theme: theme, title: Text("This article could not be displayed.", bundle: #bundle)) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
        } message: {
            Text("Open the original instead.", bundle: #bundle)
        } actions: {
            Button(action: onReload) { Text("Try again", bundle: #bundle) }
                .buttonStyle(.borderedProminent)
                .tint(SrokaColor.brand)
            OpenOriginalButton(url: originalURL)
        }
    }
}

/// Opens the original page in the browser.
struct OpenOriginalButton: View {
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                Label {
                    Text("Open original", bundle: #bundle)
                } icon: {
                    Image(systemName: "safari")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// The article header (site, title, meta line) in native text while the page loads: same place, size and colours as
/// the page's own header, so the page takes over without a jump. Hidden from accessibility (the page has the text).
struct ReaderOpeningHeader: View {
    let header: ReaderHeader
    let theme: EffectiveTheme
    let topInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(header.site).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.palette.link)
            Text(header.title).font(.system(size: 28, weight: .semibold)).lineSpacing(0)
            Text(header.metaPrefix.trimmingCharacters(in: CharacterSet(charactersIn: " ·")))
                .font(.system(size: 14)).opacity(0.65)
        }
        .foregroundStyle(theme.palette.text)
        .padding(.horizontal, 17.6)
        .padding(.top, topInset + 20)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
