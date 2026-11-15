# Chrome Web Store: Store listing tab

Paste the text inside the fenced blocks. Everything outside the fences is a note for the owner.

## Name (from manifest, max 75)
```
Sroka — Save for later
```

## Summary (dashboard field, max 132 chars; this text is 124)
```
Save any page to read later in Sroka. One click or Alt+Shift+S. Keeps paywalled pages and Reddit, X and Hacker News threads.
```
Note: the manifest `description` ("Save pages to read later in Sroka") is a different, shorter string. Optionally change it in `apps/extension/wxt.config.ts` to match before building the final zip.

## Detailed description (plain text, max 16,000)
```
Sroka is a read-later app: save it now, read it later, on any device.

This extension adds a save button to Chrome. Click the magpie in the toolbar (or press Alt+Shift+S) and the page goes into your Sroka library. Open it later in the Sroka web app or the Sroka Android app, in a clean reader view, even offline.

WHAT YOU CAN DO
- Save the current page from the toolbar button or the keyboard shortcut (Alt+Shift+S, rebindable at chrome://extensions/shortcuts).
- Save a link or a page from the right-click menu.
- Add tags and mark favorites right from the popup. Sroka suggests tags you already use.
- See on the toolbar badge that the page you are on is already saved. This check is done on your device; the address of the page you are visiting is not sent to Sroka for it.
- Right-click the toolbar icon to open your library, open the saved copy, or remove the page.

PAYWALLED AND JAVASCRIPT-HEAVY PAGES
By default the extension sends Sroka the page as your browser has rendered it, so pages you are signed in to, paywalled articles and pages that need JavaScript are saved as you see them. You can turn this off in the extension options.

REDDIT, X AND HACKER NEWS
Save a thread and Sroka keeps the discussion with it: Reddit posts with their comment tree, X threads, Hacker News stories with their comments.

RE-SAVE
If a saved item only has a preview (for example a paywalled page), the Sroka web app can ask the extension to open the page so you can save the full version.

SIMPLE AND PRIVATE
- Sign in with your email and a one-time code. No password.
- No ads. Your library is not sold and not used to train AI models.
- Usage statistics are off until you allow them. Crash and error reports can be turned off in the options.
- Export your library or delete your account at any time from Settings in the Sroka app.
- Optional: point the extension at your own Sroka server in the options page (the browser asks for permission for that address).

Sroka is open source (Apache-2.0). Privacy policy: https://sroka.app/privacy
```

## Category
Productivity

## Language
English

## URLs
- Homepage URL: `https://sroka.app`
- Support URL: `https://sroka.app` (no support page exists; contact email is hello@sroka.app, which can be entered as the support email in Account settings)
- Privacy policy URL: `https://sroka.app/privacy`
- Official URL / verified site: leave "None" (no Search Console verification done).

## Images (owned by the chrome-images agent: `store/chrome-web-store/images/`)
Icon 128x128, 1-5 screenshots 1280x800, small promo tile 440x280, optional marquee 1400x560.
