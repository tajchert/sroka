import Foundation
import SrokaCore
import Testing

@testable import SrokaSession

struct PreferencesTests {
    @Test func `Every preference has the plan's default when nothing is stored`() {
        let store = PreferencesStore(defaults: Harness.freshDefaults())
        let prefs = store.preferences
        #expect(prefs.themeMode == .system)
        #expect(prefs.readerTheme == .auto)
        #expect(prefs.readerTextScale == 1.0)
        #expect(prefs.readerFont == .sans)
        #expect(prefs.readerLineSpacing == .normal)
        #expect(prefs.sortOrder == .newest)
        #expect(prefs.swipeLeftAction == .archive)
        #expect(prefs.swipeRightAction == .none)
        #expect(prefs.swipeHintShown == false)
        #expect(prefs.downloadPolicy == .wifiOnly)
        #expect(prefs.serverUrl == nil)
        #expect(store.consent == Consent(analytics: nil, crashReports: true))
    }

    @Test(arguments: [
        PreferenceKey.themeMode, PreferenceKey.readerTheme, PreferenceKey.readerFont, PreferenceKey.readerLineSpacing,
        PreferenceKey.sortOrder, PreferenceKey.swipeLeftAction, PreferenceKey.swipeRightAction,
        PreferenceKey.downloadPolicy,
    ])
    func `Unknown stored enum values fall back to the default`(key: String) {
        let defaults = Harness.freshDefaults()
        defaults.set("SOMETHING_NEW", forKey: key)
        #expect(PreferencesStore(defaults: defaults).preferences == UserPreferences())
        defaults.set(42, forKey: key)
        #expect(PreferencesStore(defaults: defaults).preferences == UserPreferences())
    }

    @Test func `Android-style upper-case names are not accepted`() {
        let defaults = Harness.freshDefaults()
        defaults.set("OLDEST", forKey: PreferenceKey.sortOrder)
        #expect(PreferencesStore(defaults: defaults).preferences.sortOrder == .newest)
        defaults.set("oldest", forKey: PreferenceKey.sortOrder)
        #expect(PreferencesStore(defaults: defaults).preferences.sortOrder == .oldest)
    }

    @Test func `Mistyped booleans, scale and server read as defaults`() {
        let defaults = Harness.freshDefaults()
        defaults.set("yes", forKey: PreferenceKey.swipeHintShown)
        defaults.set("big", forKey: PreferenceKey.readerTextScale)
        defaults.set(7, forKey: PreferenceKey.serverUrl)
        defaults.set("true", forKey: PreferenceKey.consentAnalytics)
        defaults.set(5, forKey: PreferenceKey.consentCrashReports)
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences == UserPreferences())
        #expect(store.consent == Consent())
    }

    @Test func `Stored text scale is clamped to the range`() {
        let defaults = Harness.freshDefaults()
        defaults.set(9.0, forKey: PreferenceKey.readerTextScale)
        #expect(PreferencesStore(defaults: defaults).preferences.readerTextScale == 1.6)
        defaults.set(0.1, forKey: PreferenceKey.readerTextScale)
        #expect(PreferencesStore(defaults: defaults).preferences.readerTextScale == 0.8)
    }

    @Test func `Values are written under the plan's keys as raw values`() async throws {
        let h = try Harness()
        await h.settings.setThemeMode(.dark)
        await h.settings.setReaderTheme(.sepia)
        await h.settings.setReaderTextScale(5)
        await h.settings.setReaderFont(.serif)
        await h.settings.setReaderLineSpacing(.loose)
        await h.settings.setSortOrder(.longest)
        await h.settings.setSwipeLeftAction(.tags)
        await h.settings.setSwipeRightAction(.favorite)
        await h.settings.setSwipeHintShown()
        await h.settings.setDownloadPolicy(.manual)
        let d = h.defaults
        #expect(d.string(forKey: "theme_mode") == "dark")
        #expect(d.string(forKey: "reader_theme") == "sepia")
        #expect(d.double(forKey: "reader_text_scale") == 1.6)
        #expect(d.string(forKey: "reader_font") == "serif")
        #expect(d.string(forKey: "reader_line_spacing") == "loose")
        #expect(d.string(forKey: "sort_order") == "longest")
        #expect(d.string(forKey: "swipe_left_action") == "tags")
        #expect(d.string(forKey: "swipe_right_action") == "favorite")
        #expect(d.bool(forKey: "swipe_hint_shown"))
        #expect(d.string(forKey: "download_policy") == "manual")
        // A second store on the same suite (the share extension) reads the same values.
        #expect(PreferencesStore(defaults: d).preferences == h.preferences.preferences)
    }

    @Test func `Preferences stream emits the current value, then changes`() async throws {
        let h = try Harness()
        var stream = h.settings.preferences.makeAsyncIterator()
        #expect(await stream.next()?.themeMode == .system)
        await h.settings.setThemeMode(.light)
        #expect(await stream.next()?.themeMode == .light)
    }

    @Test func `Download policy change notifies the content engine`() async throws {
        let calls = LockedLog()
        let h = try Harness()
        let settings = LiveSettingsRepository(
            store: h.preferences, sessionStore: h.sessionStore, auth: h.auth, defaultServerUrl: Harness.defaultServer,
            onDownloadPolicyChanged: { calls.append($0.rawValue) })
        await settings.setDownloadPolicy(.anyNetwork)
        #expect(calls.entries == ["any_network"])
    }
}

struct ConsentTests {
    @Test func `Analytics is not asked and off; crash reports on by default`() async throws {
        let h = try Harness()
        let consent = LiveConsentRepository(store: h.preferences)
        let value = try #require(await firstValue(of: consent.consent))
        #expect(value.analytics == nil)
        #expect(value.analyticsEnabled == false)
        #expect(value.crashReports)
    }

    @Test func `Consent decisions are stored and observed`() async throws {
        let h = try Harness()
        let consent = LiveConsentRepository(store: h.preferences)
        var stream = consent.consent.makeAsyncIterator()
        _ = await stream.next()
        await consent.setAnalytics(false)
        #expect(await stream.next() == Consent(analytics: false, crashReports: true))
        await consent.setAnalytics(true)
        #expect(await stream.next() == Consent(analytics: true, crashReports: true))
        await consent.setCrashReports(false)
        #expect(await stream.next() == Consent(analytics: true, crashReports: false))
        #expect(h.defaults.object(forKey: "consent_analytics") as? Bool == true)
        #expect(h.defaults.object(forKey: "consent_crash_reports") as? Bool == false)
    }
}

struct ServerUrlTests {
    @Test(arguments: [
        ("https://api.sroka.app", "https://api.sroka.app"),
        ("  https://API.Sroka.app/  ", "https://api.sroka.app"),
        ("HTTPS://example.com:8443/base/", "https://example.com:8443/base"),
        ("http://localhost:8787", "http://localhost:8787"),
        ("http://127.0.0.1:8787/", "http://127.0.0.1:8787"),
    ])
    func `Accepted server URLs are normalised`(input: String, expected: String) {
        #expect(normalizeServerUrl(input) == expected)
    }

    @Test(arguments: [
        "http://example.com",
        "http://10.0.2.2:8787",
        "http://192.168.1.2",
        "ftp://example.com",
        "https://example.com/?a=1",
        "https://example.com/?",
        "https://example.com/#top",
        "https://user:pass@example.com",
        "https://user@example.com",
        "https://",
        "example.com",
        "https://exa mple.com",
        "",
        "javascript:alert(1)",
        "https://example.com:0",
    ])
    func `Rejected server URLs`(input: String) {
        #expect(normalizeServerUrl(input) == nil)
    }

    @Test func `Invalid URL is refused and nothing changes`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        #expect(await h.settings.setServerUrl("http://evil.example.com") == false)
        #expect(h.preferences.preferences.serverUrl == nil)
        #expect(h.sessionStore.current != nil)
    }

    @Test func `Changing server while signed in signs out and wipes before switching`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok")
        try await h.insertItem()
        let provider = h.provider
        h.api.configure {
            $0.signOut = {
                // The revoke goes to the old server with the old token.
                #expect(await provider.baseUrl().absoluteString == Harness.defaultServer)
                #expect(await provider.token() == "tok")
            }
        }
        #expect(await h.settings.setServerUrl("https://other.example.com/") == true)
        #expect(h.api.recorded.contains("signOut"))
        #expect(h.sessionStore.current == nil)
        #expect(try await h.itemCount() == 0)
        #expect(h.preferences.preferences.serverUrl == "https://other.example.com")
        #expect(await provider.baseUrl().absoluteString == "https://other.example.com")
        #expect(await provider.token() == nil)
    }

    @Test func `Changing server while expired also signs out`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        h.auth.markSessionExpired()
        h.api.configure { $0.signOut = {} }
        #expect(await h.settings.setServerUrl("https://other.example.com"))
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Changing server while signed out keeps data`() async throws {
        let h = try Harness()
        try await h.insertItem()
        #expect(await h.settings.setServerUrl("https://other.example.com"))
        #expect(!h.api.recorded.contains("signOut"))
        #expect(try await h.itemCount() == 1)
    }

    @Test func `Setting the build default or nil stores nothing and does not sign out`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        #expect(await h.settings.setServerUrl("https://api.sroka.app/"))
        #expect(await h.settings.setServerUrl(nil))
        #expect(await h.settings.setServerUrl("   "))
        #expect(h.preferences.preferences.serverUrl == nil)
        #expect(h.defaults.object(forKey: "server_url") == nil)
        #expect(h.sessionStore.current != nil)
    }

    @Test func `Token is withheld when the account marker names another server`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok")
        // E.g. the share extension's suite changed the server behind the app's back.
        h.preferences.setServerUrl("https://other.example.com")
        #expect(await h.provider.token() == nil)
        h.preferences.setServerUrl(nil)
        #expect(await h.provider.token() == "tok")
    }
}
