# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class RunnerTest < TestCase
    PULL = Target.new(owner: "acme", repo: "project", number: 7, kind: :pull)
    ISSUE = Target.new(owner: "acme", repo: "project", number: 7, kind: :issue)
    EVERYONE = { "alice" => 1, "bob" => 2, "carol" => 0, "dave" => 3, "author" => 5 }.freeze
    WEB = "web | packages/web | Alice, Carol"
    API = "api | services/api | Bob, author"

    class FakeGitHub
      attr_reader :events, :published, :counted

      def initialize(settings)
        @settings = settings
        @events = []
        @published = []
        @counted = []
      end

      def check_access(*) = step("access") && "bot"
      def pull(_) = step("pull") && snapshot("main")
      def issue(_) = step("issue") && snapshot("")
      def files(_) = step("files") && @settings.fetch(:files, [])
      def codeowners(_, ref) = step("codeowners:#{ref}") && @settings[:codeowners]

      def team_members(organization,
                       team)
        step("team:#{organization}/#{team}") && @settings.fetch(:teams, {}).fetch(team, [])
      end

      def suggested_reviewers(_) = step("suggestions") && @settings.fetch(:suggested, %w[Author Alice Bob])

      def issue_loads(scopes, _, field,
                      weights)
        step("issues:#{scopes.join('+')}:#{field}:#{weights.size}") && @settings.fetch(
          :issue_loads, {}
        )
      end

      def comments(_) = step("comments") && @settings.fetch(:comments, [])
      def request_review(_, reviewer) = step("request:#{reviewer}")
      def assign_issue(_, assignee) = step("assign:#{assignee}")
      def create_comment(_, body) = step("create") && (@published << body)
      def update_comment(_, id, body) = step("update:#{id}") && (@published << body)

      def review_counts(_, _, reviewers)
        step("counts")
        @counted << reviewers
        @settings.fetch(:counts, { "alice" => 1, "bob" => 2 })
      end

      private

      def snapshot(base_ref)
        Snapshot.new(author: @settings.fetch(:author, "author"), base_ref:, labels: @settings.fetch(:labels, []),
                     requested_reviewers: @settings.fetch(:requested, []))
      end

      def step(name)
        @events << name
        raise Error, "#{name} failed" if @settings[:fail] == name

        true
      end
    end

    def options(raw = {})
      Inputs.parse({ "token" => "fake", "reviewers" => "Author, Alice, Bob" }.merge(raw))
    end

    def run_with(raw = {}, target: PULL, random: 0, **settings)
      @github = FakeGitHub.new(settings)
      Runner.new(options(raw), target, @github, random: -> { random }).call
    end

    def summary(result) = result.picks.map { |pick| [pick.category, pick.reviewer, pick.status] }

    def test_suggests_without_requesting_and_excludes_the_author_before_counting
      result = run_with

      assert_equal Result.new([pick("Alice", 1)], false), result
      assert_equal %w[access pull counts comments create], @github.events
      assert_equal [%w[Alice Bob]], @github.counted
      assert_includes @github.published.first, "Suggestion only"
    end

    def test_uses_native_suggestions_without_a_reviewer_list
      assert_equal [pick("Alice", 1)], run_with({ "reviewers" => "" }).picks
      assert_equal %w[access pull suggestions counts], @github.events.first(4)
    end

    def test_fails_before_counting_when_nobody_is_eligible
      assert_match(/eligible/, assert_raises(Error) { run_with({ "reviewers" => "" }, suggested: []) }.message)
      assert_equal %w[access pull suggestions], @github.events
      assert_raises(Error) { run_with({ "reviewers" => "Author" }) }
      assert_equal %w[access pull], @github.events
    end

    def test_adds_issue_load_to_review_requests_before_selecting
      result = run_with({ "issue-repositories" => "acme/tasks, other", "status-field" => "Stage",
                          "status-weights" => "Done: 0" }, issue_loads: { "alice" => 5, "bob" => 1 })

      assert_equal [pick("Bob", 2, issue_load: 1)], result.picks
      assert_includes @github.events, "issues:acme/tasks+other:Stage:1"
      assert_includes @github.published.first, "2 pending review requests, assigned issue load 1"
    end

    def test_skips_issue_lookups_unless_configured
      run_with

      assert(@github.events.none? { |event| event.start_with?("issues") })
    end

    def test_requests_before_publishing
      result = run_with({ "assign-reviewer" => "true" })

      assert result.assigned
      assert_equal %w[request:Alice create], @github.events.last(2)
      assert_includes @github.published.first, "Review requested"
    end

    def test_does_not_request_an_already_requested_reviewer
      result = run_with({ "assign-reviewer" => "true" }, requested: ["ALICE"])

      refute result.assigned
      refute_includes @github.events, "request:Alice"
      assert_includes @github.published.first, "Review already requested"
    end

    def test_retains_and_updates_an_owned_requested_pick_above_the_minimum
      comment = { id: 42, author: "bot", type: "Bot", body: Comment.render([pick("Bob", 0, status: :requested)]) }
      result = run_with({ "assign-reviewer" => "true" }, requested: ["Bob"], comments: [comment])

      assert_equal "Bob", result.picks.first.reviewer
      assert_equal "update:42", @github.events.last
      refute_includes @github.events, "request:Bob"
    end

    def test_propagates_failures_without_publishing
      ["access", "pull", "counts", "comments", "request:Alice"].each do |step|
        error = assert_raises(Error) { run_with({ "assign-reviewer" => "true" }, fail: step) }

        assert_equal "#{step} failed", error.message
        assert_empty @github.published
      end
      ["files", "codeowners:main", "team:acme/web"].each do |step|
        assert_raises(Error) do
          run_with({ "codeowners" => "true" }, fail: step, files: ["a.ts"], codeowners: "* @acme/web")
        end
        assert_empty @github.published
      end
    end

    def test_picks_one_owner_per_matched_project_and_counts_everyone_once
      result = run_with({ "projects" => "#{WEB}\n#{API}" }, counts: EVERYONE,
                                                            files: ["packages/web/a.ts", "services/api/main.go"])

      assert_equal [pick("Carol", 0, category: "web"), pick("Bob", 2, category: "api")], result.picks
      assert_equal [%w[Alice Carol Bob]], @github.counted
      refute_includes @github.events, "suggestions"
    end

    def test_matches_by_label_and_requests_each_distinct_pick_once
      result = run_with({ "projects" => "#{WEB}\nshared | | Carol\n#{API}", "assign-reviewer" => "true" },
                        counts: EVERYONE, files: ["packages/web/a.ts"], labels: ["Shared"])

      assert_equal [["web", "Carol", :requested], ["shared", "Carol", :requested]], summary(result)
      assert result.assigned
      assert_equal ["request:Carol"], @github.events.grep(/\Arequest:/)
    end

    def test_keeps_each_categorys_previous_pick
      body = Comment.render([pick("Alice", 0, category: "web"), pick("Carol", 0, category: "api")])
      result = run_with({ "projects" => "#{WEB}\n#{API}" },
                        counts: EVERYONE, files: ["packages/web/a.ts", "services/api/main.go"],
                        requested: ["Alice"], comments: [{ id: 9, author: "bot", type: "Bot", body: }])

      assert_equal [["web", "Alice", :already_requested], ["api", "Bob", :suggested]], summary(result)
      assert_equal "update:9", @github.events.last
    end

    def test_falls_back_when_no_project_matches_or_only_the_author_owns_it
      result = run_with({ "projects" => "#{WEB}\nsolo | ** | author" }, files: ["README.md"])

      assert_equal [pick("Alice", 1)], result.picks
    end

    def test_adds_code_owners_from_the_base_ref_and_expands_teams
      result = run_with({ "projects" => WEB, "codeowners" => "true" },
                        random: 0.99, counts: EVERYONE, files: ["packages/web/a.ts", "docs/a.md"],
                        codeowners: "* @dave\n/packages/ @acme/web-team @Author\n",
                        teams: { "web-team" => %w[Carol alice CAROL] })

      assert_equal [pick("Carol", 0, category: "web"), pick("Carol", 0, category: "Code owners")], result.picks
      assert_includes @github.events, "codeowners:main"
      assert_includes @github.events, "team:acme/web-team"
      assert_equal [%w[Alice Carol dave]], @github.counted
    end

    def test_falls_back_without_a_codeowners_file
      assert_equal [pick("Alice", 1)], run_with({ "codeowners" => "true" }, files: ["a.ts"]).picks
    end

    def test_skips_before_further_lookups_when_the_required_label_is_missing
      assert_equal Result.new([], false), run_with({ "required-label" => "needs-review" }, labels: ["bug"])
      assert_equal %w[access pull], @github.events
      assert_equal [pick("Alice", 1)], run_with({ "required-label" => "needs-review" }, labels: ["Needs-Review"]).picks
    end

    def test_assigns_an_issue_by_label_and_may_pick_its_author
      result = run_with({ "projects" => "#{WEB}\n#{API}", "codeowners" => "true", "assign-reviewer" => "true" },
                        target: ISSUE, labels: ["api"], counts: { "author" => 0, "bob" => 2 })

      assert_equal [pick("author", 0, category: "api", status: :requested)], result.picks
      assert_equal %w[access issue counts comments assign:author create], @github.events
      assert_includes @github.published.first, "| Category | Suggested assignee | Status |"
      assert_includes @github.published.first, "| Assigned |"
    end

    def test_does_not_reassign_an_existing_assignee
      result = run_with({ "reviewers" => "Alice, Bob", "assign-reviewer" => "true" }, target: ISSUE,
                                                                                      requested: ["alice"])

      refute result.assigned
      refute_includes @github.events, "assign:Alice"
      assert_includes @github.published.first, "Already assigned"
    end

    def test_an_issue_needs_a_matching_project_or_reviewers
      error = assert_raises(Error) { run_with({ "reviewers" => "", "projects" => WEB }, target: ISSUE) }

      assert_match(/eligible assignees/, error.message)
      assert_equal %w[access issue], @github.events
    end
  end
end
