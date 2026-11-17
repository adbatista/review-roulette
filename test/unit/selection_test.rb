# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class SelectionTest < TestCase
    WORKLOADS = { "alice" => 1, "bob" => 2, "carol" => 1 }.freeze

    def select(reviewers, author: "other", requested: [], previous: nil, random: 0, workloads: WORKLOADS)
      Selector.select(reviewers, author:, workloads:, requested:, previous:, random: -> { random })
    end

    def test_excludes_the_author_case_insensitively_and_picks_the_minimum
      assert_equal Selection.new("Carol", 1), select(%w[Alice Bob Carol], author: "ALICE")
    end

    def test_uses_randomness_only_among_minimum_ties
      assert_equal "Carol", select(%w[Alice Bob Carol], random: 0.99).reviewer
    end

    def test_retains_an_outstanding_request_above_the_minimum
      assert_equal "Bob", select(%w[Alice Bob], requested: ["BOB"], previous: "bob").reviewer
    end

    def test_retains_a_tied_suggestion_but_replaces_an_overloaded_one
      assert_equal "Carol", select(%w[Alice Carol], previous: "carol").reviewer
      assert_equal "Alice", select(%w[Alice Bob], previous: "Bob").reviewer
    end

    def test_ignores_a_previous_reviewer_outside_the_pool
      assert_equal "Bob", select(%w[Alice Bob], author: "Alice", requested: ["alice"], previous: "Alice").reviewer
    end

    def test_rejects_invalid_counts_and_an_empty_pool
      [{}, { "alice" => -1 }, { "alice" => 1.5 }, { "alice" => nil }].each do |workloads|
        assert_raises(Error) { select(["Alice"], workloads:) }
      end
      error = assert_raises(Error) { select(["Alice"], author: "alice") }
      assert_match(/eligible/, error.message)
    end
  end
end
