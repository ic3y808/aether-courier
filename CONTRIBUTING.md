# Contributing to Aether Courier

Thanks for your interest — contributions of all sizes are welcome, from typo fixes to whole features.

## Ground rules
- Be kind. This project follows a [Code of Conduct](CODE_OF_CONDUCT.md).
- **No secrets in commits.** Credentials belong in the macOS Keychain; OAuth client IDs are configured by each user in Settings. Never commit tokens, passwords, `accounts.json`, or the generated `.xcodeproj`/`Info.plist`/entitlements.
- One focused change per pull request.

## Getting set up
```bash
brew install xcodegen
git clone https://github.com/ic3y808/aether-courier.git
cd aether-courier
./build.sh                 # generate the project + build + install to ~/Applications
cd EmailKit && ./test.sh   # run the mail-engine unit tests
```
The Xcode project is **generated from `project.yml`** — edit that (and the Swift sources), never the generated `.xcodeproj`.

## Making a change
1. Fork and branch: `git switch -c feat/short-description` (or `fix/…`, `docs/…`).
2. Keep the style of the surrounding code — match its naming, comment density, and idioms.
3. If you touch the mail engine (`EmailKit/`), add or update a test in `EmailKit/Tests`. The tests run against **scripted server transcripts**, so they need no network and no real account.
4. Build clean (`./build.sh` → `** BUILD SUCCEEDED **`) and run `EmailKit/test.sh`.
5. Open a PR describing *what* and *why*. Screenshots help for UI changes.

## Where things live
- `Aether-Courier/App` — the observable store, root layout, settings.
- `Aether-Courier/AI` — Copilot client + the agent tool loop.
- `Aether-Courier/Mail` — `MailService` (accounts, IDLE, on-disk body cache).
- `Aether-Courier/Features` — one folder per pane (Sidebar, MessageList, Reading, Copilot, Settings, Compose).
- `EmailKit/` — the dependency-free IMAP/SMTP/MIME/OAuth engine.

## Good first issues
Look for the [`good first issue`](../../issues?q=is%3Aissue+label%3A%22good+first+issue%22) label. If you're unsure where to start, open an issue and say hi.

## Reporting bugs / requesting features
Use the [issue templates](../../issues/new/choose). For bugs, include your macOS version, the provider(s) involved, and steps to reproduce. Logs are written to `~/Library/Logs/AetherCourier/courier.log` (they contain no passwords) — attaching the relevant lines speeds things up a lot.
