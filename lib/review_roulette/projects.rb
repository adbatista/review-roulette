# frozen_string_literal: true

module ReviewRoulette
  module Projects
    Rule = Struct.new(:matcher, :owners)

    module_function

    def match(projects, repository, files, labels)
      projects.select do |project|
        labels.any? { |label| label.casecmp?(project.name) } ||
          project.patterns.any? do |pattern|
            next false if pattern.repository && !pattern.repository.casecmp?(repository)

            pattern.glob == "**" || files.any?(&PathMatcher.new(pattern.glob))
          end
      end
    end

    def parse_codeowners(content)
      content.split("\n").map { |line| line.sub(/(^|\s)#.*$/, "").strip }.reject(&:empty?).map do |line|
        pattern, *owners = line.split(/\s+/)
        Rule.new(PathMatcher.new(pattern, codeowners: true),
                 owners.select { |owner| owner.start_with?("@") }.map { |owner| owner.delete_prefix("@") })
      end
    end

    def codeowners_for(rules, files)
      owners = files.flat_map do |file|
        rule = rules.reverse_each.find { |candidate| candidate.matcher.match?(file) }
        rule ? rule.owners : []
      end
      ReviewRoulette.unique(owners)
    end
  end
end
