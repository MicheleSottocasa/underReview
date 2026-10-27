import Foundation

/// A realistic two-PR stack with comments, diffs and AI analyses, for the onboarding tour and previews.
/// Ids start with `DEMO_` (GitHub node ids never do) and the repo is fictional, so nothing can collide with
/// real data; the app never sends the demo to GitHub or an AI provider, and never saves it.
public enum Demo {
    public static let idPrefix = "DEMO_"
    public static let repo = "reviewdesk-demo/storefront"
    /// The PR the tour walks through: the top of the stack.
    public static let mainID = "DEMO_PR_42"
    public static let baseID = "DEMO_PR_41"
    static let head = "demo003", oldHead = "demo002", baseHead = "demo102", baseReviewed = "demo101"

    /// GitHub logins can't contain dots, so these can't be real people (and no avatar is fetched for them).
    public static let viewer = "you.demo"

    /// True for anything the demo owns: its PR ids, item keys and note keys.
    public static func owns(_ key: String) -> Bool {
        key.contains(idPrefix) || key.contains(repo)
    }

    private static func ago(_ hours: Double) -> Date { Date(timeIntervalSinceNow: -hours * 3600) }

    private static let stack = StackInfo(number: 7, entries: [
        .init(position: 1, id: baseID, number: 41),
        .init(position: 2, id: mainID, number: 42),
    ])

    public static var pullRequests: [PullRequest] {
        var base = PullRequest(
            id: baseID, number: 41, title: "Add the invites table", url: "", state: "OPEN", isDraft: false,
            updatedAt: ago(5), headRefOid: baseHead, headRefName: "invites-table", baseRefName: "main", author: "lena.demo",
            repo: repo, commentCount: 1, reviewCount: 1, threadCommentCount: 0, requestedReviewers: [], stack: stack)
        // Reviewed earlier, then the author pushed and replied: shows "changed since your review" and the follow-up check.
        base.viewerReviewState = "CHANGES_REQUESTED"
        base.viewerReviewedOid = baseReviewed
        base.threadsAwaitingReply = 2 // the author answered both of the viewer's threads
        var main = PullRequest(
            id: mainID, number: 42, title: "Let organisation admins invite members", url: "", state: "OPEN", isDraft: false,
            updatedAt: ago(1), headRefOid: head, headRefName: "invite-members", baseRefName: "invites-table", author: "marco.demo",
            repo: repo, commentCount: 1, reviewCount: 1, threadCommentCount: 4, requestedReviewers: [viewer], stack: stack)
        // Totals match the demo files, as GitHub's would.
        for index in [0, 1] {
            let changes = files[[baseID, mainID][index]] ?? []
            let totals = (changes.reduce(0) { $0 + $1.additions }, changes.reduce(0) { $0 + $1.deletions }, changes.count)
            if index == 0 { (base.additions, base.deletions, base.changedFiles) = totals } else { (main.additions, main.deletions, main.changedFiles) = totals }
        }
        // Shows the merge badges: #41 is behind main, and #42 conflicts with #41's branch.
        (base.mergeable, base.mergeStateStatus) = ("MERGEABLE", "BEHIND")
        (main.mergeable, main.mergeStateStatus) = ("CONFLICTING", "DIRTY")
        return [base, main]
    }

    public static var details: [String: PRDetail] {
        [
            baseID: PRDetail(
                body: "Adds the `Invite` model and its table. The endpoints come in #42.",
                comments: [Comment(id: "DEMO_IC_1", author: "marco.demo", body: "Thanks! #42 builds on this.", createdAt: ago(6))],
                reviews: [Review(id: "DEMO_R_1", author: viewer, state: "CHANGES_REQUESTED", body: "Two questions inline.", submittedAt: ago(8))],
                threads: [
                    ReviewThread(id: "DEMO_T_3", path: "app/invites/models.py", line: 6, side: .right, isResolved: false, isOutdated: false, comments: [
                        Comment(id: "DEMO_C_5", author: viewer, body: "Should an email be unique per organisation? Otherwise the same person can be invited twice.", createdAt: ago(8), kind: .review, reviewID: "DEMO_R_1"),
                        Comment(id: "DEMO_C_6", author: "lena.demo", body: "Yes: #42 adds a unique constraint on (organization, email) in its migration.", createdAt: ago(5), kind: .review),
                    ], viewerCanResolve: true, diffHunk: hunk(baseID, "app/invites/models.py", 6)),
                    ReviewThread(id: "DEMO_T_4", path: "app/invites/models.py", line: 13, side: .right, isResolved: false, isOutdated: false, comments: [
                        Comment(id: "DEMO_C_7", author: viewer, body: "`timezone` isn't imported here.", createdAt: ago(8), kind: .review, reviewID: "DEMO_R_1"),
                        Comment(id: "DEMO_C_8", author: "lena.demo", body: "I'd rather leave it: a later PR moves `mark_sent` into the task anyway.", createdAt: ago(5), kind: .review),
                    ], viewerCanResolve: true, diffHunk: hunk(baseID, "app/invites/models.py", 13)),
                ],
                pendingReview: nil,
                reviewDecision: "CHANGES_REQUESTED",
                latestReviews: [Review(id: "DEMO_R_1", author: viewer, state: "CHANGES_REQUESTED", body: "", submittedAt: ago(8), commitOID: baseReviewed)]),
            mainID: PRDetail(
                body: """
                Lets organisation admins invite members by email. Builds on #41 (the invites table).

                ## Risk notes
                - **Data changes:** a new `sent_at` column and a unique constraint on (organization, email).
                - **Permission impact:** only admins should invite; see `create_invite`.
                - **Performance concerns:** none expected.
                - **Failure handling:** the email task retries 3 times and skips invites already sent.
                - **Anything I'm unsure about:** whether the unique constraint can fail on existing duplicate invites.
                """,
                comments: [Comment(id: "DEMO_IC_2", author: "lena.demo", body: "Looks good overall, two questions inline.", createdAt: ago(3))],
                reviews: [Review(id: "DEMO_R_2", author: "lena.demo", state: "COMMENTED", body: "Left a couple of questions.", submittedAt: ago(3))],
                threads: [
                    ReviewThread(id: "DEMO_T_1", path: "app/invites/views.py", line: 21, side: .right, isResolved: false, isOutdated: false, comments: [
                        Comment(id: "DEMO_C_1", author: "lena.demo", body: "Shouldn't this check that `request.user` is an admin of the organisation? Right now anyone can invite to any organisation.", createdAt: ago(3), kind: .review, reviewID: "DEMO_R_2"),
                        Comment(id: "DEMO_C_2", author: "marco.demo", body: "Good catch: the check was on the old view. I'll add it back.", createdAt: ago(2), kind: .review),
                    ], diffHunk: hunk(mainID, "app/invites/views.py", 21)),
                    ReviewThread(id: "DEMO_T_2", path: "app/invites/tasks.py", line: 11, side: .right, isResolved: true, isOutdated: false, comments: [
                        Comment(id: "DEMO_C_3", author: "lena.demo", body: "Could a retry send the email twice?", createdAt: ago(3), kind: .review, reviewID: "DEMO_R_2"),
                        Comment(id: "DEMO_C_4", author: "marco.demo", body: "Not anymore: it returns early once `sent_at` is set.", createdAt: ago(2), kind: .review),
                    ], resolvedBy: "lena.demo", diffHunk: hunk(mainID, "app/invites/tasks.py", 11)),
                ],
                pendingReview: nil,
                reviewDecision: "REVIEW_REQUIRED",
                latestReviews: [Review(id: "DEMO_R_2", author: "lena.demo", state: "COMMENTED", body: "", submittedAt: ago(3), commitOID: oldHead)]),
        ]
    }

    /// What GitHub's `diffHunk` holds: the file's patch up to the commented line.
    static func hunk(_ prID: String, _ path: String, _ line: Int) -> String {
        let lines = Diff.parse(files[prID]?.first { $0.filename == path }?.patch ?? "")
        return lines.prefix((lines.firstIndex { $0.newLine == line } ?? lines.count) + 1).map { line in
            switch line.kind {
            case .hunk: line.text
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            }
        }.joined(separator: "\n")
    }

    public static var files: [String: [FileChange]] {
        [
            baseID: [
                FileChange(filename: "app/invites/models.py", status: "added", additions: 13, deletions: 0, patch: """
                @@ -0,0 +1,13 @@
                +from django.db import models
                +
                +
                +class Invite(models.Model):
                +    organization = models.ForeignKey("orgs.Organization", on_delete=models.CASCADE)
                +    email = models.EmailField()
                +    created_at = models.DateTimeField(auto_now_add=True)
                +
                +    def as_json(self):
                +        return {"id": self.id, "email": self.email}
                +
                +    def mark_sent(self):
                +        Invite.objects.filter(id=self.id).update(sent_at=timezone.now())
                """),
            ],
            mainID: [
                FileChange(filename: "app/invites/views.py", status: "modified", additions: 15, deletions: 4, patch: """
                @@ -1,15 +1,26 @@
                 from django.http import JsonResponse
                +from django.views.decorators.http import require_POST
                \u{20}
                 from .models import Invite, Organization
                +from .tasks import send_invite_email
                \u{20}
                \u{20}
                 def list_invites(request, org_id):
                     org = Organization.objects.get(id=org_id, members=request.user)
                     invites = Invite.objects.filter(organization=org)
                     return JsonResponse({"invites": [i.as_json() for i in invites]})
                \u{20}
                \u{20}
                -def create_invite(request, org_id):
                -    org = Organization.objects.get(id=org_id)
                -    invite = Invite.objects.create(organization=org, email=request.POST["email"])
                -    return JsonResponse(invite.as_json(), status=201)
                +@require_POST
                +def create_invite(request, org_id):
                +    \"\"\"
                +    Invite someone to an organisation by email.
                +
                +    Only admins can invite; the email is sent in the background.
                +    \"\"\"
                +    org = Organization.objects.get(id=org_id)
                +    email = request.POST["email"].strip().lower()
                +    invite, created = Invite.objects.get_or_create(organization=org, email=email)
                +    if created:
                +        send_invite_email.delay(invite.id)
                +    return JsonResponse(invite.as_json(), status=201 if created else 200)
                """),
                FileChange(filename: "app/invites/tasks.py", status: "modified", additions: 11, deletions: 3, patch: """
                @@ -1,9 +1,17 @@
                 from celery import shared_task
                +from django.db import transaction
                \u{20}
                 from .models import Invite
                \u{20}
                \u{20}
                -@shared_task
                -def send_invite_email(invite_id):
                +@shared_task(bind=True, max_retries=3, default_retry_delay=60)
                +def send_invite_email(self, invite_id):
                     invite = Invite.objects.get(id=invite_id)
                -    mailer.send(invite.email, template="invite")
                +    if invite.sent_at:
                +        return  # already sent: a retry must not email twice
                +    try:
                +        mailer.send(invite.email, template="invite")
                +    except mailer.TemporaryError as error:
                +        raise self.retry(exc=error)
                +    with transaction.atomic():
                +        invite.mark_sent()
                """),
                FileChange(filename: "app/invites/migrations/0003_invite_sent_at.py", status: "added", additions: 19, deletions: 0, patch: """
                @@ -0,0 +1,19 @@
                +from django.db import migrations, models
                +
                +
                +class Migration(migrations.Migration):
                +    dependencies = [("invites", "0002_invite")]
                +
                +    operations = [
                +        migrations.AddField(
                +            model_name="invite",
                +            name="sent_at",
                +            field=models.DateTimeField(null=True),
                +        ),
                +        migrations.AddConstraint(
                +            model_name="invite",
                +            constraint=models.UniqueConstraint(
                +                fields=["organization", "email"], name="unique_invite_per_org"
                +            ),
                +        ),
                +    ]
                """),
                FileChange(filename: "app/invites/legacy_tokens.py", status: "removed", additions: 0, deletions: 8, patch: """
                @@ -1,8 +0,0 @@
                -import secrets
                -
                -
                -def make_token():
                -    return secrets.token_hex(8)
                -
                -
                -TOKEN_TTL_DAYS = 7
                """),
            ],
        ]
    }

    /// Files already marked as viewed.
    public static let viewedFiles: [String: Set<String>] = [mainID: ["app/invites/legacy_tokens.py"]]

    /// A local draft the viewer hasn't sent yet.
    public static var drafts: [Draft] {
        [Draft(prID: mainID, anchor: Anchor(path: "app/invites/tasks.py", line: 14), body: "Should a retry be logged, so failed invites are easy to find?", commitOID: head)]
    }

    /// A follow-up check on the base PR: one request handled, one pushed back.
    public static var followUps: [FollowUpRun] {
        var run = FollowUpRun(prID: baseID, engine: .claudeCode, headRefOid: baseHead, reviewedOid: baseReviewed, result: FollowUpResult(
            summary: "One request is handled; the missing `timezone` import was pushed back, and the code still fails without it.",
            items: [
                FollowUpItem(threadID: "DEMO_T_3", request: "Make invites unique per organisation", status: "addressed",
                             explanation: "#42's migration adds `unique_invite_per_org` on (organization, email), and `create_invite` uses `get_or_create`."),
                FollowUpItem(threadID: "DEMO_T_4", request: "Import `timezone` in models.py", status: "disputed",
                             explanation: "The author wants to leave it for a later PR, but `mark_sent` calls `timezone.now()` in this one, so it raises `NameError` until then."),
            ]))
        run.usage = TokenUsage(input: 3, output: 640, cacheRead: 2_590, cacheWrite: 1_480, listPriceUSD: 0.02)
        run.date = ago(0.2)
        return [run]
    }

    /// A current analysis and one from before the last push (shown as outdated).
    public static var runs: [AIRun] {
        var current = AIRun(prID: mainID, engine: .claudeCode, headRefOid: head, result: ReviewResult(
            summary: "One real problem: `create_invite` lets any signed-in user invite to any organisation. The migration's unique constraint can fail on existing duplicates; the email task is otherwise safe to retry.",
            findings: [
                Finding(severity: "high", title: "Anyone can invite to any organisation",
                        rationale: "`create_invite` loads the organisation by id without checking that the user is one of its admins, unlike `list_invites`.",
                        path: "app/invites/views.py", line: 21,
                        comment: "This loads the organisation without checking membership. Could we scope it like `list_invites` and require an admin?",
                        suggestion: "    org = Organization.objects.get(id=org_id, admins=request.user)"),
                Finding(severity: "medium", title: "Unique constraint can fail on existing duplicates",
                        rationale: "Adding `unique_invite_per_org` fails if the table already holds two invites for the same email in one organisation.",
                        path: "app/invites/migrations/0003_invite_sent_at.py", line: 14,
                        comment: "If production already has duplicate invites, this migration will fail. Should we deduplicate first in a data migration?"),
                Finding(severity: "low", title: "`mailer` isn't imported", rationale: "`tasks.py` uses `mailer` but never imports it.",
                        path: "app/invites/tasks.py", line: 13, comment: "`mailer` isn't imported in this module, so the task fails at runtime."),
            ],
            keyAreas: [
                KeyArea(path: "app/invites/migrations/0003_invite_sent_at.py", startLine: 13, endLine: 18,
                        reason: "The unique constraint must not fail on existing duplicate invites.", risk: "data"),
                KeyArea(path: "app/invites/views.py", startLine: 14, endLine: 26,
                        reason: "Check who may call `create_invite`: the organisation isn't scoped to the user.", risk: "access"),
                KeyArea(path: "app/invites/tasks.py", startLine: 10, endLine: 17,
                        reason: "Retries must stay idempotent: the early return and `mark_sent` guard against double emails.", risk: "failure"),
            ],
            risks: [
                RiskAssessment(question: "data", level: "medium", answer: "Adds `sent_at` and a unique constraint on (organization, email) in `0003_invite_sent_at.py`; existing duplicates would make it fail."),
                RiskAssessment(question: "access", level: "high", answer: "`create_invite` in `views.py` fetches the organisation by id only: any signed-in user can invite to any organisation."),
                RiskAssessment(question: "scale", level: "low", answer: "`get_or_create` on the (organization, email) pair is backed by the new unique index."),
                RiskAssessment(question: "failure", level: "low", answer: "The task retries 3 times and returns early once `sent_at` is set, so retries don't email twice."),
                RiskAssessment(question: "explain", level: "none", answer: "A small, conventional change; nothing needs explaining."),
            ]))
        current.date = ago(0.5)
        current.options = CodeReviewOptions(model: "", effort: "high")
        // Sample usage, so the run card shows what a review used (in line with a measured high-effort run).
        current.usage = TokenUsage(input: 24, output: 9_800, cacheRead: 98_400, cacheWrite: 4_100, listPriceUSD: 0.31, passes: 2)
        current.estimatedTokens = 1_900
        var old = AIRun(prID: mainID, engine: .claudeCode, headRefOid: oldHead, result: ReviewResult(
            summary: "The email task can send an invite twice when it retries.",
            findings: [Finding(severity: "medium", title: "Retries can email twice", rationale: "The task doesn't record that the email went out.",
                               path: "app/invites/tasks.py", line: 9, comment: "A retry after a timeout would send the invite again.")]))
        old.date = ago(4)
        // The base PR's only analysis predates its last push: its banner, sidebar icon and header badge show it.
        var base = AIRun(prID: baseID, engine: .claudeCode, headRefOid: baseReviewed, result: ReviewResult(
            summary: "Invites aren't unique per organisation yet, so the same email can be invited twice.",
            findings: [Finding(severity: "medium", title: "Duplicate invites", rationale: "Nothing stops two invites for one email in one organisation.",
                               path: "app/invites/models.py", line: 6, comment: "Could invites be unique per organisation?")],
            keyAreas: [KeyArea(path: "app/invites/models.py", startLine: 1, endLine: 13, reason: "The invite model: check what keeps invites unique.", risk: "data")],
            risks: [RiskAssessment(question: "data", level: "medium", answer: "Adds the `Invite` table in `models.py` without a uniqueness constraint.")]))
        base.date = ago(6)
        base.options = CodeReviewOptions(model: "", effort: "high")
        return [current, old, base]
    }
}

extension PullRequest {
    /// Part of the onboarding demo: never sent to GitHub or an AI provider, never saved.
    public var isDemo: Bool { id.hasPrefix(Demo.idPrefix) }
}

extension Organization {
    /// The organization without any demo item keys, notes or ids: what may be saved.
    public func removingDemo() -> Organization {
        var clean = self
        clean.placements = placements.filter { !Demo.owns($0.key) }
        clean.followed = followed.filter { !Demo.owns($0.key) }
        clean.unfollowed = unfollowed.filter { !Demo.owns($0) }
        clean.notes = notes.filter { !Demo.owns($0.key) }
        clean.muted = muted.filter { !Demo.owns($0) }
        return clean
    }
}

extension PRArchive {
    /// The archive without the demo's item keys: what may be saved.
    public func removingDemo() -> PRArchive {
        var clean = self
        clean.manual = manual.filter { !Demo.owns($0.key) }
        clean.kept = kept.filter { !Demo.owns($0) }
        return clean
    }
}
