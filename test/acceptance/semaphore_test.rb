# frozen_string_literal: true

require_relative "acceptance_helper"

class SemaphoreAcceptanceTest < AcceptanceTest
  def setup
    super
    github.add_pull(7, author: "author")
    github.pending_reviews(alice: 1, bob: 3, carol: 2)
  end

  def test_suggests_the_least_loaded_reviewer_without_requesting_a_review
    output_file = File.join(dir, "outputs.env")
    result = semaphore("ROULETTE_REVIEWERS" => "bob, alice, carol", "ROULETTE_OUTPUT_FILE" => output_file)

    assert result.success?, result.stderr
    assert_includes comment_body, "### Review roulette"
    assert_includes comment_body,
                    "| All | [@alice](https://github.com/alice) — 1 pending review request | Suggestion only |"
    assert_empty github.review_requests
    assert_equal({ "skipped" => "false", "reviewer" => "alice", "reviewers" => "alice", "review-count" => "1",
                   "issue-load" => "", "workload" => "1", "assigned" => "false" }, result.outputs)
    assert_includes File.read(output_file), "ROULETTE_REVIEWER=alice\n"
  end

  def test_requests_the_review_when_assignment_is_enabled
    result = semaphore("ROULETTE_REVIEWERS" => "alice, bob", "ROULETTE_ASSIGN_REVIEWER" => "true")

    assert result.success?, result.stderr
    assert_equal ["alice"], github.review_requests
    assert_includes comment_body, "| Review requested |"
    assert_equal "true", result.outputs["assigned"]
  end

  def test_never_picks_the_pull_request_author
    github.add_pull(7, author: "Alice")

    result = semaphore("ROULETTE_REVIEWERS" => "alice, carol")

    assert_equal "carol", result.outputs["reviewer"]
  end

  def test_uses_github_suggestions_when_no_reviewers_are_listed
    github.suggested_reviewers = %w[bob carol]

    result = semaphore

    assert_equal "carol", result.outputs["reviewer"]
  end

  def test_rerun_updates_its_comment_and_keeps_an_already_requested_reviewer
    semaphore("ROULETTE_REVIEWERS" => "alice, bob", "ROULETTE_ASSIGN_REVIEWER" => "true")
    github.pending_reviews(alice: 9)

    result = semaphore("ROULETTE_REVIEWERS" => "alice, bob", "ROULETTE_ASSIGN_REVIEWER" => "true")

    assert_equal "alice", result.outputs["reviewer"]
    assert_equal "false", result.outputs["assigned"]
    assert_equal ["alice"], github.review_requests
    assert_includes comment_body, "9 pending review requests | Review already requested |"
  end

  def test_rerun_replaces_a_suggestion_that_is_no_longer_least_loaded
    semaphore("ROULETTE_REVIEWERS" => "alice, bob")
    github.pending_reviews(alice: 9)

    result = semaphore("ROULETTE_REVIEWERS" => "alice, bob")

    assert_equal "bob", result.outputs["reviewer"]
    assert_includes comment_body, "[@bob]"
  end

  def test_ignores_a_marker_copied_into_someone_elses_comment
    github.add_comment("<!-- review-roulette:v2:All=bob -->", author: "mallory")

    result = semaphore("ROULETTE_REVIEWERS" => "alice, bob")

    assert_equal "alice", result.outputs["reviewer"]
    assert_equal 2, github.comments.size
  end

  def test_adds_assigned_issues_weighted_by_project_status
    github.add_repository("acme/tasks")
    github.assign_issue("alice", repo: "acme/tasks", projects: [{ "Status" => "In progress" }])
    github.assign_issue("alice", repo: "acme/tasks", projects: [{ "Status" => "Done" }])
    github.assign_issue("alice", repo: "acme/tasks")
    github.assign_issue("carol", repo: "acme/tasks", projects: [{ "Status" => "Done" }])

    result = semaphore(
      "ROULETTE_REVIEWERS" => "alice, carol",
      "ROULETTE_ISSUE_REPOSITORIES" => "acme/tasks",
      "ROULETTE_STATUS_WEIGHTS" => "In progress: 3\nDone: 0"
    )

    assert result.success?, result.stderr
    assert_equal "carol", result.outputs["reviewer"]
    assert_equal "0", result.outputs["issue-load"]
    assert_equal "2", result.outputs["workload"]
    assert_includes comment_body,
                    "[@carol](https://github.com/carol) — 2 pending review requests, assigned issue load 0 |"
  end

  def test_counts_every_assigned_issue_once_without_status_weights
    github.add_owner("acme")
    2.times { github.assign_issue("alice", repo: "acme/tasks") }

    result = semaphore("ROULETTE_REVIEWERS" => "alice, carol", "ROULETTE_ISSUE_REPOSITORIES" => "acme")

    assert_equal "carol", result.outputs["reviewer"]
    assert_equal "0", result.outputs["issue-load"]
  end

  def test_picks_one_owner_per_matched_project_from_a_config_file
    github.add_pull(7, author: "author", files: ["packages/web/app.ts", "services/api/main.go"])
    config = write("roulette.json", JSON.generate(
                                      "reviewers" => %w[alice bob carol],
                                      "assign-reviewer" => true,
                                      "projects" => ["web | packages/web/** | bob, carol",
                                                     "api | acme/mono:services/api | alice, bob",
                                                     "docs | docs/** | alice"]
                                    ))

    result = semaphore("ROULETTE_CONFIG" => config)

    assert result.success?, result.stderr
    assert_includes comment_body,
                    "| web | [@carol](https://github.com/carol) — 2 pending review requests | Review requested |"
    assert_includes comment_body,
                    "| api | [@alice](https://github.com/alice) — 1 pending review request | Review requested |"
    refute_includes comment_body, "| docs |"
    assert_equal %w[carol alice], github.review_requests
    assert_equal "carol", result.outputs["reviewer"]
    assert_equal "carol,alice", result.outputs["reviewers"]
  end

  def test_matches_a_project_by_label
    github.add_pull(7, author: "author", labels: ["Security"])

    result = semaphore("ROULETTE_REVIEWERS" => "alice", "ROULETTE_PROJECTS" => "security | | bob, carol")

    assert_includes comment_body, "| security | [@carol]"
    assert_equal "carol", result.outputs["reviewer"]
  end

  def test_adds_a_code_owners_row_and_expands_teams
    github.add_pull(7, author: "author", files: ["packages/web/app.ts"], base_ref: "release")
    github.codeowners = "* @alice\n/packages/ @acme/web-team\n"
    github.add_team("web-team", %w[bob carol])

    result = semaphore("ROULETTE_REVIEWERS" => "alice", "ROULETTE_CODEOWNERS" => "true")

    assert result.success?, result.stderr
    assert_includes comment_body, "| Code owners | [@carol]"
  end

  def test_skips_a_target_without_the_required_label
    result = semaphore("ROULETTE_REVIEWERS" => "alice", "ROULETTE_REQUIRED_LABEL" => "needs-review")

    assert result.success?, result.stderr
    assert_equal({ "skipped" => "true" }, result.outputs)
    assert_empty github.comments
  end

  def test_skips_builds_that_are_not_for_a_pull_request
    result = semaphore("SEMAPHORE_GIT_PR_NUMBER" => nil, "ROULETTE_REVIEWERS" => "alice")

    assert result.success?, result.stderr
    assert_equal({ "skipped" => "true" }, result.outputs)
    assert_empty github.requests
  end

  def test_assigns_an_issue_to_the_owner_of_its_labelled_project
    github.add_issue(12, author: "bob", labels: ["api"])

    result = semaphore(
      "ROULETTE_NUMBER" => "12", "ROULETTE_KIND" => "issue", "ROULETTE_ASSIGN_REVIEWER" => "true",
      "ROULETTE_PROJECTS" => "api | services/api | bob, carol"
    )

    assert result.success?, result.stderr
    assert_equal ["carol"], github.assignments
    assert_includes comment_body, "| Category | Suggested assignee | Status |"
    assert_includes comment_body, "| api | [@carol](https://github.com/carol) — 2 pending review requests | Assigned |"
  end

  def test_fails_without_a_token
    result = semaphore("ROULETTE_TOKEN" => nil, "ROULETTE_REVIEWERS" => "alice")

    refute result.success?
    assert_includes result.stderr, "token is required"
    assert_empty github.requests
  end

  def test_fails_on_invalid_configuration_before_calling_the_api
    result = semaphore("ROULETTE_REVIEWERS" => "not a login")

    refute result.success?
    assert_includes result.stderr, "Invalid GitHub login"
    assert_empty github.requests
  end

  def test_fails_without_writing_when_the_repository_is_inaccessible
    result = semaphore("SEMAPHORE_GIT_REPO_SLUG" => "acme/secret", "ROULETTE_REVIEWERS" => "alice")

    refute result.success?
    assert_includes result.stderr, "Target repository is inaccessible"
    assert_empty github.writes
  end

  def test_fails_when_an_issue_repository_is_inaccessible
    result = semaphore("ROULETTE_REVIEWERS" => "alice", "ROULETTE_ISSUE_REPOSITORIES" => "acme/hidden")

    refute result.success?
    assert_includes result.stderr, "issue repository is inaccessible"
    assert_empty github.writes
  end

  def test_fails_when_no_eligible_reviewer_remains
    result = semaphore("ROULETTE_REVIEWERS" => "author")

    refute result.success?
    assert_includes result.stderr, "No eligible reviewers"
    assert_empty github.writes
  end

  def test_never_prints_the_token_when_github_rejects_it
    result = semaphore("ROULETTE_TOKEN" => "wrong-secret", "ROULETTE_REVIEWERS" => "alice")

    refute result.success?
    refute_includes result.stdout + result.stderr, "wrong-secret"
  end

  def test_rejects_repositories_not_hosted_on_github
    result = semaphore("SEMAPHORE_GIT_PROVIDER" => "bitbucket", "ROULETTE_REVIEWERS" => "alice")

    refute result.success?
    assert_includes result.stderr, "GitHub"
    assert_empty github.requests
  end
end
