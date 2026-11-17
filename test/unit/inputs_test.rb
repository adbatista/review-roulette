# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class InputsTest < TestCase
    def parse(raw = {}) = Inputs.parse({ "token" => "secret" }.merge(raw))

    def test_normalizes_lists_and_defaults
      options = parse("reviewers" => "@Alice, alice\nBob", "organizations" => "Acme,acme\nOther")

      assert_equal %w[Alice Bob], options.reviewers
      assert_equal %w[Acme Other], options.organizations
      assert_equal [false, [], "Status", {}, [], false, "", ""],
                   [options.assign_reviewer, options.issue_repositories, options.status_field,
                    options.status_weights, options.projects, options.codeowners, options.command,
                    options.required_label]
    end

    def test_empty_lists_and_explicit_flags
      options = parse("reviewers" => " , \n", "assign-reviewer" => " true ", "codeowners" => "true",
                      "command" => " /roulette ", "required-label" => " needs review ")

      assert_empty options.reviewers
      assert options.assign_reviewer
      assert options.codeowners
      assert_equal "/roulette", options.command
      assert_equal "needs review", options.required_label
    end

    def test_parses_issue_scopes_and_status_weights
      options = parse("issue-repositories" => "acme/tasks, Acme/Tasks\nother", "status-field" => " Stage ",
                      "status-weights" => "In progress: 3\n\nReview: now: 2\r\n*: 0")

      assert_equal %w[acme/tasks other], options.issue_repositories
      assert_equal "Stage", options.status_field
      assert_equal({ "in progress" => 3, "review: now" => 2, "*" => 0 }, options.status_weights)
    end

    def test_parses_projects_with_folder_repository_and_label_only_patterns
      options = parse("projects" => "web | packages/web/**, packages/ui | @Alice, bob\n\n" \
                                    "docs | acme/docs:, Acme/site:guides/** | carol\nsecurity | | dave")

      assert_equal(
        [["web", [[nil, "packages/web/**"], [nil, "packages/ui"]], %w[Alice bob]],
         ["docs", [["acme/docs", "**"], ["Acme/site", "guides/**"]], ["carol"]],
         ["security", [], ["dave"]]],
        options.projects.map { |project| [project.name, project.patterns.map(&:to_a), project.owners] }
      )
    end

    INVALID = [
      { "token" => " " }, { "reviewers" => "a--b" }, { "reviewers" => "-alice" },
      { "organizations" => "bad org" }, { "organizations" => "@acme" }, { "assign-reviewer" => "yes" },
      { "codeowners" => "yes" }, { "issue-repositories" => "acme/tasks/extra" },
      { "issue-repositories" => "acme/bad repo" }, { "status-weights" => "Todo" },
      { "status-weights" => "Todo: -1" }, { "status-weights" => "Todo: 1.5" }, { "status-weights" => ": 1" },
      { "status-weights" => "Todo: 99999999999999999999" }, { "projects" => "web | src/**" },
      { "projects" => "web | src/** | alice | extra" }, { "projects" => " | src/** | alice" },
      { "projects" => "web | src/** | " }, { "projects" => "web | src/** |" },
      { "projects" => "web | src/** | bad login" }, { "projects" => "web | a | alice\nWEB | b | bob" },
      { "projects" => "all | a | alice" }, { "projects" => "Code Owners | a | alice" },
      { "projects" => "web | bad owner/repo:src | alice" }
    ].freeze

    def test_rejects_invalid_inputs
      INVALID.each { |raw| assert_raises(Error, raw.inspect) { parse(raw) } }
    end
  end
end
