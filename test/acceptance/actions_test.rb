# frozen_string_literal: true

require_relative "acceptance_helper"

class ActionsAcceptanceTest < AcceptanceTest
  REPOSITORY = { "name" => "mono", "owner" => { "login" => "acme" } }.freeze
  PULL_EVENT = {
    "action" => "opened", "number" => 7,
    "pull_request" => { "number" => 7, "base" => { "repo" => REPOSITORY },
                        "head" => { "repo" => { "name" => "mono", "owner" => { "login" => "fork" } } } }
  }.freeze

  def setup
    super
    github.add_pull(7, author: "author")
    github.add_issue(12, author: "author", labels: ["needs-owner"])
    github.pending_reviews(alice: 1, bob: 3)
  end

  def comment_event(body, association: "MEMBER", action: "created", pull: true)
    { "action" => action, "repository" => REPOSITORY,
      "issue" => { "number" => pull ? 7 : 12 }.merge(pull ? { "pull_request" => {} } : {}),
      "comment" => { "body" => body, "author_association" => association } }
  end

  def test_pull_request_event_requests_a_review_and_publishes_step_outputs
    result = actions("pull_request", PULL_EVENT, "reviewers" => "@alice\nbob", "assign-reviewer" => "true")

    assert result.success?, result.stderr
    assert_equal ["alice"], github.review_requests
    assert_includes comment_body,
                    "| All | [@alice](https://github.com/alice) — 1 pending review request | Review requested |"
    assert_equal({ "skipped" => "false", "reviewer" => "alice", "reviewers" => "alice", "review-count" => "1",
                   "issue-load" => "", "workload" => "1", "assigned" => "true" }, result.outputs)
  end

  def test_pull_request_target_event_uses_the_base_repository
    result = actions("pull_request_target", PULL_EVENT, "reviewers" => "alice, bob")

    assert result.success?, result.stderr
    assert_equal "alice", result.outputs["reviewer"]
  end

  def test_command_comment_from_a_member_runs_on_the_pull_request
    result = actions("issue_comment", comment_event("thanks!\n/roulette"),
                     "reviewers" => "alice, bob", "command" => "/roulette")

    assert result.success?, result.stderr
    assert_equal "alice", result.outputs["reviewer"]
    assert_includes comment_body, "[@alice]"
  end

  def test_command_comment_on_an_issue_assigns_it
    result = actions("issue_comment", comment_event("/roulette", pull: false),
                     "reviewers" => "alice, bob", "command" => "/roulette",
                     "required-label" => "needs-owner", "assign-reviewer" => "true")

    assert result.success?, result.stderr
    assert_equal ["alice"], github.assignments
    assert_includes comment_body, "| Assigned |"
  end

  def test_command_from_an_outside_commenter_is_skipped
    result = actions("issue_comment", comment_event("/roulette", association: "CONTRIBUTOR"),
                     "reviewers" => "alice", "command" => "/roulette")

    assert result.success?, result.stderr
    assert_equal({ "skipped" => "true" }, result.outputs)
    assert_empty github.requests
  end

  def test_other_comments_and_edits_are_skipped
    [comment_event("please run /roulette"), comment_event("/roulette", action: "edited")].each do |payload|
      result = actions("issue_comment", payload, "reviewers" => "alice", "command" => "/roulette")

      assert result.success?, result.stderr
      assert_equal({ "skipped" => "true" }, result.outputs)
    end
    assert_empty github.requests
  end

  def test_comment_events_require_a_command
    result = actions("issue_comment", comment_event("/roulette"), "reviewers" => "alice")

    refute result.success?
    assert_includes result.stdout, "::error::command is required for issue_comment events"
    assert_empty github.requests
  end

  def test_failures_are_reported_as_workflow_errors_without_outputs
    result = actions("pull_request", PULL_EVENT, "reviewers" => "author")

    refute result.success?
    assert_match(/^::error::No eligible reviewers/, result.stdout)
    assert_empty result.outputs
  end

  def test_fails_without_a_pull_request_or_issue_in_the_event
    result = actions("push", { "ref" => "refs/heads/main" }, "reviewers" => "alice")

    refute result.success?
    assert_includes result.stdout, "::error::A valid pull-request or issue event context is required"
  end

  def test_masks_the_token_in_the_log
    result = actions("pull_request", PULL_EVENT, "reviewers" => "alice")

    assert_includes result.stdout, "::add-mask::#{FakeGitHub::TOKEN}"
  end
end
