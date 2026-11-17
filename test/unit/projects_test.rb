# frozen_string_literal: true

require_relative "test_helper"

module ReviewRoulette
  class ProjectsTest < TestCase
    PROJECTS = Inputs.projects(<<~LINES)
      web | packages/web/** | alice
      api | Acme/Mono:services/api | bob
      docs | acme/docs: | carol
      security | | dave
    LINES
    RULES = Projects.parse_codeowners(<<~CODEOWNERS)
      # default owners
      *       @fallback  # trailing comment
      *.md    @docs-team someone@example.com
      /apps/  @acme/apps @Alice

      /apps/legacy/
    CODEOWNERS

    def names(repository, files, labels = [])
      Projects.match(PROJECTS, repository, files, labels).map(&:name)
    end

    def test_matches_folders_anywhere_and_scoped_folders_only_in_their_repository
      files = ["packages/web/a.ts", "services/api/main.go"]

      assert_equal %w[web api], names("acme/mono", files)
      assert_equal %w[web], names("acme/other", files)
      assert_empty names("acme/mono", ["README.md"])
    end

    def test_matches_a_whole_repository_without_changed_files
      assert_equal %w[docs], names("ACME/Docs", [])
    end

    def test_matches_a_project_by_label
      assert_equal %w[security], names("acme/mono", [], %w[Security bug])
    end

    def test_uses_the_last_matching_codeowners_rule_per_file
      assert_equal %w[fallback acme/apps Alice],
                   Projects.codeowners_for(RULES, ["src/a.ts", "apps/web/a.ts", "apps/web/README.md"])
      assert_equal %w[docs-team], Projects.codeowners_for(RULES, ["README.md", "docs/a.md"])
    end

    def test_a_later_rule_without_owners_leaves_files_unowned
      assert_empty Projects.codeowners_for(RULES, ["apps/legacy/a.ts"])
      assert_empty Projects.codeowners_for(Projects.parse_codeowners("/src/ @alice"), ["docs/a.md"])
    end
  end
end
