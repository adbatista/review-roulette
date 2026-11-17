# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class CommentTest < TestCase
    def test_renders_one_selection_with_each_status
      { suggested: "Suggestion only", requested: "Review requested",
        already_requested: "Review already requested" }.each do |status, text|
        body = Comment.render([pick("Alice", 2, status:)])

        assert_includes body, "### Review roulette\n\n| Category | Suggested reviewer | Status |\n| --- | --- | --- |\n"
        assert_includes body, "| All | [@Alice](https://github.com/Alice) — 2 pending review requests | #{text} |"
        assert_equal({ "all" => "Alice" }, Comment.read_suggestions(body))
      end
    end

    def test_singular_workload_and_issue_load
      assert_includes Comment.render([pick("Bob", 1)]), "— 1 pending review request |"
      assert_includes Comment.render([pick("Bob", 1, issue_load: 4)]),
                      "— 1 pending review request, assigned issue load 4 |"
      assert_includes Comment.render([pick("Bob", 1, issue_load: 0)]), "assigned issue load 0 |"
    end

    def test_renders_one_row_per_category_and_round_trips_names
      body = Comment.render([pick("Alice", 2, category: "web & ui=é", status: :requested),
                             pick("Bob", 0, category: "API", status: :already_requested)])

      assert_includes body, "| API | [@Bob](https://github.com/Bob) — 0 pending review requests | " \
                            "Review already requested |"
      assert_includes body, "<!-- review-roulette:v2:web%20%26%20ui%3D%C3%A9=Alice&API=Bob -->"
      assert_equal({ "web & ui=é" => "Alice", "api" => "Bob" }, Comment.read_suggestions(body))
    end

    def test_words_an_issue_comment_as_an_assignment
      { suggested: "Suggestion only", requested: "Assigned", already_requested: "Already assigned" }
        .each do |status, text|
        body = Comment.render([pick("Alice", 1, status:)], :issue)

        assert_includes body, "| Category | Suggested assignee | Status |"
        assert_includes body, "| #{text} |"
      end
    end

    def test_reads_the_single_reviewer_marker_of_earlier_versions
      assert_equal({ "all" => "Alice" }, Comment.read_suggestions("text\n<!-- review-roulette:v1:Alice -->"))
    end

    def test_ignores_invalid_markers
      ["hello", "<!-- review-roulette:v2:Alice -->", "<!-- review-roulette:v2:=Alice -->",
       "<!-- review-roulette:v2:All=bad login -->", "<!-- review-roulette:v2:%E0%A4%A=Alice -->",
       "<!-- review-roulette:v2:%FF=Alice -->", "<!-- review-roulette:v2:All=Alice&api -->",
       "<!-- review-roulette:v1:bad login -->", "<!-- review-roulette:v1:-bad -->",
       "<!-- review-roulette:v1:Alice -->\n<!-- review-roulette:v1:Bob -->"].each do |body|
        assert_nil Comment.read_suggestions(body), body
      end
    end

    def test_finds_the_earliest_owned_valid_comment
      body = Comment.render([pick("Alice", 0)])
      comments = [
        { id: 1, body:, author: "mallory", type: "User" }, { id: 5, body:, author: "Roulette[bot]", type: "Bot" },
        { id: 3, body:, author: "roulette[bot]", type: "Bot" },
        { id: 2, body: "unmarked", author: "roulette[bot]", type: "Bot" },
        { id: 0, body:, author: "roulette[bot]", type: "Organization" }
      ]

      assert_equal 3, Comment.find_managed(comments, "roulette[bot]")[:id]
      assert_nil Comment.find_managed(comments, "other")
    end
  end
end
