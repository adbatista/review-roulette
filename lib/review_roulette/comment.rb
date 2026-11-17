# frozen_string_literal: true

module ReviewRoulette
  Pick = Struct.new(:category, :reviewer, :workload, :review_count, :issue_load, :status, keyword_init: true)

  module Comment
    COPY = {
      pull: { heading: "Suggested reviewer", suggested: "Suggestion only", requested: "Review requested",
              already_requested: "Review already requested" },
      issue: { heading: "Suggested assignee", suggested: "Suggestion only", requested: "Assigned",
               already_requested: "Already assigned" }
    }.freeze
    MARKER = /<!-- review-roulette:v([12]):([^\n]*?) -->/
    ENCODED = /\A(?:[^%]|%\h\h)*\z/

    module_function

    def render(picks, kind = :pull)
      copy = COPY.fetch(kind)
      rows = picks.map do |pick|
        "| #{pick.category} | [@#{pick.reviewer}](https://github.com/#{pick.reviewer}) — " \
          "#{workload(pick)} | #{copy.fetch(pick.status)} |"
      end
      marker = picks.map { |pick| "#{encode(pick.category)}=#{pick.reviewer}" }.join("&")
      <<~BODY.chomp
        ### Review roulette

        | Category | #{copy[:heading]} | Status |
        | --- | --- | --- |
        #{rows.join("\n")}

        <!-- review-roulette:v2:#{marker} -->
      BODY
    end

    def workload(pick)
      reviews = "#{pick.review_count} pending review request#{'s' unless pick.review_count == 1}"
      pick.issue_load ? "#{reviews}, assigned issue load #{pick.issue_load}" : reviews
    end

    # Returns the previous pick per lower-cased category, or nil for an unmanaged comment.
    def read_suggestions(body)
      matches = body.scan(MARKER)
      return unless matches.size == 1

      version, payload = matches.first
      pairs = version == "1" ? ["All=#{payload}"] : payload.split("&", -1)
      pairs.to_h do |pair|
        name, login = pair.split("=", 2)
        category = decode(name)
        return nil if category.nil? || category.empty? || !LOGIN.match?(login.to_s)

        [category.downcase, login]
      end
    end

    def find_managed(comments, identity)
      owned = comments.select do |comment|
        comment[:author].casecmp?(identity) && %w[User Bot].include?(comment[:type]) &&
          read_suggestions(comment[:body])
      end
      owned.min_by { |comment| comment[:id] }
    end

    # Matches JavaScript's encodeURIComponent so markers stay readable across versions.
    def encode(text) = text.b.gsub(/[^A-Za-z0-9\-_.!~*'()]/) { |byte| format("%%%02X", byte.ord) }

    def decode(text)
      return unless ENCODED.match?(text)

      decoded = text.b.gsub(/%(\h\h)/) { ::Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
      decoded if decoded.valid_encoding?
    end
  end
end
