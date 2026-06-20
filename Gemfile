# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # minitest-snapshot 0.1.0 declares minitest < 6.0, but Ruby 4.0
  # ships minitest 6.0.x as a default gem. Pin to the 5.x line so
  # the constraint resolves.
  gem "minitest", "~> 5.20"
  gem "minitest-snapshot", "~> 0.1"
  gem "rake", "~> 13.0"
  gem "rdoc", "~> 6.0"
  gem "simplecov", "~> 0.22", require: false
end

group :development do
  gem "lefthook", "~> 1.7"
  gem "rubocop", "~> 1.70", require: false
  gem "rubocop-rake", "~> 0.6", require: false
  gem "rubocop-minitest", "~> 0.36", require: false
end
