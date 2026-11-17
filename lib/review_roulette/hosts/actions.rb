# frozen_string_literal: true

require "json"
require "securerandom"

module ReviewRoulette
  module Hosts
    class Actions
      attr_reader :exit_code

      def initialize(env = ENV, out: $stdout)
        @env = env
        @out = out
        @exit_code = 0
      end

      # The runner exports hyphenated names to JavaScript and Docker actions; this composite
      # action maps its inputs to shell-safe underscored names instead.
      def input(name)
        upper = name.upcase
        (@env["INPUT_#{upper}"] || @env["INPUT_#{upper.tr('-', '_')}"]).to_s.strip
      end

      def event
        payload = payload()
        pull = payload["pull_request"]
        issue = payload["issue"]
        base = pull ? pull.dig("base", "repo") : payload["repository"]
        found = { target: { owner: base&.dig("owner", "login"), repo: base && base["name"],
                            number: (pull || issue || {})["number"],
                            kind: pull || issue&.key?("pull_request") ? :pull : :issue } }
        return found unless @env["GITHUB_EVENT_NAME"] == "issue_comment"

        comment = payload["comment"] || {}
        found.merge(comment: { created: payload["action"] == "created",
                               association: comment["author_association"], body: comment["body"] })
      end

      def secret(value) = @out.puts("::add-mask::#{value}")
      def info(message) = @out.puts(message)

      def output(name, value)
        path = @env["GITHUB_OUTPUT"].to_s
        return info("#{name}=#{value}") if path.empty?

        delimiter = "ghadelimiter_#{SecureRandom.hex(16)}"
        File.write(path, "#{name}<<#{delimiter}\n#{value}\n#{delimiter}\n", mode: "a")
      end

      def fail(message)
        @out.puts("::error::#{message.gsub('%', '%25').gsub("\r", '%0D').gsub("\n", '%0A')}")
        @exit_code = 1
      end

      private

      def payload
        path = @env["GITHUB_EVENT_PATH"].to_s
        parsed = File.file?(path) ? JSON.parse(File.read(path)) : {}
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
