# Changelog

ReviewDesk is a beta preview: there is no stable release yet. Each version below is a preview build.
Add a `## <version>` section here before tagging a release: the release workflow publishes it as the release's description.

## Unreleased

- Pull requests inside a stack show their number under the title in the sidebar, like standalone ones.

## 0.8.1

- **Notifications in the app:** the bell in the toolbar lists the notifications received since ReviewDesk opened (up to 50, newest first), with a badge for new ones. Click one to open its pull request; muted pull requests are listed too, marked as muted.
- **Suggested code changes:** AI findings can carry a small, certain fix. The card shows the code with a checkbox, and accepting sends it with the comment as a GitHub suggested change (single or multi-line) that the author applies with one click, submitted with your review. When its lines aren't all in the diff it's sent as plain code instead.
- A spinner in the sidebar marks every pull request an AI review, follow-up check or stack run is working on; hover it to see what the agent is doing.

## 0.8.0

- The pull request header shows how many lines the whole pull request adds and removes; hover for the number of files.
- Scrolling large diffs is smooth again: the diff is parsed and highlighted once instead of on every pointer move.
- **AI findings go straight into your pending review:** a finding about code becomes an inline comment on your pending GitHub review (on its line, or the nearest line GitHub accepts, naming the one it meant) instead of landing in the review summary. Only general remarks still go to the summary.
- A Claude Code review that couldn't read the pull request's diff now fails with an error saying so, instead of looking like a clean pull request with no findings.
- **AI review works when ReviewDesk is opened from Finder or the Dock:** `/code-review` couldn't find `gh` (apps opened that way get a minimal `PATH`), so it never saw the diff. The tools ReviewDesk starts now get the folders of `gh`, `claude` and the usual install locations on their `PATH`.
- Every icon in the sidebar explains itself in plain words on hover (open, draft, changed since your review, merged, closed, comments not sent yet, your review, replies waiting for you, review requested, notifications off), and hovering a row explains all of its icons at once.

## 0.7.2

- Switching pull request or tab while something loads no longer shows "The operation couldn't be completed (Swift.CancellationError error 1)": cancelled work isn't reported as an error anymore.
## 0.7.1

- Pull requests you approved are left out of stack runs: the Follow-up stack list hides them ("N approved by you, hidden"), and *Review Stack* and *Check Stack* don't start agents on them.
- In-app updates no longer leave a temporary copy registered with macOS, which could blank the icon in notifications.
## 0.7.0

- **Review Stack runs one agent per pull request, in parallel:** up to 3 at once by default (Settings › AI; Ollama one at a time). The progress box lists every pull request with its agent's state (waiting, running, done with its findings, failed, stopped) and live log, on the pull request you started from and on each member. Click a row to open that pull request, stop one agent alone, or *Cancel All*.
- **Check a whole stack:** the Follow-up tab lists every pull request of the stack with its latest check, and *Check Stack* checks all those with new commits or replies since your review, bottom first.
- **Install updates from the app:** *Install and Relaunch* downloads the new version, checks it against GitHub's checksum, replaces the app and relaunches it. Updates installed this way don't need the first install's right-click → Open.
## 0.6.0

- **Follow-up check:** after the author pushes or replies to your comments, *Check if addressed* asks the AI whether the changes and replies since your review handle each of your requests (addressed, partly, not addressed, pushed back or unclear), with the evidence and a button to resolve addressed threads. Its prompt is editable in Settings.
## 0.5.0

- **Onboarding tour:** on first launch, and from *Help › Show Tour*, a guided tour explains each area on a demo stack of fictional pull requests, with comments, diffs and a sample AI analysis. The demo is read-only and never saved.
- **Screenshots** of the demo in the README.
- AI rationales and key-area reasons show `code` and **bold** formatting instead of raw Markdown.
- Notifications show the app icon again after installing over an older copy.
## 0.4.0

- **Chat about a comment:** ✨ *Explain* now opens a chat where you can ask follow-up questions, and 💬 *Ask* opens it straight away for your own question. Both keep the same context: the PR description, the conversation and the diff.
- AI engines are labelled by maturity where you pick them: Claude Code is beta, Codex and Ollama are alpha.
- The app says it's a beta preview, in the sidebar footer and in Settings › General.
- Each GitHub release now describes what changed, from this changelog.

## 0.3.0

- **Changed since your review:** an open PR you reviewed that got new commits afterwards has its own state, with an orange badge, a "new commits since your review" marker and a *Changed Since Review* filter.
- **Last fetch:** the bottom of the sidebar shows when the PR list was last fetched, a spinner while fetching, the error if it failed, and a refresh button.
- **Update notices:** ReviewDesk checks GitHub Releases at launch and every 6 hours, and offers to download a newer version (banner, notification, *Check for Updates…*).
- **CI:** every push and pull request builds the app and runs the tests on GitHub.

## 0.2.0

- **Claude Code's `/code-review`** runs the AI review, with a model and effort picker, read-only access to the PR, and live progress while it works.
- **Risk tab:** walks the review as five questions (data, access, scale, failure, explain), with the AI's answer and level for each, the author's Risk notes and your own checkboxes.
- **Focus filter** in Changes: the key files and sections to read before submitting, plus every file with comments you haven't submitted.
- **Repository rules:** reviews check the change against `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` and similar files.
- **Comments:** edit, delete, react, resolve or hide as resolved, *Explain* with AI, and styled inline code.
- **Viewed checkboxes** for changed files, synced with GitHub.
- **Settings:** refresh intervals, diff layout, AI engine and model, and every AI prompt.
- **Far fewer GitHub API calls**, so the hourly rate limit isn't hit anymore; refreshes every 180 s in front and 600 s in the background.
- Docstrings and other multi-line strings are colored as strings.

## 0.1.0

- First preview: a native macOS app for reviewing GitHub pull requests. It has an inbox with local projects and folders, native GitHub stacks, a side-by-side diff with inline drafts saved to your pending GitHub review, update notifications and a menu bar item, and AI-assisted review with Claude Code, Codex or Ollama.
