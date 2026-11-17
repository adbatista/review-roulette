# frozen_string_literal: true

require_relative "runner_test"

module ReviewRoulette
  class CLITest < TestCase
    TARGET = { owner: "acme", repo: "mono", number: 5, kind: :pull }.freeze

    class FakeHost
      attr_reader :calls, :exit_code

      def initialize(event, inputs)
        @event = event
        @inputs = { "token" => "secret", "reviewers" => "Alice" }.merge(inputs)
        @calls = []
        @exit_code = 0
      end

      def input(name) = @inputs.fetch(name, "")
      def event = @event.is_a?(Exception) ? raise(@event) : @event
      def secret(value) = @calls << [:secret, value]
      def info(message) = @calls << [:info, message]
      def output(name, value) = @calls << [:output, name, value]

      def fail(message)
        @calls << [:fail, message]
        @exit_code = 1
      end
    end

    def run_cli(event = { target: TARGET }, inputs = {}, **settings)
      @host = FakeHost.new(event, inputs)
      @tokens = []
      @github = RunnerTest::FakeGitHub.new(settings)
      CLI.new(@host, github: ->(token) { @tokens << token and @github }).call
    end

    def comment(body, created: true, association: "MEMBER") = { created:, association:, body: }

    def test_publishes_outputs_for_the_first_pick_and_every_unique_reviewer
      status = run_cli({ target: TARGET }, { "projects" => "web | ** | alice\napi | ** | bob, alice\nui | ** | alice" },
                       counts: { "alice" => 1, "bob" => 0 })

      assert_equal 0, status
      assert_equal [[:secret, "secret"], [:output, "skipped", false], [:output, "reviewer", "alice"],
                    [:output, "reviewers", "alice,bob"], [:output, "review-count", 1], [:output, "issue-load", ""],
                    [:output, "workload", 1], [:output, "assigned", false]], @host.calls
      assert_equal ["secret"], @tokens
    end

    def test_skips_when_the_host_has_nothing_to_act_on
      assert_equal 0, run_cli({ skip: "not a pull-request build" })
      assert_equal [[:info, "Review roulette skipped: not a pull-request build"], [:output, "skipped", true]],
                   @host.calls.drop(1)
      assert_empty @tokens
    end

    def test_skips_when_the_required_label_is_missing
      run_cli({ target: TARGET }, { "required-label" => "needs-review" })

      assert_equal [:output, "skipped", true], @host.calls.last
      assert_match(/required label/, @host.calls[-2].last)
    end

    def test_runs_a_collaborators_command_comment
      run_cli({ target: TARGET, comment: comment("please\r\n  /roulette  \nthanks") }, { "command" => "/roulette" })

      assert_includes @host.calls, [:output, "reviewer", "Alice"]
    end

    def test_skips_other_comments_outside_commenters_and_edits
      [comment("nice work /roulette"), comment("/roulette", association: "CONTRIBUTOR"),
       comment("/roulette", created: false), comment(nil), comment("/roulette", association: nil)].each do |found|
        assert_equal 0, run_cli({ target: TARGET, comment: found }, { "command" => "/roulette" })
        assert_equal [:output, "skipped", true], @host.calls.last
        assert_empty @tokens
      end
    end

    def test_comment_events_require_a_command
      assert_equal 1, run_cli({ target: TARGET, comment: comment("/roulette") })
      assert_equal [:fail, "command is required for issue_comment events"], @host.calls.last
    end

    def test_fails_for_an_invalid_target
      [{}, { target: TARGET.merge(number: nil) }, { target: TARGET.merge(repo: nil) },
       { target: TARGET.merge(owner: "bad owner") }, { target: TARGET.merge(number: 0) },
       { target: TARGET.merge(number: "5") }, { target: TARGET.merge(kind: :epic) }].each do |event|
        assert_equal 1, run_cli(event)
        assert_equal [:fail, "A valid pull-request or issue event context is required"], @host.calls.last
        assert_empty @tokens
      end
    end

    def test_fails_without_a_token_before_building_a_client
      assert_equal 1, run_cli({ target: TARGET }, { "token" => " " })
      assert_equal [[:fail, "token is required"]], @host.calls
    end

    def test_scrubs_the_token_from_failures_and_publishes_no_outputs
      assert_equal 1, run_cli(RuntimeError.new("request failed with secret"))
      assert_equal [[:secret, "secret"], [:fail, "request failed with ***"]], @host.calls
    end

    def test_reports_run_failures
      assert_equal 1, run_cli({ target: TARGET }, {}, fail: "counts")
      assert_equal [:fail, "counts failed"], @host.calls.last
    end
  end
end
