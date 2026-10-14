# Deep links

The Tasks feature answers to a small set of URIs. The point of the sample is not
the URIs themselves but the handling rules around them, which apply to any
product deep link.

| URI | Opens |
|---|---|
| `https://sroka.app/tasks` | Task list |
| `https://sroka.app/tasks/new` | Task list → Create task |
| `https://sroka.app/tasks/{id}` | Task list → Task detail |
| `sroka://tasks/...` | The same, through the custom scheme |

## Where the pieces live

| Concern | Location |
|---|---|
| URI patterns and matching rules | `feature/tasks/api/.../TasksDeepLinks.kt` |
| Intent filters | `app/src/main/AndroidManifest.xml` |
| Intent handling, cold and warm | `app/.../MainActivity.kt` |
| Back stack installation | `app/.../navigation/SrokaNavHost.kt` |
| Rule tests | `feature/tasks/api/src/test/` |
| End-to-end tests | `app/src/test/.../DeepLinkNavigationTest.kt` |

The matching rules sit in the feature's `api` module because the URIs a feature
answers to are part of its navigation contract, alongside its routes. The app
module composes deep links from every feature without depending on any
implementation.

## Rules this sample follows

**A deep link is untrusted input.** Any app can send any Intent with any URI.
The resolver is a parser for hostile data, and every unrecognised URI returns
null so the app opens normally instead of guessing.

**Only the URI is read.** Nothing consults Intent extras to decide where to
navigate, and nothing launches a nested Intent taken from the extras. Forwarding
an Intent supplied by a caller is the intent-redirection vulnerability; if a
product ever needs it, sanitize with `androidx.core.content.IntentSanitizer`
first.

**Arguments are validated before they become routes.** A task id must match a
bounded allowlist pattern. That stops traversal-shaped values, oversized strings
and anything that could be concatenated into a query downstream.

**The host is compared exactly.** `sroka.app.evil.test` and
`sub.sroka.app` are not this app's host. Suffix or prefix matching on a URI
allowlist is the obvious way in.

**Entering at a detail screen does not trap the user.** `/tasks/{id}` resolves
to a *synthetic back stack* of list then detail, so the first Back press goes to
the task list inside the app rather than back to whatever launched the link.

**The warm path is checked like the cold path.** `launchMode="singleTop"` means
a link arriving while the app runs reaches `onNewIntent`, never `onCreate`.
Validating only in `onCreate` leaves the warm path open. `setIntent` is called
before processing so `getIntent()` matches what is being handled.

**A warm-start link replaces the back stack rather than appending to it.**
Appending leaves the user's earlier history underneath an unrelated destination,
so Back walks backwards through two unrelated journeys.

**App Links and custom schemes are separate intent filters.** Attributes inside
one filter combine as a cross product, so merging them would also claim
`sroka://sroka.app` and `https://tasks`. Only the `https` filter is
verifiable; a custom scheme can be registered by any other installed app, so
treat data arriving through it as lower trust.

## Before shipping

1. Replace the host, and publish `/.well-known/assetlinks.json` containing the
   app's signing certificate fingerprint. `autoVerify="true"` does nothing until
   that file resolves.
2. Verify on device with:
   ```bash
   adb shell am start -W -a android.intent.action.VIEW \
     -d "https://sroka.app/tasks/abc-123" app.sroka.debug
   adb shell pm get-app-links app.sroka
   ```
3. Decide what a deep link to a signed-out or unauthorized resource does. This
   sample has no authentication, so it navigates unconditionally; a real product
   must resolve the destination *after* establishing identity, and must not leak
   whether a resource exists.
4. Re-check every rule above whenever a new URI is added.

## Navigation 3 matchers

The template uses stable Navigation 3 **1.2.0**. `UriDeepLinkMatcher` maps
explicit HTTPS and custom-scheme patterns to the feature's serializable keys.
Every matcher uses `.withBackStack` to declare its synthetic stack.
`maxOrNull()` selects the best match, so literal `/tasks/new` takes precedence
over `/tasks/{taskId}`. Path segments are decoded and re-encoded individually
before matching so encoded `new` also selects create, without changing segment
boundaries or decoding arguments twice. The resolver validates the extracted task ID before
returning a stack; matching alone does not establish product validity or access.

The Activity passes only `Intent.data` to the resolver. `DeepLinkRequest` is
constructed from that URI, so Intent extras remain outside the navigation
contract. Apps whose contracts depend on action or MIME type can instead use
`DeepLinkRequest(intent = intent)` with explicit matcher filters.

URI matcher tests run under Robolectric because `DeepLinkUri` on Android is an
alias of `android.net.Uri`. They exercise real matching, decoded arguments,
route precedence, authority rejection, and synthetic stacks. Activity tests
cover cold and warm starts, Back, and stack replacement.

Patterns include an explicit scheme and authority; ports and user-info not
present in those patterns are rejected. Paths are exact, including empty
segments and trailing slashes. Explicit root validation and a create-matcher
filter preserve case-sensitive literals because the library matches URI
patterns without regard to case; `NEW` remains a task identifier. Extra query parameters do not override path IDs.

See the official [deep-link guide](https://developer.android.com/guide/navigation/navigation-3/deep-links)
and [URI matching rules](https://developer.android.com/guide/navigation/navigation-3/deep-links/uri-matcher).
