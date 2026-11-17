# frozen_string_literal: true

module ReviewRoulette
  Selection = Struct.new(:reviewer, :workload)

  module Selector
    module_function

    def select(reviewers, author:, workloads:, requested:, previous: nil, random: -> { rand })
      candidates = candidates(reviewers, author, workloads)
      raise Error, "No eligible reviewers remain after excluding the PR author" if candidates.empty?

      minimum = candidates.map(&:workload).min
      kept = previous && candidates.find { |candidate| candidate.reviewer.casecmp?(previous) }
      return kept if kept && (kept.workload == minimum || requested.any? { |login| login.casecmp?(kept.reviewer) })

      tied = candidates.select { |candidate| candidate.workload == minimum }
      tied[(random.call * tied.size).floor]
    end

    def candidates(reviewers, author, workloads)
      reviewers.reject { |login| login.casecmp?(author) }.map do |reviewer|
        workload = workloads[reviewer.downcase]
        raise Error, "Invalid or missing reviewer workload count" unless workload.is_a?(Integer) && !workload.negative?

        Selection.new(reviewer, workload)
      end
    end
  end
end
