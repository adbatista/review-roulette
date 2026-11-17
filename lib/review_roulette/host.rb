# frozen_string_literal: true

module ReviewRoulette
  module Host
    HOSTS = { "actions" => Hosts::Actions, "semaphore" => Hosts::Semaphore }.freeze

    def self.detect(env = ENV)
      name = env["ROULETTE_HOST"].to_s.strip
      name = env["GITHUB_ACTIONS"] == "true" ? "actions" : "semaphore" if name.empty?
      HOSTS.fetch(name) { raise Error, "ROULETTE_HOST must be one of: #{HOSTS.keys.join(', ')}" }.new(env)
    end
  end
end
