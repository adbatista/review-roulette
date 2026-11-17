# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new("test:unit") do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/unit/**/*_test.rb"
end

Rake::TestTask.new("test:acceptance") do |task|
  task.libs << "test"
  task.pattern = "test/acceptance/**/*_test.rb"
end

desc "Run unit and acceptance tests"
task test: ["test:unit", "test:acceptance"]

task default: :test

desc "Bump lib/review_roulette/version.rb by patch, minor or major and print the new version"
task "version:bump", [:part] do |_, arguments|
  index = %w[major minor patch].index(arguments[:part]) or abort("Usage: rake version:bump[patch|minor|major]")
  path = "lib/review_roulette/version.rb"
  source = File.read(path)
  numbers = source[/VERSION = "(\d+\.\d+\.\d+)"/, 1].split(".").map(&:to_i)
  numbers[index] += 1
  numbers.fill(0, (index + 1)..)
  File.write(path, source.sub(/VERSION = "[^"]+"/, %(VERSION = "#{numbers.join('.')}")))
  puts numbers.join(".")
end
