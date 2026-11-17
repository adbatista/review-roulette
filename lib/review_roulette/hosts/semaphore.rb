# frozen_string_literal: true

require "json"

module ReviewRoulette
  module Hosts
    # Driven only by environment variables and an optional JSON file, so it also runs on
    # any other CI once ROULETTE_REPOSITORY and ROULETTE_NUMBER are set.
    class Semaphore
      attr_reader :exit_code

      def initialize(env = ENV, out: $stdout, err: $stderr)
        @env = env
        @out = out
        @err = err
        @exit_code = 0
      end

      def input(name)
        value = @env[variable(name)]
        return value if value
        return @env["GITHUB_TOKEN"].to_s if name == "token"

        stringify(config[name])
      end

      def event
        provider = @env["SEMAPHORE_GIT_PROVIDER"].to_s
        raise Error, "Review roulette only supports repositories hosted on GitHub" unless ["",
                                                                                           "github"].include?(provider)

        kind = @env["ROULETTE_KIND"].to_s.strip
        kind = "pull" if kind.empty?
        raise Error, "ROULETTE_KIND must be pull or issue" unless %w[pull issue].include?(kind)

        number = (@env["ROULETTE_NUMBER"] || @env["SEMAPHORE_GIT_PR_NUMBER"]).to_s.strip
        return { skip: "this is not a pull-request build and ROULETTE_NUMBER is unset" } if number.empty?

        # SEMAPHORE_GIT_REPO_SLUG is the project's repository, never the fork a PR came from.
        owner, repo, *rest = (@env["ROULETTE_REPOSITORY"] || @env["SEMAPHORE_GIT_REPO_SLUG"]).to_s.split("/", -1)
        { target: { owner:, repo: rest.empty? ? repo : nil,
                    number: number.match?(/\A\d+\z/) ? number.to_i : nil, kind: kind.to_sym } }
      end

      def secret(_value) = nil
      def info(message) = @out.puts(message)

      def output(name, value)
        line = "#{variable(name)}=#{value}"
        info(line)
        path = @env["ROULETTE_OUTPUT_FILE"].to_s.strip
        File.write(path, "#{line}\n", mode: "a") unless path.empty?
      end

      def fail(message)
        @err.puts("Review roulette failed: #{message}")
        @exit_code = 1
      end

      private

      def variable(name) = "ROULETTE_#{name.upcase.tr('-', '_')}"

      def config
        @config ||= begin
          path = @env["ROULETTE_CONFIG"].to_s.strip
          parsed = path.empty? ? {} : JSON.parse(File.read(path))
          raise Error, "ROULETTE_CONFIG must point to a JSON object" unless parsed.is_a?(Hash)

          parsed
        end
      rescue JSON::ParserError, SystemCallError
        raise Error, "ROULETTE_CONFIG must point to a readable JSON file"
      end

      def stringify(value)
        case value
        when Array then value.join("\n")
        when Hash then value.map { |key, entry| "#{key}: #{entry}" }.join("\n")
        when String, Numeric, true, false then value.to_s
        else ""
        end
      end
    end
  end
end
