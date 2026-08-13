<p align="center">
  <img src="assets/hero.svg" alt="Aether Courier — a private, AI-native email client for macOS" width="100%">
</p>

<h1 align="center">Aether Courier</h1>

<p align="center">
  <b>A private, AI‑native email client for macOS.</b><br>
  Native SwiftUI · a self‑contained mail engine · a built‑in AI that actually <i>does things</i> — running on <b>your</b> Mac.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-26%20Tahoe-8d5cf7?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-ec4899?logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-3b82f6">
  <img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen">
  <img alt="Issues" src="https://img.shields.io/badge/issues-open-8d5cf7">
</p>

---

## Why Aether Courier?

Most "AI email" apps ship your mail to someone else's servers. Aether Courier is the opposite: the **mail engine is self‑contained** and the **AI runs locally on your Mac** (via [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai)). No third‑party relay sees your inbox, and the assistant isn't a chatbot bolted on the side — it's an **agent** that can read, sort, summarise, and clean up your mailboxes for you.

> Think Apple‑Mail‑native polish, a Copilot that can *take action*, and everything private by default.

## ✨ Features

| | |
|---|---|
| 🔒 **Local‑first AI** | The Copilot talks to Ollama / LM Studio on your machine by default. Point it at any OpenAI‑compatible endpoint if you prefer. |
| 🤖 **An agent, not a chatbot** | Summarise unread & flag important, sort inboxes into folders, report spam across a whole sender/domain, empty trash/spam, unsubscribe, run a phishing/security check, draft replies, create calendar events, and read PDF/image attachments (Vision OCR). |
| ⚡ **Real push, never polling** | New mail arrives instantly over **IMAP IDLE**, with an optional macOS notification sound. |
| 📬 **Works with your accounts** | iCloud, Gmail, Outlook/Office 365 (OAuth), and Proton (via Proton Mail Bridge). Unified "All Inboxes" across every account. |
| 🧰 **Self‑contained mail engine** | `EmailKit` — a zero‑dependency Swift package implementing IMAP, SMTP, MIME and OAuth2 (PKCE + XOAUTH2) directly on `Network.framework`. No CocoaPods, no SPM tree. |
| 🗂️ **Full mailbox** | All folders, filters (Unread, Attachments, …), search, flags, multi‑select bulk actions, move‑to‑folder, create/delete folders. |
| 🛡️ **Private by default** | Remote images (tracking pixels) blocked until you ask; links open in your real browser, not an in‑app view; a blocked‑senders list; nothing leaves your Mac except mail to your own servers. |
| 💾 **Download once, open instantly** | Message bodies are cached to disk and re‑opened with zero network — works offline, survives restarts. A background warmer fills the cache without ever getting in your way. |
| 🎨 **A theme you'll actually enjoy** | A soft "aurora glass" look — frosted panels, gradient accents, glowing orbs — tuned for macOS 26 Liquid Glass, in light and dark. |

## 📸 Screenshots

> _Add your own screenshots here (see [`docs/screenshots`](docs/)); the shots below show the aurora‑glass theme, the reading pane, and the AI Copilot._

| Reading & theme | AI Copilot |
|---|---|
| _`docs/reading.png`_ | _`docs/copilot.png`_ |

## 🚀 Install

Aether Courier is currently **build‑from‑source** (a signed release build is on the roadmap). It targets **macOS 26 "Tahoe"**.

### Prerequisites
- **Xcode 26+** (full app, not just Command Line Tools)
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- *(optional, for AI)* [**Ollama**](https://ollama.com): `brew install ollama` then `ollama pull llama3.1:8b`

### Build & run
```bash
git clone https://github.com/ic3y808/aether-courier.git
cd aether-courier
./build.sh          # xcodegen generate + xcodebuild → installs to ~/Applications
open ~/Applications/Aether-Courier.app
```

> The `.xcodeproj`, `Info.plist` and entitlements are **generated from `project.yml`** (the source of truth) and are gitignored — never hand‑edit them; run `./build.sh` or `xcodegen generate`.

### Run the tests
```bash
cd EmailKit && ./test.sh    # IMAP/SMTP/MIME/OAuth unit tests (scripted, no network)
```

## 🧭 Using it

1. **Add an account** — click **Add Account** and pick your provider.
   - **Gmail / Outlook** use OAuth. You supply your own OAuth **client ID** in **Settings → Providers** (a Google Cloud "iOS/Desktop" client, or an Azure Entra application ID). This keeps *you* in control of your own app registration — no shared keys.
   - **iCloud / Proton** use an **app‑specific password** (Proton via the local [Proton Mail Bridge](https://proton.me/mail/bridge)).
2. **Turn on the AI** — install Ollama, `ollama pull llama3.1:8b`, then open **Settings → Model** and pick your model. (Any OpenAI‑compatible server works; flip to a remote host in Settings if you don't want local.)
3. **Ask the Copilot** — try *"summarise my unread and flag anything important"*, *"sort my inboxes into folders"*, or *"is this email a phishing attempt?"*. It runs as an agent and reports what it did.
4. **Pick a notification sound** — **Settings → Sync → Notifications**.

## 🔐 Privacy & security

- **Your mail never touches a third party.** IMAP/SMTP talk directly to your providers.
- **AI is local by default.** Prompts go to Ollama/LM Studio on your Mac; nothing is sent to a cloud model unless you explicitly configure a remote host.
- **Credentials live in the macOS Keychain**, never in code or plain files. This repo contains **no secrets** — you register your own OAuth client IDs.
- **Tracking pixels blocked**, external links open in your default browser, per‑message "Show Images".

## 🏗️ Architecture

```
Aether-Courier/           SwiftUI app (macOS 26)
├── App/                  Store, root layout, settings
├── AI/                   Copilot client + agent (tool-calling over /v1/chat/completions)
├── Mail/                 MailService — ties EmailKit to accounts, IDLE, disk cache
├── Features/             Sidebar · MessageList · Reading · Copilot · Settings · Compose
└── EmailKit/             ← self-contained Swift package (the mail engine)
    └── Sources/EmailKit/ IMAP · SMTP · MIME · OAuth2 (PKCE/XOAUTH2) over Network.framework
```

The whole networking layer is **dependency‑free** and unit‑tested against scripted server transcripts — a good place to start if you want to learn how IMAP/SMTP really work.

## 🗺️ Roadmap

- [ ] Notarised, signed `.dmg` release + auto‑update
- [ ] Threaded conversation view
- [ ] Rich compose (formatting, inline images, drag‑drop attachments)
- [ ] Rules / smart mailboxes
- [ ] Calendar & contacts panes
- [ ] iOS companion

Have an idea? [Open an issue](../../issues/new/choose) or 👍 an existing one.

## 🤝 Contributing

Contributions are very welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)** and our **[Code of Conduct](CODE_OF_CONDUCT.md)**. Good first issues are labelled [`good first issue`](../../issues?q=is%3Aissue+label%3A%22good+first+issue%22). Bug reports and feature requests go through the [issue templates](../../issues/new/choose).

## 📣 Spread the word

If Aether Courier is useful to you, a ⭐ helps others find it. See **[MARKETING.md](MARKETING.md)** for where the project is being shared and how to help.

## 📄 License

[MIT](LICENSE) © Aether Courier contributors. Do (almost) anything you like; no warranty.

---

<p align="center"><sub>Built with SwiftUI, EmailKit, and a locally‑run LLM. No inbox left the building.</sub></p>
