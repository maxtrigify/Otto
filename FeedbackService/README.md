# Otto feedback service

A small Cloudflare Worker behind **Help › Send Feedback…** in the Otto app. The app posts a
bug report or idea as JSON; the worker validates it, cleans the text and files it as a
**public** issue on [maxtrigify/Otto](https://github.com/maxtrigify/Otto/issues). The app shows
people that the report is public before they send it.

The worker holds the only credential (a GitHub token stored as a Worker secret). Nothing in this
folder is secret: it contains no account ID, token or private URL.

## API

`POST https://feedback.openotto.io/v1/feedback` with `Content-Type: application/json`, body ≤ 4 MB:

```json
{
  "kind": "bug",
  "title": "Optional, at most 120 characters",
  "description": "Required, 10 to 5,000 characters",
  "screenshot": {"mediaType": "image/png", "base64": "…"},
  "environment": {"appVersion": "0.2.0", "build": "42", "macOS": "26.1", "architecture": "arm64", "model": "Mac15,6"},
  "installID": "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
}
```

`kind` is `bug` or `idea`. `screenshot` (PNG or JPEG, ≤ 3 MB decoded, checked by magic bytes)
and `environment` are optional. `installID` is a random UUID the app creates once; it is used
only as a rate-limit key and never reaches GitHub or the logs. Neither does the client IP.

| Status | Body | Meaning |
|---|---|---|
| 201 | `{"issueNumber": 17, "issueURL": "https://github.com/…/issues/17"}` | Filed |
| 400 / 413 / 415 | `{"error": "…"}` | Invalid report (short, human-readable message) |
| 429 | `{"error": "…"}` + `Retry-After` | Rate limited |
| 502 | `{"error": "…"}` | GitHub refused or could not be reached (only the status is logged) |
| 503 | `{"error": "…"}` | Not configured (missing token, rate-limit bindings or screenshots branch) |

`GET /health` returns `ok`. Every other method or path is 404/405.

## What the issue looks like

Title `[Bug] <title or first line, ≤ 80 characters>` or `[Idea] …`; labels `bug` or
`enhancement`, plus `from-app`. The body is the description, the screenshot (if any), a
**Details** section with the app and Mac versions (if the person left that switch on), and a
"Sent from the Otto app." footer.

Text is cleaned before posting: HTML tags and comments are removed, remaining `<` is escaped,
`@mentions` get a zero-width joiner so nobody is notified, `![` is escaped so only the worker
can embed an image, more than three blank lines collapse, and bidi/control characters are
dropped. Plain links are kept.

Screenshots are committed through the Contents API to the `feedback-screenshots` branch at
`screenshots/<YYYY-MM>/<uuid>.<png|jpg>` and embedded as
`https://raw.githubusercontent.com/maxtrigify/Otto/feedback-screenshots/<path>`.

## Rate limits

Cloudflare's rate limiting binding only counts over 10- or 60-second windows, so the limits
are per minute: 2 reports per install ID, 5 per client IP and 30 in total across everyone
(`wrangler.jsonc`). The global cap also bounds GitHub API use. A longer daily cap would need
a Durable Object or KV counter; it is not implemented. If spam appears, lower these numbers or
add a Cloudflare WAF rate limiting rule on `feedback.openotto.io/v1/feedback`.

## Development

```
npm ci --ignore-scripts
npm test
npm run dev        # wrangler dev on http://127.0.0.1:8792
```

The tests mock GitHub and the rate-limit bindings; they make no network calls. To point a
Debug build of the app at a local worker, launch it with
`OTTO_FEEDBACK_URL=http://127.0.0.1:8792/v1/feedback`.

## Deploying (owner only)

1. **Cloudflare login.** `npx wrangler login` with the Cloudflare account that holds the
   `openotto.io` zone. (Or export `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` in the shell.
   Never commit the account ID here.)
2. **GitHub token.** At GitHub › Settings › Developer settings › Fine-grained tokens, create a
   token owned by `maxtrigify` with **Repository access: Only select repositories → maxtrigify/Otto**
   and these repository permissions only:
   - **Issues: Read and write** (create issues and apply labels)
   - **Contents: Read and write** (commit screenshots to `feedback-screenshots`)
   - Metadata: Read-only (added automatically)

   Give it an expiry and put a reminder in the calendar to rotate it.
3. **Store the token.** `npx wrangler secret put GITHUB_TOKEN` and paste it. It is never in
   this repository, the app or the logs.
4. **Labels.** Make sure `bug`, `enhancement` and `from-app` exist on maxtrigify/Otto
   (`gh label create from-app --repo maxtrigify/Otto --color 5319e7 --description "Sent from the Otto app"`).
5. **Screenshots branch.** Create an empty orphan branch so screenshots never touch `main`:

   ```
   git clone --no-checkout https://github.com/maxtrigify/Otto.git otto-shots && cd otto-shots
   git switch --orphan feedback-screenshots
   git commit --allow-empty -m "Feedback screenshots from the Otto app"
   git push origin feedback-screenshots
   ```

   Without it, reports with a screenshot return 503 and the app asks the person to try again
   without one. Consider a branch ruleset that blocks force pushes and deletion for it.
6. **Deploy.** `npm ci --ignore-scripts && npm test && npx wrangler deploy`. The `routes` entry
   creates the `feedback.openotto.io` custom domain and its certificate.
7. **Check.** `curl https://feedback.openotto.io/health` prints `ok`. Then send a real report from
   a Debug build and close the resulting issue.

The app's packaged `Info.plist` already points at `https://feedback.openotto.io/v1/feedback`
(`OttoFeedbackURL`). Rotating the token needs only steps 2–3.
