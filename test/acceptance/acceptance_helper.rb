# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require_relative "support/fake_github"

# Runs the real executable as a subprocess against FakeGitHub. ROULETTE_BIN swaps in
# another implementation of the same contract.
class AcceptanceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  COMMAND = ENV.fetch("ROULETTE_BIN", "#{RbConfig.ruby} bin/review-roulette").shellsplit
  Result = Struct.new(:stdout, :stderr, :status, :outputs) do
    def success? = status.success?
  end

  attr_reader :github, :dir

  def setup
    @github = FakeGitHub.new.start
    @dir = Dir.mktmpdir("roulette-acceptance")
  end

  def teardown
    github.stop
    FileUtils.rm_rf(dir)
  end

  def semaphore(env = {})
    result = execute({
      "SEMAPHORE" => "true",
      "SEMAPHORE_GIT_PROVIDER" => "github",
      "SEMAPHORE_GIT_REPO_SLUG" => "acme/mono",
      "SEMAPHORE_GIT_PR_NUMBER" => "7",
      "ROULETTE_TOKEN" => FakeGitHub::TOKEN
    }.merge(env))
    result.outputs = result.stdout.scan(/^ROULETTE_(\w+)=(.*)$/).to_h do |name, value|
      [name.downcase.tr("_", "-"), value]
    end
    result
  end

  def actions(event_name, payload, inputs = {})
    event_path = write("event.json", JSON.generate(payload))
    output_path = write("github_output", "")
    env = { "token" => FakeGitHub::TOKEN }.merge(inputs).transform_keys { |name| "INPUT_#{name.upcase}" }
    result = execute(env.merge(
                       "GITHUB_ACTIONS" => "true",
                       "GITHUB_EVENT_NAME" => event_name,
                       "GITHUB_EVENT_PATH" => event_path,
                       "GITHUB_OUTPUT" => output_path,
                       "GITHUB_REPOSITORY" => "acme/mono"
                     ))
    result.outputs = parse_github_output(File.read(output_path))
    result
  end

  def write(name, content)
    File.join(dir, name).tap { |path| File.write(path, content) }
  end

  def comment_body
    assert_equal 1, github.comments.size, "expected exactly one roulette comment"
    github.comments.first[:body]
  end

  private

  def execute(env)
    base = { "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home, "GITHUB_API_URL" => github.url }
    stdout, stderr, status = Open3.capture3(base.merge(env).compact, *COMMAND, chdir: ROOT, unsetenv_others: true)
    Result.new(stdout, stderr, status, {})
  end

  def parse_github_output(text)
    outputs = {}
    lines = text.lines(chomp: true)
    until lines.empty?
      line = lines.shift
      if (heredoc = line.match(/\A([\w-]+)<<(.+)\z/))
        value = []
        value << lines.shift until lines.empty? || lines.first == heredoc[2]
        lines.shift
        outputs[heredoc[1]] = value.join("\n")
      elsif (pair = line.match(/\A([\w-]+)=(.*)\z/))
        outputs[pair[1]] = pair[2]
      end
    end
    outputs
  end
end
