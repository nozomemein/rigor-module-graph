require "rake/testtask"
require "rdoc/task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

RDoc::Task.new do |rdoc|
  rdoc.main = "README.md"
  rdoc.title = "rigor-module-graph"
  rdoc.rdoc_dir = "doc"
  # `docs/*.md` carries the long-form design notes (plan, known
  # limitations). Including them here means `rake rdoc` produces
  # one navigable site that covers source, README, and design
  # docs together.
  rdoc.rdoc_files.include("README.md", "CHANGELOG.md", "docs/*.md", "lib/**/*.rb")
  rdoc.options << "--markup" << "rdoc"
end

namespace :rdoc do
  desc "Generate RDoc and open the index in a browser (macOS / xdg-open)"
  task preview: :rdoc do
    index = File.expand_path("doc/index.html", __dir__)
    opener = ENV["BROWSER"] ||
             (RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open")
    sh opener, index
  end

  desc "Serve RDoc on http://localhost:8808 via `ri --server`"
  task :server do
    sh "ri", "--server=8808"
  end
end

desc "Run tests with C2 (branch) coverage. Report writes to ./coverage."
task :coverage do
  ENV["COVERAGE"] = "1"
  Rake::Task[:test].invoke
end

task default: :test
