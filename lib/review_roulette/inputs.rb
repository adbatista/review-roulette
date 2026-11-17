# frozen_string_literal: true

module ReviewRoulette
  LOGIN = /\A[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}\z/i
  REPOSITORY = /\A[\w.-]+\z/

  Options = Struct.new(
    :token, :reviewers, :organizations, :assign_reviewer, :issue_repositories, :status_field,
    :status_weights, :projects, :codeowners, :command, :required_label,
    keyword_init: true
  )
  Project = Struct.new(:name, :patterns, :owners, keyword_init: true)
  Pattern = Struct.new(:repository, :glob, keyword_init: true)

  def self.unique(values) = values.uniq(&:downcase)

  module Inputs
    MAX_WEIGHT = (2**53) - 1
    RESERVED_PROJECTS = ["all", "code owners"].freeze

    module_function

    def parse(raw)
      token = raw["token"].to_s.strip
      raise Error, "token is required" if token.empty?

      Options.new(
        token:,
        reviewers: logins(raw["reviewers"], strip_at: true),
        organizations: logins(raw["organizations"]),
        assign_reviewer: enabled?(raw, "assign-reviewer"),
        issue_repositories: scopes(raw["issue-repositories"]),
        status_field: presence(raw["status-field"]) || "Status",
        status_weights: weights(raw["status-weights"]),
        projects: projects(raw["projects"]),
        codeowners: enabled?(raw, "codeowners"),
        command: raw["command"].to_s.strip,
        required_label: raw["required-label"].to_s.strip
      )
    end

    def presence(value)
      stripped = value.to_s.strip
      stripped unless stripped.empty?
    end

    def entries(value) = value.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)

    def logins(value, strip_at: false)
      names = entries(value).map { |entry| strip_at ? entry.delete_prefix("@") : entry }.reject(&:empty?)
      raise Error, "Invalid GitHub login in input list" unless names.all?(LOGIN)

      ReviewRoulette.unique(names)
    end

    def enabled?(raw, name)
      value = presence(raw[name]) || "false"
      raise Error, "#{name} must be true or false" unless %w[true false].include?(value)

      value == "true"
    end

    def scopes(value)
      found = entries(value).each do |scope|
        owner, repo, *rest = scope.split("/", -1)
        next if rest.empty? && LOGIN.match?(owner) && (repo.nil? || REPOSITORY.match?(repo))

        raise Error, "issue-repositories entries must be an owner or owner/repo"
      end
      ReviewRoulette.unique(found)
    end

    def weights(value)
      value.to_s.split("\n").reject { |line| line.strip.empty? }.to_h do |line|
        match = /\A(.+):\s*(\d+)\s*\z/.match(line)
        name = match && match[1].strip.downcase
        weight = match && match[2].to_i
        if name.nil? || name.empty? || weight > MAX_WEIGHT
          raise Error, "status-weights lines must look like `In progress: 2`"
        end

        [name, weight]
      end
    end

    def projects(value)
      value.to_s.split("\n").reject { |line| line.strip.empty? }.each_with_object({}) do |line, found|
        project = project(line)
        key = project.name.downcase
        if found.key?(key) || RESERVED_PROJECTS.include?(key)
          raise Error, "projects names must be unique and not `All` or `Code owners`"
        end

        found[key] = project
      end.values
    end

    def project(line)
      name, patterns, owners, *rest = line.split("|", -1).map(&:strip)
      if name.empty? || owners.nil? || !rest.empty?
        raise Error, "projects lines must look like `name | patterns | owners`"
      end

      owners = logins(owners, strip_at: true)
      raise Error, "projects lines need at least one owner" if owners.empty?

      Project.new(name:, owners:, patterns: patterns.split(",").map(&:strip).reject(&:empty?).map { pattern(_1) })
    end

    def pattern(text)
      scoped = %r{\A([^/:]+)/([^/:]+):(.*)\z}.match(text)
      return Pattern.new(glob: text) unless scoped
      unless LOGIN.match?(scoped[1]) && REPOSITORY.match?(scoped[2])
        raise Error, "projects repository patterns must look like `owner/repo:glob`"
      end

      glob = scoped[3].strip
      Pattern.new(repository: "#{scoped[1]}/#{scoped[2]}", glob: glob.empty? ? "**" : glob)
    end
  end
end
