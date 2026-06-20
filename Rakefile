require "rake/testtask"
require "rdoc/task"
# Defines `rake build` / `rake release` per the `Bundler::GemHelper`
# convention. `rake release` is what `rubygems/release-gem` (the
# action used in `.github/workflows/release.yml`) invokes under
# the hood: build the gem into `pkg/`, guard a clean working
# tree, push the tag (no-op when already pushed), then push to
# RubyGems via the OIDC credentials the action wires up.
require "bundler/gem_tasks"

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
  # README / CHANGELOG / docs/*.md use CommonMark, not RDoc's
  # built-in syntax. Aligned with `.rdoc_options`'s `markup:
  # markdown` so the README's `![alt](path)` image tags actually
  # render in the generated site.
  rdoc.options << "--markup" << "markdown"
end

# Image references in README.md (e.g. `examples/billing/graph.svg`)
# don't get copied into `doc/` by RDoc's darkfish template, so the
# generated site 404s on them. Mirror referenced assets into the
# output tree under the same relative path so the markdown links
# keep working both on GitHub and on GitHub Pages.
RDOC_ASSET_PATHS = [
  "examples/billing/graph.svg"
].freeze

Rake::Task[:rdoc].enhance do
  require "fileutils"
  RDOC_ASSET_PATHS.each do |src|
    dest = File.join("doc", src)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(src, dest)
  end
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
