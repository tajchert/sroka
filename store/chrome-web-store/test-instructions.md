# Chrome Web Store: Test instructions

Sign-in is passwordless (email one-time code, 6 digits). A reviewer cannot read the mailbox of an address they do not own, so the API has a fixed reviewer login. When the API secrets `REVIEW_EMAIL` and `REVIEW_OTP` are both set, a sign-in code requested for exactly that email address (compared trimmed and lowercased) is always the value of `REVIEW_OTP`; every other address gets a random code. Source: `workers/api/src/auth.ts` (`generateOTP` override in `emailOTP`; vars declared in `workers/api/src/env.ts`). Codes expire after 5 minutes, 5 wrong attempts lock the code, and sending is limited to 3 codes per minute, so tell the reviewer not to retry rapidly. The email is still "sent" by the normal path but nothing needs to arrive.

Owner before submitting: set both secrets on the production API worker (`wrangler secret put REVIEW_EMAIL` and `REVIEW_OTP` in `workers/api`), use an address you control that is not a real user's account, and fill in the placeholders below. Never commit the values. Delete the secrets after review if you do not want a standing test login.

## Paste into "Test instructions" (replace the two placeholders)
```
Sroka needs an account; sign-in is by email one-time code. Use this reviewer account (no real mailbox needed):

Email: <REVIEW_EMAIL>
Code: <REVIEW_OTP>

1. Click the extension's toolbar icon (the magpie). Enter the email above to request a code. On the code screen, type the code above. The code is fixed for this account, so no email needs to arrive. Please request it once; codes are rate limited.
2. Open any article in a tab, for example https://en.wikipedia.org/wiki/Magpie, then click the toolbar icon (or press Alt+Shift+S). The popup shows "Saved". Add a tag or toggle Favorite.
3. Press "Open" in the popup (or right-click the toolbar icon and choose Open Sroka) to see the saved page in the web library at https://sroka.app/app/.
4. Right-click a page and choose the Sroka save entry; it works the same way. Right-click the toolbar icon on a saved page to see "Open in Sroka" and "Remove from Sroka".
5. Options (right-click the toolbar icon > Options): the capture setting and the analytics and error-report switches. Analytics is off until you press "Allow" on the card shown after the first save.

Permissions are used only after these user actions. The optional host permission (https://*/*) is requested only if you enter a custom server URL in Options; you can ignore that field.
Privacy policy: https://sroka.app/privacy
```
