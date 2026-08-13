# Getting Aether Courier in front of users

A lightweight go‑to‑market plan for a privacy‑first, local‑AI macOS email client. The audience is people who care about **owning their data** and are curious about **running LLMs locally** — a crowd that overlaps heavily with the open‑source and self‑hosting communities.

## The one‑line pitch
> **A native macOS email client with an AI that actually does your inbox chores — and it all runs on your Mac. No inbox leaves the building.**

## Positioning (what makes it shareable)
1. **Local‑first AI** — rides the Ollama / on‑device‑LLM wave. This is the hook for HN, Reddit, and the local‑LLM crowd.
2. **Privacy by default** — no relay, tracking pixels blocked, credentials in Keychain. Resonates with r/privacy, degoogle, self‑hosters.
3. **Agentic, not a chatbot** — "sort my inboxes into folders", "is this phishing?", "empty spam" — concrete, demoable value.
4. **A dependency‑free mail engine** — `EmailKit` is a genuinely interesting standalone artifact for Swift developers (great for a separate blog post / Show HN).

## Launch checklist (do these first)
- [ ] A **10–20s screen recording** (GIF/MP4) of the Copilot summarising unread and sorting folders. This is the single highest‑leverage asset.
- [ ] 2–3 clean **screenshots** with demo data (not a real inbox) → drop into `docs/` and the README.
- [ ] A **signed, notarised `.dmg`** on the GitHub Releases page (people won't build from source at launch). Until then, clear build‑from‑source steps.
- [ ] Enable **GitHub Discussions** and add a few "good first issue" labels.
- [ ] A tiny **landing page** (GitHub Pages) with the hero, the GIF, and a download button.

## Where to post (in rough order of fit)
| Channel | Angle | Notes |
|---|---|---|
| **Show HN** (news.ycombinator.com) | "Show HN: A private macOS email client with a local‑LLM agent" | Post Tue–Thu, ~9am ET. Lead with the *why* (local AI + privacy) and the GIF. Reply to every comment. |
| **r/LocalLLaMA** | "Built a macOS email client that runs its AI on Ollama" | This community *loves* practical local‑LLM apps. Show the model picker + a real task. |
| **r/macapps**, **r/apple** | Native SwiftUI, Liquid‑Glass look | Screenshots matter most here. |
| **r/selfhosted**, **r/privacy**, **r/degoogle** | "No inbox leaves your Mac" | Emphasise Keychain, no relay, Proton/self‑hosted IMAP support. |
| **Lobsters** | The `EmailKit` engine + IMAP IDLE writeup | Technical audience; a good architecture post lands well. |
| **Product Hunt** | Broad launch | Do this *after* you have a signed .dmg + polished GIF. |
| **Mastodon / Bluesky / X** | Short clips, #Swift #macOS #LocalLLM #Ollama | Tag Ollama/LM Studio; they often reshare community apps. |
| **awesome‑ lists** | PRs to `awesome-selfhosted`, `awesome-macos`, `awesome-ollama` | Durable, long‑tail discovery. |
| **Ollama / LM Studio communities** | "An app that uses your local model" | Their Discords/showcases welcome integrations. |

## Content ideas (durable traffic)
- **Blog: "How I wrote a dependency‑free IMAP/SMTP engine in Swift"** → Show HN / Lobsters gold, and it markets the app.
- **Blog: "Giving my email client a local‑LLM agent that can actually act on my mailbox."**
- **Comparison page**: Aether Courier vs. cloud‑AI email clients, on the axes of *where your mail goes* and *where the AI runs*.

## Metrics to watch
GitHub **stars** and **traffic** (Insights → Traffic), Release **downloads**, and issue/discussion volume. Early signal = referral sources from the posts above.

## Ask from every reader
The README ends with a ⭐ ask. In each post, invite issues and PRs explicitly — early contributors become long‑term maintainers.

---
_This file is a living plan; PRs that add channels, copy, or lessons‑learned are welcome._
