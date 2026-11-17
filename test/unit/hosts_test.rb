# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "test_helper"

module ReviewRoulette
  class HostsTest < TestCase
    PULL_BUILD = { "SEMAPHORE" => "true", "SEMAPHORE_GIT_PROVIDER" => "github",
                   "SEMAPHORE_GIT_REPO_SLUG" => "acme/mono", "SEMAPHORE_GIT_PR_SLUG" => "fork/mono",
                   "SEMAPHORE_GIT_PR_NUMBER" => "42" }.freeze
    REPOSITORY = { "name" => "project", "owner" => { "login" => "base-owner" } }.freeze

    def setup
      @dir = Dir.mktmpdir("roulette-hosts")
      @out = StringIO.new
      @err = StringIO.new
    end

    def teardown = FileUtils.rm_rf(@dir)

    def write(name, content) = File.join(@dir, name).tap { |path| File.write(path, content) }
    def semaphore(env = {}) = Hosts::Semaphore.new(env, out: @out, err: @err)

    def actions(event_name, payload, env = {})
      Hosts::Actions.new({ "GITHUB_EVENT_NAME" => event_name,
                           "GITHUB_EVENT_PATH" => write("event.json", JSON.generate(payload)) }.merge(env), out: @out)
    end

    def test_detects_the_host_and_honors_the_override
      { { "GITHUB_ACTIONS" => "true" } => Hosts::Actions, { "SEMAPHORE" => "true" } => Hosts::Semaphore,
        {} => Hosts::Semaphore, { "GITHUB_ACTIONS" => "true", "ROULETTE_HOST" => " semaphore " } => Hosts::Semaphore,
        { "SEMAPHORE" => "true", "ROULETTE_HOST" => "actions" } => Hosts::Actions }.each do |env, host|
        assert_instance_of host, Host.detect(env)
      end
      assert_match(/actions, semaphore/, assert_raises(Error) { Host.detect("ROULETTE_HOST" => "jenkins") }.message)
    end

    def test_semaphore_targets_the_projects_pull_request_not_the_fork
      assert_equal({ target: { owner: "acme", repo: "mono", number: 42, kind: :pull } }, semaphore(PULL_BUILD).event)
    end

    def test_semaphore_overrides_can_point_at_an_issue
      env = PULL_BUILD.merge("ROULETTE_REPOSITORY" => "other/tasks", "ROULETTE_NUMBER" => " 7 ",
                             "ROULETTE_KIND" => "issue")

      assert_equal({ target: { owner: "other", repo: "tasks", number: 7, kind: :issue } }, semaphore(env).event)
    end

    def test_semaphore_skips_builds_without_a_pull_request
      assert_match(/not a pull-request build/, semaphore("SEMAPHORE_GIT_REPO_SLUG" => "acme/mono").event[:skip])
    end

    def test_semaphore_leaves_malformed_targets_for_validation
      assert_equal({ owner: "a", repo: nil, number: nil, kind: :pull },
                   semaphore("ROULETTE_REPOSITORY" => "a/b/c", "ROULETTE_NUMBER" => "x1").event[:target])
      assert_equal [nil, nil], semaphore("ROULETTE_NUMBER" => "3").event[:target].values_at(:owner, :repo)
    end

    def test_semaphore_rejects_other_providers_and_unknown_kinds
      assert_match(/GitHub/, assert_raises(Error) do
        semaphore(PULL_BUILD.merge("SEMAPHORE_GIT_PROVIDER" => "bitbucket")).event
      end.message)
      assert_match(/ROULETTE_KIND/, assert_raises(Error) do
        semaphore(PULL_BUILD.merge("ROULETTE_KIND" => "epic")).event
      end.message)
    end

    def test_semaphore_reads_inputs_from_variables_then_the_config_file
      config = write("config.json", JSON.generate(
                                      "reviewers" => %w[alice bob], "assign-reviewer" => true, "command" => nil,
                                      "status-weights" => { "In progress" => 3, "Done" => 0 }, "status-field" => "Stage"
                                    ))
      host = semaphore("ROULETTE_CONFIG" => config, "ROULETTE_STATUS_FIELD" => "Column", "GITHUB_TOKEN" => "fallback")

      assert_equal(["alice\nbob", "true", "In progress: 3\nDone: 0", "Column", "", "", "fallback"],
                   %w[reviewers assign-reviewer status-weights status-field command projects token]
                     .map { |name| host.input(name) })
      assert_equal "own", semaphore("ROULETTE_TOKEN" => "own", "GITHUB_TOKEN" => "fallback").input("token")
      assert_equal "", semaphore.input("token")
    end

    def test_semaphore_rejects_unusable_config_files
      ["[]", "null", '"text"', "{nope"].each do |content|
        host = semaphore("ROULETTE_CONFIG" => write("bad.json", content))
        assert_match(/ROULETTE_CONFIG/, assert_raises(Error) { host.input("reviewers") }.message)
      end
      assert_raises(Error) { semaphore("ROULETTE_CONFIG" => File.join(@dir, "missing.json")).input("reviewers") }
    end

    def test_semaphore_logs_outputs_as_shell_variables_and_appends_them_to_a_file
      file = File.join(@dir, "outputs.env")
      host = semaphore("ROULETTE_OUTPUT_FILE" => file)
      host.output("reviewer", "alice")
      host.output("review-count", 2)
      host.info("hello")
      host.secret("ignored")

      assert_equal "ROULETTE_REVIEWER=alice\nROULETTE_REVIEW_COUNT=2\n", File.read(file)
      assert_equal "ROULETTE_REVIEWER=alice\nROULETTE_REVIEW_COUNT=2\nhello\n", @out.string
    end

    def test_semaphore_reports_failure_on_stderr_with_a_failing_exit_code
      host = semaphore

      assert_equal 0, host.exit_code
      host.fail("boom")
      assert_equal "Review roulette failed: boom\n", @err.string
      assert_equal 1, host.exit_code
    end

    def test_actions_reads_inputs_under_either_naming
      host = Hosts::Actions.new({ "INPUT_ASSIGN-REVIEWER" => " true ", "INPUT_REQUIRED_LABEL" => "x" }, out: @out)

      assert_equal(["true", "x", ""], %w[assign-reviewer required-label reviewers].map { host.input(_1) })
    end

    def test_actions_targets_the_base_repository_of_a_pull_request
      payload = { "pull_request" => { "number" => 7, "base" => { "repo" => REPOSITORY },
                                      "head" => { "repo" => { "name" => "fork" } } } }

      assert_equal({ target: { owner: "base-owner", repo: "project", number: 7, kind: :pull } },
                   actions("pull_request_target", payload).event)
    end

    def test_actions_describes_comment_events
      payload = { "action" => "created", "repository" => REPOSITORY, "issue" => { "number" => 12 },
                  "comment" => { "body" => "/roulette", "author_association" => "MEMBER" } }

      assert_equal({ target: { owner: "base-owner", repo: "project", number: 12, kind: :issue },
                     comment: { created: true, association: "MEMBER", body: "/roulette" } },
                   actions("issue_comment", payload).event)
      payload["issue"]["pull_request"] = {}
      assert_equal :pull, actions("issue_comment", payload).event[:target][:kind]
      refute actions("issues", payload).event.key?(:comment)
    end

    def test_actions_tolerates_a_missing_or_malformed_event
      [Hosts::Actions.new({}, out: @out), actions("push", []),
       Hosts::Actions.new({ "GITHUB_EVENT_PATH" => write("event.json", "{nope") }, out: @out)].each do |host|
        assert_equal({ owner: nil, repo: nil, number: nil, kind: :issue }, host.event[:target])
      end
    end

    def test_actions_writes_outputs_masks_and_errors
      output = write("github_output", "")
      host = Hosts::Actions.new({ "GITHUB_OUTPUT" => output }, out: @out)
      host.output("reviewer", "alice")
      host.secret("s3cret")
      host.info("hello")
      host.fail("50% broken\nsecond line")

      assert_match(/\Areviewer<<(ghadelimiter_\h{32})\nalice\n\1\n\z/, File.read(output))
      assert_equal "::add-mask::s3cret\nhello\n::error::50%25 broken%0Asecond line\n", @out.string
      assert_equal 1, host.exit_code
      Hosts::Actions.new({}, out: @out).output("reviewer", "bob")
      assert_includes @out.string, "reviewer=bob\n"
    end
  end
end
