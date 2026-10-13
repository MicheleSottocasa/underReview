# Changelog

ReviewDesk is a beta preview: there is no stable release yet. Each version below is a preview build.
Add a `## <version>` section here before tagging a release: the release workflow publishes it as the release's description.

## Unreleased

- AI rationales and key-area reasons show `code` and **bold** formatting instead of raw Markdown.
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
