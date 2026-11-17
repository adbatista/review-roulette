# Review roulette

A GitHub Action that picks the least-loaded reviewer from an explicit list, per-project owners, `CODEOWNERS` or GitHub's native PR-specific suggestions, posts one managed comment, and optionally requests review. It also runs on issues, where it suggests or sets an assignee.

**Workload = outstanding personal review requests on open PRs**, not PR assignees or submitted reviews. Optionally, open issues assigned to a reviewer in other repositories add to it, weighted by their project board status. The PR author is excluded. Minimum-count ties are random.

## Quick start

Replace `OWNER/review-roulette@<commit-sha>` with this action's published repository and a trusted commit SHA. Consumers need no checkout or dependency installation.

```yaml
name: Review roulette
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
permissions:
  pull-requests: write
concurrency:
  group: review-roulette-${{ github.repository }}
  cancel-in-progress: false
jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: OWNER/review-roulette@<commit-sha>
        id: roulette
        with:
          reviewers: |
            alice
            bob
            carol
          # Suggestion-only is the default.
          # assign-reviewer: 'true'
```

Both modes write a PR conversation comment and need `pull-requests: write`. Assignment is additive: it requests the chosen user's review without removing existing reviewers. GitHub enforces reviewer eligibility when the request is made; suggestion mode does **not** prove the user can review the repository.

## Inputs

| Input                | Default               | Meaning                                                                                                 |
| -------------------- | --------------------- | ------------------------------------------------------------------------------------------------------- |
| `token`              | `${{ github.token }}` | Token used for all API operations.                                                                      |
| `reviewers`          | Empty                 | Comma- or newline-separated user logins; optional leading `@`. Empty uses GitHub's suggested reviewers. |
| `organizations`      | Empty                 | Organizations whose visible workloads are summed, **instead of** repository scope.                      |
| `assign-reviewer`    | `false`               | Set to `true` to request review as well as suggest it.                                                  |
| `issue-repositories` | Empty                 | Owners or `owner/repo` names whose open issues assigned to a reviewer add to their workload.            |
| `status-field`       | `Status`              | Single-select project field read as an issue's status.                                                  |
| `status-weights`     | Empty                 | One `Status name: weight` per line. Empty counts every assigned issue as 1.                             |
| `projects`           | Empty                 | One `name \| patterns \| owners` per line; each matched project gets its own pick.                      |
| `codeowners`         | `false`               | Also pick among the `CODEOWNERS` of the changed files.                                                  |
| `command`            | Empty                 | Comment line that triggers the action on `issue_comment` events, such as `/roulette`.                   |
| `required-label`     | Empty                 | Run only when the pull request or issue carries this label.                                             |

Lists are trimmed, validated, and deduplicated case-insensitively. Boolean inputs accept only `true` or `false`.

### Automatic reviewer discovery

Omit `reviewers` (or leave it empty) to use GitHub's native suggested reviewers for the target PR through GraphQL `PullRequest.suggestedReviewers`. GitHub bases these suggestions on commit history and past review comments; they are not a list of recently active contributors.

An explicit reviewer list takes precedence. In either mode, the action excludes the PR author and balances outstanding review requests across the remaining candidates. If no eligible candidates remain, the action fails before requesting a review or publishing a comment. API failures also fail the run rather than falling back to unrelated contributors.

### Multiple organizations and assignment

```yaml
- uses: OWNER/review-roulette@<commit-sha>
  with:
    token: ${{ secrets.REVIEW_ROULETTE_TOKEN }}
    reviewers: alice, bob, carol
    organizations: |
      acme
      acme-labs
    assign-reviewer: "true"
```

`GITHUB_TOKEN` is repository-scoped. Use a GitHub App installation token or PAT with access to the relevant repositories for broader counts. The token needs read access for PR workloads and write access to the target PR. Fine-grained tokens/App installations need repository **Pull requests: read** on workload repositories and **Pull requests: write** on the target; classic PATs need appropriate `repo` access for private repositories. The action resolves its authenticated comment identity through GraphQL `viewer`, including installation-token bot identities; it does not require installation tokens to support REST `/user`.

Repository and organization lookups check scope accessibility, **not full private-repository visibility or write permission**. Organization counts reflect only repositories visible to the supplied token. A successful lookup cannot establish complete organization coverage. An inaccessible configured scope or failed/partial search fails the run instead of silently lowering a reviewer's workload.

### Assigned issues and project status

```yaml
- uses: OWNER/review-roulette@<commit-sha>
  with:
    token: ${{ secrets.REVIEW_ROULETTE_TOKEN }}
    reviewers: alice, bob, carol
    issue-repositories: |
      acme/tasks
      acme-labs
    status-weights: |
      In progress: 3
      Todo: 1
      Done: 0
      *: 1
```

Each candidate's workload becomes their pending review requests **plus** their issue load: the open issues assigned to them in the listed repositories (`owner/repo`) or across a whole owner (`owner`).

- Without `status-weights`, every assigned open issue counts 1 and no project data is read.
- With `status-weights`, each issue counts the weight of its status in the `status-field` of its GitHub Projects. Status names match case-insensitively and weights are non-negative integers.
- `*` is the weight for an unlisted status and for issues on no project; it defaults to 1.
- An issue on several projects counts once, at its heaviest status. Archived project items are ignored.

Reading project status needs a token that can read the projects: a classic PAT with `read:project`, or a GitHub App with organization **Projects: read**. `GITHUB_TOKEN` cannot read organization projects or other repositories. A status that cannot be read fails the run instead of lowering the load.

### Projects and owners

```yaml
- uses: OWNER/review-roulette@<commit-sha>
  with:
    reviewers: alice, bob, carol
    projects: |
      web      | packages/web/**, packages/ui/** | alice, bob
      api      | acme/mono:services/api/**       | carol, dave
      docs     | acme/docs:                      | erin
      security |                                 | frank, grace
    codeowners: "true"
```

Each line is `name | patterns | owners`. A project matches the PR when a changed file matches one of its patterns, or when the PR carries a label equal to the project name. Every matched project gets its own row and its own least-loaded pick among its owners.

| Pattern                             | Matches                                               |
| ----------------------------------- | ----------------------------------------------------- |
| `packages/web/**` or `packages/web` | That folder, in whichever repository the action runs. |
| `acme/mono:services/api/**`         | That folder, only in `acme/mono`.                     |
| `acme/docs:`                        | Every PR in `acme/docs`.                              |
| (empty)                             | Nothing by path; the project matches by label only.   |

Globs support `*` (within one path segment), `**` (across segments) and `?`. The same `projects` value can be shared across repositories, for example through an organization variable.

With `codeowners: "true"`, the action reads `CODEOWNERS` from the PR's base branch (`.github/`, the root, then `docs/`) and adds a `Code owners` row picked among the owners of the changed files. Teams are expanded to their members and email owners are ignored. This needs `contents: read`, and team owners need a token that can read the organization's team members, which `GITHUB_TOKEN` cannot.

When no project or code owner applies, or the PR author is the only owner, the action falls back to `reviewers` (or GitHub's suggestions) in a single `All` row. The same person can be picked for several rows and is requested once.

## Comment command, labels and issues

```yaml
name: Review roulette
on:
  issue_comment:
    types: [created]
  issues:
    types: [labeled]
permissions:
  issues: write
  pull-requests: write
jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: OWNER/review-roulette@<commit-sha>
        with:
          reviewers: alice, bob, carol
          command: /roulette
          required-label: needs-owner
          assign-reviewer: "true"
```

- **Command**: on `issue_comment` events the action runs only when a line of a newly created comment is exactly `command`, and the commenter is a repository owner, member or collaborator. Anything else is skipped successfully. `command` is required for these events, because under a PAT or App token the action's own comment would otherwise retrigger it. On other events `command` is ignored, so one workflow can serve both.
- **Label**: with `required-label`, the action runs only when the pull request or issue currently carries that label, compared case-insensitively. Otherwise it is skipped.
- **Issues**: on a plain issue the action suggests an assignee, and with `assign-reviewer: "true"` assigns them, which needs `issues: write`. An issue has no changed files, so a project matches it by label or by a whole-repository pattern (`owner/repo:`), `codeowners` does not apply, and GitHub's suggestions are unavailable: without a matching project, `reviewers` is required. The issue author stays eligible. Someone already assigned is not assigned again.

`issue_comment` workflows run from the default branch with a write-capable token even when the comment is on a fork's pull request, so never check out or execute PR-head code in them.

## Fork pull requests

Fork `pull_request` workflows commonly receive read-only tokens, so comment/review-request writes can fail. For forks, use a metadata-only `pull_request_target` workflow:

```yaml
name: Review roulette
on:
  pull_request_target:
    types: [opened, reopened, ready_for_review]
permissions:
  pull-requests: write
concurrency:
  group: review-roulette-${{ github.repository }}
  cancel-in-progress: false
jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: OWNER/review-roulette@<commit-sha>
        with:
          reviewers: alice, bob, carol
          assign-reviewer: "true"
```

**Never check out or execute PR-head code in this privileged workflow.** Use trusted, pinned action code. Reviewer discovery uses GitHub API metadata only. The action uses the PR's base repository, never the fork's head repository. Dependabot PRs may also have token/secret restrictions; repository policy still applies.

## Comment and outputs

The comment shows one selected reviewer per category:

| Category | Suggested reviewer                 | Status           |
| -------- | ---------------------------------- | ---------------- |
| web      | @alice — 2 pending review requests | Review requested |
| api      | @carol — 0 pending review requests | Suggestion only  |

The status says suggestion-only, review requested, or review already requested. The count is captured **before** a new request in that run.

| Output         | Meaning                                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------------------- |
| `reviewer`     | Selected login; the first category's pick when several are made.                                          |
| `reviewers`    | Comma-separated unique logins selected across all categories.                                             |
| `review-count` | Outstanding request count at selection time.                                                              |
| `issue-load`   | Weighted assigned issues of the selected reviewer; empty without `issue-repositories`.                    |
| `workload`     | Request count plus issue load, the number used for selection.                                             |
| `assigned`     | `true` only if this run successfully created a review request; otherwise `false`.                         |
| `skipped`      | `true` when the command or required label was missing and nothing was done; other outputs are then unset. |

Outputs are published only after successful comment publication. API failures fail the action. If assignment succeeds but commenting fails, the request stays in place and the run fails; no rollback is attempted.

### Reruns

The action updates its earliest valid, identity-owned managed comment. A copied marker in someone else's comment is not editable. Preserve its hidden marker to retain selection history.

Each category remembers its own pick:

- Keep a prior selected reviewer who is still in the current candidate pool, is not the author, and has an outstanding request on this PR—even if their count is now higher.
- Otherwise retain a prior suggestion only while it shares the minimum count.
- Never request the chosen reviewer again if they are already requested, even without a prior comment.
- Changing token identity can result in a new managed comment. Concurrent runs or manually duplicated owned comments are not consolidated automatically.
