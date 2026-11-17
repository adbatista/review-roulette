# frozen_string_literal: true

module ReviewRoulette
  class CLI
    INPUTS = %w[
      reviewers organizations assign-reviewer issue-repositories status-field status-weights
      projects codeowners command required-label
    ].freeze
    TRUSTED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

    def initialize(host, github: ->(token) { GitHub.new(token) })
      @host = host
      @github = github
    end

    # Returns the process exit code.
    def call
      token = @host.input("token").strip
      @host.secret(token) unless token.empty?
      options = Inputs.parse(INPUTS.to_h { |name| [name, @host.input(name)] }.merge("token" => token))
      event = @host.event
      return skip(event[:skip]) if event[:skip]
      return skip("the comment is not the command from a repository collaborator") unless commanded?(options, event)

      report(Runner.new(options, target(event), @github.call(token)).call)
    rescue StandardError => e
      @host.fail(token.to_s.empty? ? e.message : e.message.gsub(token, "***"))
      @host.exit_code
    end

    private

    def skip(reason)
      @host.info("Review roulette skipped: #{reason}")
      @host.output("skipped", true)
      @host.exit_code
    end

    def commanded?(options, event)
      comment = event[:comment] or return true
      # Without a command, the action's own comment would retrigger it under a PAT or App token.
      raise Error, "command is required for issue_comment events" if options.command.empty?

      comment[:created] && TRUSTED_ASSOCIATIONS.include?(comment[:association]) &&
        comment[:body].is_a?(String) && comment[:body].lines.any? { |line| line.strip == options.command }
    end

    def target(event)
      found = event[:target] || {}
      owner, repo, number = found.values_at(:owner, :repo, :number)
      valid = owner.is_a?(String) && LOGIN.match?(owner) && repo.is_a?(String) && REPOSITORY.match?(repo) &&
              number.is_a?(Integer) && number.positive? && %i[pull issue].include?(found[:kind])
      raise Error, "A valid pull-request or issue event context is required" unless valid

      Target.new(owner:, repo:, number:, kind: found[:kind])
    end

    def report(result)
      first = result.picks.first or return skip("the required label is missing")
      { "skipped" => false, "reviewer" => first.reviewer,
        "reviewers" => result.picks.map(&:reviewer).uniq.join(","), "review-count" => first.review_count,
        "issue-load" => first.issue_load.to_s, "workload" => first.workload,
        "assigned" => result.assigned }.each { |name, value| @host.output(name, value) }
      @host.exit_code
    end
  end
end
