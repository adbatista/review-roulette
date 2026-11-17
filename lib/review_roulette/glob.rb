# frozen_string_literal: true

module ReviewRoulette
  # CODEOWNERS rules differ from plain globs: a pattern without a slash matches at any
  # depth, and a trailing wildcard segment such as `docs/*` does not reach nested files.
  class PathMatcher
    def initialize(pattern, codeowners: false)
      directory = pattern.end_with?("/")
      trimmed = pattern.delete_prefix("./").sub(%r{/+\z}, "")
      floating = codeowners && !trimmed.include?("/")
      glob = trimmed.sub(%r{\A/+}, "")
      shallow = codeowners && glob.split("/").last.to_s.include?("*")
      suffix = if directory then "/.*"
               elsif shallow then ""
               else "(?:/.*)?"
               end
      @regexp = Regexp.new("\\A#{'(?:.*/)?' if floating}#{translate(glob)}#{suffix}\\z")
    end

    def match?(path) = @regexp.match?(path)

    def to_proc = method(:match?).to_proc

    private

    def translate(glob)
      glob.scan(%r{\*\*/|\*\*|\*|\?|[^*?]+}).map do |token|
        case token
        when "**/" then "(?:.*/)?"
        when "**" then ".*"
        when "*" then "[^/]*"
        when "?" then "[^/]"
        else Regexp.escape(token)
        end
      end.join
    end
  end
end
