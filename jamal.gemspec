# frozen_string_literal: true

require_relative "lib/jamal/version"

Gem::Specification.new do |spec|
  spec.name = "jamal"
  spec.version = Jamal::VERSION
  spec.authors = ["Mounir Ahmina"]

  spec.summary = "Deploy your static website to a remote server"
  spec.homepage = "https://github.com/mojl/jamal"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = ["jamal"]
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html

  spec.add_dependency "net-ssh", "~> 7.3"
  spec.add_dependency "net-sftp", "~> 4.0"
  spec.add_dependency "optparse", "~> 0.6.0"
  spec.add_dependency "fileutils", "~> 1.7"
  spec.add_dependency "yaml", "~> 0.4.0"
  spec.add_dependency "tempfile", "~> 0.3.1"
end
