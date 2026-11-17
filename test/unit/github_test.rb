# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class GitHubTest < TestCase
    TARGET = Target.new(owner: "acme", repo: "project", number: 7, kind: :pull)
    ACCESS = { repository: { nameWithOwner: "Acme/Project" }, viewer: { login: "roulette[bot]" } }.freeze
    Call = Struct.new(:verb, :uri, :headers, :body) do
      def path = uri.path
      def query = body["query"]
      def variables = body["variables"]
    end

    # Replies are consumed in order; each is [status, body] or [status, body, headers].
    def client(*replies, env: {})
      @calls = []
      @waits = []
      transport = lambda do |method, uri, headers, body|
        @calls << Call.new(method, uri, headers, body ? JSON.parse(body) : nil)
        status, payload, reply_headers = replies.shift || raise("Unexpected API call to #{uri}")
        Response.new(status, reply_headers || {}, JSON.generate(payload))
      end
      GitHub.new("fake-token", env:, transport:, sleeper: ->(seconds) { @waits << seconds }, clock: -> { 0 })
    end

    def data(payload) = [200, { data: payload }]
    def counts(*values) = data(values.each_with_index.to_h { |value, index| ["q#{index}", { issueCount: value }] })

    def issue_page(nodes, cursor = nil)
      data(search: { pageInfo: { hasNextPage: !cursor.nil?, endCursor: cursor }, nodes: })
    end

    def issue(*statuses, archived: false)
      { projectItems: { nodes: statuses.map do |name|
        { isArchived: archived, fieldValueByName: name && { name: } }
      end } }
    end

    def test_checks_repository_organizations_and_issue_scopes_and_returns_the_identity
      github = client(data(ACCESS), data(organization: { login: "Other" }),
                      data(repository: { nameWithOwner: "Acme/Tasks" }), data(repositoryOwner: { login: "Owner" }))

      assert_equal "roulette[bot]", github.check_access(TARGET, %w[Other other], %w[acme/tasks ACME/TASKS owner])
      assert_equal %w[/graphql] * 4, @calls.map(&:path)
      assert_equal({ "owner" => "acme", "repo" => "tasks" }, @calls[2].variables)
      assert_equal "Bearer fake-token", @calls[0].headers["Authorization"]
    end

    def test_rejects_inaccessible_or_mismatched_scopes
      [[[data(ACCESS.merge(repository: nil))], [], [], /repository/],
       [[data(ACCESS.merge(repository: { nameWithOwner: "wrong/project" }))], [], [], /repository/],
       [[data(ACCESS.merge(viewer: nil))], [], [], /identity/],
       [[data(ACCESS), data(organization: nil)], ["secret"], [], /organization/],
       [[data(ACCESS), data(repository: nil)], [], ["acme/tasks"], /issue repository/],
       [[data(ACCESS), data(repositoryOwner: nil)], [], ["other"], /issue repository/]]
        .each do |replies, organizations, scopes, message|
        error = assert_raises(Error) { client(*replies).check_access(TARGET, organizations, scopes) }
        assert_match message, error.message
      end
    end

    def test_reads_a_pull_request_and_paginates_requested_reviewers
      next_link = { "link" => '<https://api.github.com/repos/acme/project/pulls/7/requested_reviewers?page=2>; rel="next"' }
      github = client([200, { user: { login: "author" }, labels: [{ name: "web" }], base: { ref: "release" } }],
                      [200, { users: [{ login: "Alice" }], teams: [] }, next_link],
                      [200, { users: [{ login: "Bob" }], teams: [] }])

      assert_equal Snapshot.new(author: "author", requested_reviewers: %w[Alice Bob], labels: ["web"],
                                base_ref: "release"), github.pull(TARGET)
      assert_equal "per_page=100", @calls[1].uri.query
      assert_equal "page=2", @calls[2].uri.query
    end

    def test_never_follows_a_pagination_link_to_another_host
      github = client([200, [], { "link" => '<https://evil.example/steal>; rel="next"' }])

      error = assert_raises(Error) { github.files(TARGET) }
      assert_match(/unexpected host/, error.message)
      assert_equal 1, @calls.size
    end

    def test_reads_an_issue
      github = client([200, { user: { login: "author" }, assignees: [{ login: "Alice" }],
                              labels: ["plain", { name: "web" }, {}] }],
                      [200, { user: nil, labels: [] }])

      assert_equal Snapshot.new(author: "author", requested_reviewers: ["Alice"], labels: ["plain", "web", ""],
                                base_ref: ""), github.issue(TARGET)
      assert_equal "/repos/acme/project/issues/7", @calls[0].path
      assert_equal ["", []], github.issue(TARGET).to_a.first(2)
    end

    def test_lists_changed_files
      github = client([200, [{ filename: "src/a.ts" }, { filename: "docs/b.md" }]])

      assert_equal %w[src/a.ts docs/b.md], github.files(TARGET)
      assert_equal "/repos/acme/project/pulls/7/files", @calls[0].path
    end

    def test_reads_codeowners_from_the_base_ref_trying_each_location
      github = client([404, { message: "Not Found" }], [200, { type: "file", content: Base64.encode64("* @alice\n") }])

      assert_equal "* @alice\n", github.codeowners(TARGET, "release/1 x")
      assert_equal %w[/repos/acme/project/contents/.github/CODEOWNERS /repos/acme/project/contents/CODEOWNERS],
                   @calls.map(&:path)
      assert_equal "ref=release%2F1%20x", @calls[0].uri.query
    end

    def test_codeowners_is_absent_for_directories_and_fails_on_other_errors
      assert_nil client([200, [{ type: "file" }]], [404, {}], [404, {}]).codeowners(TARGET, "main")
      assert_raises(ApiError) { client([403, { message: "denied" }]).codeowners(TARGET, "main") }
    end

    def test_lists_team_members_and_explains_an_unreadable_team
      github = client([200, [{ login: "Alice" }, { login: "Bob" }]], [404, { message: "Not Found" }],
                      [403, { message: "denied" }])

      assert_equal %w[Alice Bob], github.team_members("acme", "web team")
      assert_equal "/orgs/acme/teams/web%20team/members", @calls[0].path
      assert_match(/team is inaccessible/, assert_raises(Error) { github.team_members("acme", "hidden") }.message)
      assert_match(/denied/, assert_raises(ApiError) { github.team_members("acme", "web") }.message)
    end

    def test_fetches_and_deduplicates_suggested_reviewers
      suggestions = %w[Alice ALICE Bob].map { |login| { reviewer: { login: } } }
      github = client(data(repository: { pullRequest: { suggestedReviewers: suggestions } }),
                      data(repository: { pullRequest: nil }))

      assert_equal %w[Alice Bob], github.suggested_reviewers(TARGET)
      assert_equal({ "owner" => "acme", "repo" => "project", "number" => 7 }, @calls[0].variables)
      assert_match(/suggested reviewers/, assert_raises(Error) { github.suggested_reviewers(TARGET) }.message)
    end

    def test_counts_open_review_requests_in_the_repository
      github = client(counts(3))

      assert_equal({ "alice" => 3 }, github.review_counts(TARGET, [], ["Alice"]))
      assert_equal "is:pr is:open repo:acme/project review-requested:Alice", @calls[0].variables["q0"]
      assert_includes @calls[0].query, "q0: search(type: ISSUE, first: 1, query: $q0) { issueCount }"
    end

    def test_sums_organizations_and_deduplicates_scopes_and_reviewers
      github = client(counts(2, 3, 4, 5))

      assert_equal({ "alice" => 5, "bob" => 9 },
                   github.review_counts(TARGET, %w[Acme ACME Other], %w[Alice ALICE Bob]))
      assert_equal "is:pr is:open org:Other review-requested:Alice", @calls[0].variables["q1"]
    end

    def test_batches_searches
      github = client(counts(*([1] * 20)), counts(4))

      assert_equal 24, github.review_counts(TARGET, Array.new(21) { |index| "org#{index}" }, ["Alice"])["alice"]
      assert_equal 2, @calls.size
    end

    def test_rejects_missing_malformed_or_partial_counts
      [data({}), data(q0: nil), data(q0: { issueCount: nil }), data(q0: { issueCount: -1 }),
       [200, { data: { q0: { issueCount: 0 } }, errors: [{ message: "scope denied" }] }]].each do |reply|
        assert_raises(Error) { client(reply).review_counts(TARGET, [], ["Alice"]) }
      end
    end

    def test_counts_assigned_issues_without_reading_projects
      github = client(counts(2, 3, 0, 0))

      assert_equal({ "alice" => 5, "bob" => 0 },
                   github.issue_loads(%w[acme/tasks other], %w[Alice alice Bob], "Status", {}))
      assert_equal ["is:issue is:open repo:acme/tasks assignee:Alice", "is:issue is:open org:other assignee:Alice"],
                   @calls[0].variables.values_at("q0", "q1")
      refute_includes @calls[0].query, "projectItems"
    end

    def test_weighs_each_issue_by_its_heaviest_live_status_across_pages
      first = [issue("In Progress", "Done"), issue("Done"), issue("In progress", archived: true)]
      github = client(issue_page(first, "c1"),
                      issue_page([issue, issue(nil), issue("Unknown"), nil]))

      loads = github.issue_loads(["acme/tasks"], ["Alice"], "Stage", { "in progress" => 3, "done" => 0, "*" => 2 })

      assert_equal 3 + 0 + 2 + 2 + 2 + 2 + 2, loads["alice"]
      assert_equal({ "q" => "is:issue is:open repo:acme/tasks assignee:Alice", "field" => "Stage", "after" => nil },
                   @calls[0].variables)
      assert_equal "c1", @calls[1].variables["after"]
      assert_includes @calls[0].query, "fieldValueByName(name: $field)"
    end

    def test_unlisted_statuses_default_to_one_and_malformed_pages_fail
      assert_equal 1, client(issue_page([issue("Todo"), issue("Done")]))
        .issue_loads(["acme"], ["Alice"], "Status", { "done" => 0 })["alice"]
      [data(search: nil), data(search: { pageInfo: nil, nodes: [] }),
       [200, { data: { search: nil }, errors: [{ message: "INSUFFICIENT_SCOPES" }] }]].each do |reply|
        assert_raises(Error) { client(reply).issue_loads(["acme"], ["Alice"], "Status", { "done" => 0 }) }
      end
    end

    def test_lists_comments_with_author_metadata
      github = client([200, [{ id: 1, body: "one", user: { login: "roulette[bot]", type: "Bot" } },
                             { id: 2, body: nil, user: nil }]])

      assert_equal [{ id: 1, body: "one", author: "roulette[bot]", type: "Bot" },
                    { id: 2, body: "", author: "", type: "" }], github.comments(TARGET)
    end

    def test_sends_write_payloads_to_the_base_repository
      github = client([201, {}], [201, {}], [200, {}], [201, { assignees: [{ login: "alice" }] }])
      github.request_review(TARGET, "Alice")
      github.create_comment(TARGET, "hello")
      github.update_comment(TARGET, 42, "updated")
      github.assign_issue(TARGET, "Alice")

      assert_equal([["POST", "/repos/acme/project/pulls/7/requested_reviewers", { "reviewers" => ["Alice"] }],
                    ["POST", "/repos/acme/project/issues/7/comments", { "body" => "hello" }],
                    ["PATCH", "/repos/acme/project/issues/comments/42", { "body" => "updated" }],
                    ["POST", "/repos/acme/project/issues/7/assignees", { "assignees" => ["Alice"] }]],
                   @calls.map { |call| [call.verb, call.path, call.body] })
    end

    def test_rejects_a_silently_dropped_assignee
      error = assert_raises(Error) { client([201, { assignees: [] }]).assign_issue(TARGET, "Alice") }
      assert_match(/did not assign/, error.message)
    end

    def test_uses_enterprise_urls
      github = client(data(ACCESS), [200, []], env: { "GITHUB_API_URL" => "https://ghe.example/api/v3/" })
      github.check_access(TARGET, [])
      github.files(TARGET)

      assert_equal "https://ghe.example/api/graphql", @calls[0].uri.to_s
      assert_equal "https://ghe.example/api/v3/repos/acme/project/pulls/7/files?per_page=100", @calls[1].uri.to_s
    end

    def test_honors_rate_limit_guidance
      [[429, { "retry-after" => "2" }, 2], [403, { "retry-after" => "Thu, 01 Jan 1970 00:00:02 GMT" }, 2],
       [403, { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => "2" }, 3],
       [429, {}, 1]].each do |status, headers, wait|
        client([status, { message: "limited" }, headers], data(ACCESS)).check_access(TARGET, [])

        assert_equal [wait], @waits
      end
    end

    def test_fails_without_waiting_on_invalid_or_excessive_guidance
      [{ "retry-after" => "invalid" }, { "retry-after" => "120" }].each do |headers|
        assert_raises(ApiError) { client([429, {}, headers]).check_access(TARGET, []) }
        assert_empty @waits
      end
    end

    def test_retries_transient_read_failures_with_a_bound
      assert_raises(ApiError) { client(*([[503, { message: "unavailable" }]] * 3)).check_access(TARGET, []) }
      assert_equal [1, 2], @waits
      assert_equal 3, @calls.size
    end

    def test_does_not_retry_ambiguous_write_failures_or_permanent_errors
      assert_raises(ApiError) { client([503, {}]).create_comment(TARGET, "hello") }
      assert_equal 1, @calls.size
      [401, 403, 404, 422].each do |status|
        assert_raises(ApiError) { client([status, { message: "denied" }]).check_access(TARGET, []) }
        assert_equal 1, @calls.size
      end
    end

    def test_still_retries_rate_limited_writes
      client([429, {}, { "retry-after" => "1" }], [201, {}]).create_comment(TARGET, "hello")

      assert_equal [1], @waits
    end

    def test_reports_non_json_responses_and_unreachable_hosts
      transport = ->(*) { Response.new(200, {}, "<html>") }
      assert_match(/not JSON/, assert_raises(Error) { GitHub.new("t", env: {}, transport:).files(TARGET) }.message)

      github = GitHub.new("t", env: { "GITHUB_API_URL" => "http://127.0.0.1:1" })
      assert_match(/Could not reach/, assert_raises(Error) { github.files(TARGET) }.message)
    end
  end
end
