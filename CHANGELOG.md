# Changelog

ReviewDesk is a beta preview: there is no stable release yet. Each version below is a preview build.
Add a `## <version>` section here before tagging a release: the release workflow publishes it as the release's description.

## Unreleased

- **Merge conflicts show up:** a red triangle marks a pull request (and its stack) that conflicts with its base, the header shows *Conflicts* (click to resolve them on GitHub) or *Behind <base>*, and you're notified when one of your own pull requests starts to conflict.
- **Color themes:** Settings › Appearance picks, edits and previews the diff and syntax colors (light and dark), and imports or exports them as a JSON theme file. Colors a file leaves out keep the default.
- **Color themes:** Settings › Appearance picks, edits and previews the diff, syntax and accent colors (light and dark, your threads' and others' colors included), and imports or exports them as a JSON theme file. Colors a file leaves out keep the default.
- **Import a theme from your editor:** *Import from IDE…* finds VS Code, Cursor and JetBrains IDEs (IntelliJ IDEA, PyCharm, WebStorm, Android Studio, …), shows the theme each one uses and previews what it gives before saving. *Import…* also reads a VS Code theme file or a JetBrains `.icls` scheme.
- In side-by-side mode, added and deleted files are shown in one full-width column instead of next to an empty half.
- **Actions show progress until their result is on screen:** submitting a review, replying, resolving, editing, deleting, reacting to or hiding a comment keeps its *Submitting…*/*Sending…* state or a spinner until the reloaded pull request shows the change, instead of briefly showing the old state. Deleting a draft, marking a file viewed and the linked agent's actions (stop, logs, open in Terminal, refresh) show a spinner too, and the item can't be clicked again meanwhile. Failures still appear in the error banner.
- Pull requests inside a stack show their number under the title in the sidebar, like standalone ones.
- The Conversation tab uses the whole width of the window instead of stopping at 900 points, so long descriptions and comments wrap less.
- The **Add reaction** button opens the 8 reactions in one row, as on GitHub, with the ones you gave highlighted and each one named on hover. Arrow keys move between them, Return picks, Esc closes.
- **Involving Me** in Changes shows only the review threads you started, replied in (pending replies too) or are @mentioned in. When there are some, the file tree narrows to the files that have one, with their count; the other threads keep their marker in the gutter. The choice is remembered.
- **Your threads stand out:** a review thread you started has a teal border and bar, one started by someone else a violet one, tinted when you replied in it; folded resolved threads keep their color, dimmed. Your own comments get a light teal background and a **You** badge, so ownership doesn't depend on color alone.
- A folded resolved thread tells you what it's about without opening it: who resolved it, who took part (up to 3, then +N, you as "you"), how many comments, and the first line of the first comment (hover for all of it).
- While ReviewDesk opens, the sidebar shows "Loading pull requests…" instead of an empty list or "No pull requests", and a spinner replaces the toolbar's Refresh button whenever the list is being fetched.
- Refreshing while ReviewDesk is still connecting to GitHub no longer leads to a wrong "Your review was requested" notification for each pull request awaiting your review: refreshes wait until your GitHub account is known.
- **Collapse the conversation:** each card in the Conversation tab (the description, comments and reviews) has a chevron that folds it to its header, and *Collapse All* / *Expand All* folds or unfolds them all at once.
- **Linked commits and PRs:** commit SHAs, `#123`, `GH-123`, `owner/repo#123`, `owner/repo@sha` and GitHub URLs in descriptions, comments and AI text are links, as on GitHub (not inside code). A PR ReviewDesk follows opens in the app; anything else opens on GitHub. The header shows the head commit's short SHA.
- **Inline threads in Conversation:** the Conversation tab shows every inline review thread under the review that started it, with its file, the diff lines above it, a *Show in Changes* link and the usual reply, resolve and Explain actions. Resolved and outdated threads start folded, and *Collapse All* folds threads too. A filter on top shows *All*, *Started by Me* (threads, comments and reviews you started) or *Unresolved*, and is remembered.
- **What's New before you update:** *What's New* on the update banner, in *Check for Updates…* and in Settings › Updates lists the changes of every version since yours, newest first with their release dates, with the install button and *Later*.
- **What's New after an update:** the first launch of a new version lists what changed since the version you had, from the notes bundled in the app (so it works offline). A fresh install doesn't show it; *Help › What's New* reopens this version's notes.
- **Involving Me in Conversation:** the Conversation tab's filter has an *Involving Me* option, like the one in Changes: only the threads you started, replied in or were @mentioned in, under their reviews, plus your own comments and reviews and those that mention you.
- **Faster first open:** the pull request list is kept on disk, so the sidebar shows it as soon as ReviewDesk opens (the footer says how old it is), and the first refresh only fetches the pull requests that changed since.
- **To Review and My PRs:** the sidebar's Inbox is split in two. *To Review* lists other people's pull requests; *My PRs* lists yours, and each shows the reviews others left on it (how many approved, asked for changes or commented; hover for who).
- **Outdated AI analysis is obvious:** when the author pushes after an AI review, AI Review, Risk and Changes show one banner ("The author pushed 3 commits since this analysis") with *Re-run* (same engine, model and effort) and *Show Changes Since* (GitHub's comparison). The sidebar row gets orange sparkles, the header an *AI analysis outdated* badge, and key areas in the diff are dimmed.

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
