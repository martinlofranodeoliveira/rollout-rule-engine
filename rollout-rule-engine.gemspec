# frozen_string_literal: true

require_relative "lib/rollout_rule_engine/version"

Gem::Specification.new do |spec|
  spec.name = "rollout-rule-engine"
  spec.version = RolloutRuleEngine::VERSION
  spec.authors = ["Lofrano Tecnologia"]
  spec.summary = "Offline deterministic feature flag evaluation with bounded audit traces"
  spec.description = "Development 0.1.0: strict attribute targeting, prerequisite DAG validation, SemVer predicates and length-prefixed SHA-256 cohort rollouts."
  spec.homepage = "https://lofranotecnologia.com.br"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata = {
    "source_code_uri" => "https://github.com/martinlofranodeoliveira/rollout-rule-engine",
    "bug_tracker_uri" => "https://github.com/martinlofranodeoliveira/rollout-rule-engine/issues",
    "changelog_uri" => "https://github.com/martinlofranodeoliveira/rollout-rule-engine/blob/main/CHANGELOG.md"
  }
  spec.files = Dir["lib/**/*.rb", "bin/rollout-engine", "data/*.json", "docs/*.md", "test/*.rb",
                   "README*.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "LICENSE"].sort
  spec.bindir = "bin"
  spec.executables = ["rollout-engine"]
  spec.require_paths = ["lib"]
end
