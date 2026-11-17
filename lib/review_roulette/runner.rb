# frozen_string_literal: true

module ReviewRoulette
  Target = Struct.new(:owner, :repo, :number, :kind, keyword_init: true) do
    def pull? = kind == :pull
  end
  Category = Struct.new(:name, :candidates)
  Result = Struct.new(:picks, :assigned)

  class Runner
    def initialize(options, target, github, random: -> { rand })
      @options = options
      @target = target
      @github = github
      @random = random
    end

    def call
      login = @github.check_access(@target, @options.organizations, @options.issue_repositories)
      @snapshot = @target.pull? ? @github.pull(@target) : @github.issue(@target)
      return Result.new([], false) unless required_label?

      categories = resolve_categories
      everyone = ReviewRoulette.unique(categories.flat_map(&:candidates))
      raise Error, no_candidates_message if everyone.empty?

      load_workloads(everyone)
      comment = Comment.find_managed(@github.comments(@target), login)
      picks = pick(categories, comment ? Comment.read_suggestions(comment[:body]) : {})
      publish(comment, Comment.render(picks, @target.kind))
      Result.new(picks, @newly_requested.any?)
    end

    private

    # An issue's author may be its assignee; only a PR author cannot review their own work.
    def author = @target.pull? ? @snapshot.author : ""

    def required_label?
      label = @options.required_label
      label.empty? || @snapshot.labels.any? { |name| name.casecmp?(label) }
    end

    def no_candidates_message
      return "No eligible reviewers remain after excluding the PR author" if @target.pull?

      "No eligible assignees: an issue needs a matching project or a reviewers list"
    end

    def eligible(logins) = ReviewRoulette.unique(logins).reject { |login| login.casecmp?(author) }

    def resolve_categories
      files = @target.pull? && (@options.projects.any? || @options.codeowners) ? @github.files(@target) : []
      matched = scoped_categories(files).map { |category| Category.new(category.name, eligible(category.candidates)) }
                                        .reject { |category| category.candidates.empty? }
      matched.empty? ? [Category.new("All", eligible(fallback_reviewers))] : matched
    end

    def scoped_categories(files)
      categories = Projects.match(@options.projects, "#{@target.owner}/#{@target.repo}", files, @snapshot.labels)
                           .map { |project| Category.new(project.name, project.owners) }
      categories << Category.new("Code owners", code_owners(files)) if @options.codeowners && @target.pull?
      categories
    end

    def fallback_reviewers
      return @options.reviewers if @options.reviewers.any? || !@target.pull?

      @github.suggested_reviewers(@target)
    end

    def code_owners(files)
      content = @github.codeowners(@target, @snapshot.base_ref) or return []
      Projects.codeowners_for(Projects.parse_codeowners(content), files).flat_map do |owner|
        organization, team = owner.split("/", 2)
        team ? @github.team_members(organization, team) : [owner]
      end
    end

    def load_workloads(everyone)
      @review_counts = @github.review_counts(@target, @options.organizations, everyone)
      scopes = @options.issue_repositories
      @issue_loads = if scopes.empty?
                       nil
                     else
                       @github.issue_loads(scopes, everyone, @options.status_field,
                                           @options.status_weights)
                     end
      @workloads = @review_counts.to_h { |login, count| [login, count + (@issue_loads ? @issue_loads[login] : 0)] }
    end

    def pick(categories, previous)
      outstanding = @snapshot.requested_reviewers.map(&:downcase)
      @newly_requested = []
      categories.map do |category|
        selection = Selector.select(category.candidates, author:, workloads: @workloads,
                                                         requested: @snapshot.requested_reviewers,
                                                         previous: previous[category.name.downcase],
                                                         random: @random)
        login = selection.reviewer.downcase
        Pick.new(category: category.name, reviewer: selection.reviewer, workload: selection.workload,
                 review_count: @review_counts.fetch(login), issue_load: @issue_loads && @issue_loads[login],
                 status: status_for(selection.reviewer, outstanding))
      end
    end

    def status_for(reviewer, outstanding)
      login = reviewer.downcase
      return :already_requested if outstanding.include?(login)
      return :requested if @newly_requested.include?(login)
      return :suggested unless @options.assign_reviewer

      @target.pull? ? @github.request_review(@target, reviewer) : @github.assign_issue(@target, reviewer)
      @newly_requested << login
      :requested
    end

    def publish(comment, body)
      comment ? @github.update_comment(@target, comment[:id], body) : @github.create_comment(@target, body)
    end
  end
end
