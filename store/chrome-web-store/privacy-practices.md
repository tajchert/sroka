# Chrome Web Store: Privacy practices tab

Text in fenced blocks is for pasting. "Source:" lines are notes for the owner (code paths verified) and must not be pasted.

## Single purpose
```
Save web pages to the user's Sroka read-later library (a service at sroka.app) so they can read them later on any device.
```

## Permission justifications

### activeTab
```
Lets the extension read the page the user is looking at only when they click the toolbar button, press the keyboard shortcut or use the context menu. It is used to get the page URL and title and to capture the rendered page so it can be saved to the user's library. No access to other tabs or sites without a user action.
```
Source: `apps/extension/lib/save.ts` (scripting.executeScript after a user action), `entrypoints/popup/App.tsx`.

### contextMenus
```
Adds "Save to Sroka" entries to the right-click menu for pages and links, and "Open in Sroka" / "Remove from Sroka" entries on the toolbar button's menu. Nothing else is added to the menu.
```
Source: `entrypoints/background.ts` (contextMenus.create/onClicked), `lib/item-menu.ts`.

### storage
```
Stores the user's sign-in session token, their settings (the capture option and the analytics and error-report choices), the list of saves waiting to be retried while offline, and a local set of hashed addresses of already-saved pages used for the "already saved" badge. All of it stays in the browser (chrome.storage.local and chrome.storage.session).
```
Source: `lib/consent.ts`, `lib/settings.ts`, `lib/queue.ts`, `lib/saved-set.ts`, `lib/resave.ts` (storage.session).

### scripting
```
Used together with activeTab to run one function in the page the user chose to save. It copies the rendered page (with scripts, styles and other noise removed) so it can be sent to the user's own Sroka library. This is how pages behind a paywall or login, and pages that need JavaScript, are saved correctly. It runs only after a user action on that tab. No content scripts are registered and no code is injected into pages automatically.
```
Source: `lib/save.ts:81` (`scripting.executeScript({ func: pageHtmlForCapture })`); no `content_scripts` in `wxt.config.ts`.

### alarms
```
Schedules a periodic background refresh (about every 20 minutes) of the list of the user's saved pages, so the toolbar badge can show whether the current page is already saved, and retries saves that failed while the user was offline.
```
Source: `entrypoints/background.ts:115` (alarms.onAlarm), `lib/saved-set.ts` (alarm `sroka-saved-set`). Retry queue alarm: `lib/queue.ts` (`ALARM`, `alarms.create`).

### tabs
```
Used to read the URL of the active tab and to update that tab's toolbar badge and menu items (saved state), to open the Sroka library or a saved item in a new tab, and to save the right tab when a re-save is requested from the Sroka web app. The visited URL is compared locally with a hashed list of saved pages; it is not sent to any server unless the user chooses to save the page.
```
Source: `entrypoints/background.ts` (tabs.query/get/onActivated/onUpdated/onRemoved), `lib/open-app.ts`, `lib/resave.ts`, `lib/saved-set.ts`; extension CLAUDE.md "Badge privacy".

### Host permission: https://api.sroka.app/*
```
The extension talks to the Sroka API at api.sroka.app: sign-in with an email code, saving pages, tags, and syncing the list of saved items. This is the only host the extension needs by default.
```
Source: `wxt.config.ts` `host_permissions` (localhost:8787 only in development mode); `lib/api.ts`.

### Optional host permissions: https://*/* and http://localhost/*
```
Optional, and requested only at runtime when the user enters a custom server address in the options page (for self-hosted Sroka servers). The extension asks the browser for permission to that one origin only; if the user declines, the setting is not saved. Nothing is requested at install time. http://localhost is for self-hosting on the user's own machine.
```
Source: `wxt.config.ts` `optional_host_permissions`; `entrypoints/options/Options.tsx:32-33` (`permissions.contains/request`, origin-only per extension CLAUDE.md D8).

### externally_connectable (https://sroka.app/*)
```
Lets the Sroka web app at https://sroka.app send two messages to the extension: a version ping and a request to re-save an item the user already has in their library. The extension verifies the sender origin, requires a signed-in user, and only acts on items that belong to that user. It grants the web page no access to browsing data.
```
Source: `wxt.config.ts`, `lib/resave.ts`, `entrypoints/background.ts:110` (`runtime.onMessageExternal`). The store build (`SROKA_STORE_BUILD=1`) omits the localhost entry.

## Remote code
Answer: **No, I am not using remote code.**
Verified: no `eval`, `new Function`, `importScripts` or remote `<script>` in `apps/extension` (grep). All JS is bundled by WXT. The popup and options HTML load the Outfit font CSS from fonts.googleapis.com (stylesheet and font files only, not code); see Mismatches in `store/README.md`.
If a justification box appears:
```
All code is packaged in the extension. It loads no remote scripts or WebAssembly and does not use eval.
```

## Data usage: what is collected
Tick only these categories.

| Category | Tick? | Why |
|---|---|---|
| Personally identifiable information | Yes | Email address (account; sign-in codes are sent to it), stored on our server. |
| Health information | No | |
| Financial and payment information | No | No payments. |
| Authentication information | Yes (conservative) | The session token is stored in chrome.storage.local and sent to our API; the one-time code is typed in and sent to our API. There are no passwords. Google's definition covers credentials and tokens, so declare it. |
| Personal communications | No | |
| Location | No | No geolocation. The server sees the IP like any web server. |
| Web history | No (judgment call) | The extension does not collect browsing history. Only pages the user explicitly saves are sent; the badge lookup is local against a hashed list. Tick it if you want the most conservative answer, and then say so in the privacy policy. |
| User activity | Yes | Opt-in anonymous feature-use events (popup opened, library opened, login, item saved with source and kind) to Google Analytics 4, off until the user accepts. Error reports (extension version, stack, page path, user agent) to our server, on by default with opt-out. |
| Website content | Yes | Saved page URL, title and the rendered page copy (text, images) are sent to the user's library. |

Source: `lib/analytics.ts` (events `popup_open`, `open_library`, `login`, `save_item`; GA4 Measurement Protocol, sent from the background only), `lib/error-reporting.ts` (POST `/v1/client-errors`), `lib/save.ts`, `lib/api.ts`.

## Certifications (tick all three)
- I do not sell or transfer user data to third parties, outside of the approved use cases. (Cloudflare hosts the service and Google Analytics processes opt-in statistics on our behalf: approved service-provider uses.)
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
  (D16 anonymous totals of saved sites/public articles, shown to the owner only once ≥ 5 people saved them, are used to improve how pages are saved: related to the single purpose. Pages captured by the extension are never counted.)
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

## Privacy policy URL (field on this tab)
`https://sroka.app/privacy`
