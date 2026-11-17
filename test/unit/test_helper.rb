# frozen_string_literal: true

require "minitest/autorun"
require "review_roulette"

module ReviewRoulette
  class TestCase < Minitest::Test
    def pick(reviewer, review_count, category: "All", status: :suggested, issue_load: nil)
      Pick.new(category:, reviewer:, review_count:, issue_load:, status:,
               workload: review_count + issue_load.to_i)
    end
  end
end
