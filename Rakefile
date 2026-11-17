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
