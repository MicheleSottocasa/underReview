# ReviewDesk

A native macOS app for reviewing GitHub pull requests: a private inbox with local projects and folders, native GitHub stacks, manual and AI-assisted review, drafts saved to your pending GitHub review, and update notifications.

There is no backend. Notes, folders, drafts and AI results stay in `~/Library/Application Support/ReviewDesk/`. GitHub is reached only through the `gh` CLI. Code goes to a cloud AI provider only when you run a review with Claude Code or Codex.

## Requirements

- macOS 14 or later, with Swift 6 (the Command Line Tools are enough; Xcode is not required).
- [`gh`](https://cli.github.com), logged in (`gh auth login`). The active `gh` account is the one ReviewDesk uses.
- Optional, for AI review: `claude` (Claude Code) and/or `codex`, logged in with a subscription, or [`ollama`](https://ollama.com) with a local model. If a CLI is logged in with an API key, ReviewDesk refuses to run it, and it strips API-key environment variables from every child process.

## Commands

| Command | What it does |
| --- | --- |
| `make test` | Runs the core test suite (`swift test` plus the Swift Testing plugin path the Command Line Tools need). |
| `make app` | Builds a release `ReviewDesk.app` signed ad hoc in the repo root. Notifications only work from this bundle. |
| `make run` | `make app`, then opens it. |
| `make icon` | Regenerates `assets/AppIcon.icns` from the drawing in `assets/make-icon.swift`. |
| `swift run ReviewDesk` | Quick debug launch without a bundle (notifications are disabled). |

## Layout

- `Sources/ReviewDeskCore`: the testable core. It contains the process runner, the `gh` GitHub client, native stack grouping, the diff parser, pending-review sync, update detection, the AI context builder and the AI CLI adapters.
- `Sources/ReviewDesk`: the SwiftUI app. It contains the three-column window, the menu bar extra, notifications and settings.
- `Tests/ReviewDeskCoreTests`: Swift Testing tests. Every CLI is stubbed through `FakeRunner`.
- `assets/`: `Info.plist` and `AppIcon.icns` for the bundle, plus `make-icon.swift`, which draws the icon.

## How it behaves

- **Inbox:** PRs you authored, are assigned to, or were asked to review, plus any PR added by URL. Everything seen is monitored until you choose *Stop Monitoring*.
- **Stacks:** these come from GitHub's native stacked PRs (`gh stack`) and are shown bottom first. Folders hold a standalone PR or a whole stack.
- **Reviews:** drafts are local until *Save to GitHub as Pending*. They are then added to your existing pending review through GraphQL, never recreated. Publishing needs an explicit Comment, Approve or Request Changes choice. After a timeout, writes are reconciled against GitHub before a retry.
- **Polling:** every 60 s while active and 120 s in the background, with backoff on errors. The first load raises no notifications. Closing the window keeps the menu bar item running, and *Quit* stops monitoring.
- **AI:** *Prepare Context* shows exactly which files go into a review, plus a token estimate and the budget. Nothing is truncated silently. The CLIs run in an empty temporary directory with tools, hooks, plugins and MCP disabled.

## Not in v1

Merge, rebase or push from the app. Creating or editing stacks. Multiple GitHub accounts. Sync between devices. Submodule and LFS content in AI context. Distribution beyond a local build.
