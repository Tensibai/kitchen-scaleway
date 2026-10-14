# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "kitchen/driver/scaleway_version"

Gem::Specification.new do |spec|
  spec.name          = "kitchen-scaleway"
  spec.version       = Kitchen::Driver::SCALEWAY_VERSION
  spec.authors       = ["Tensibai"]
  spec.email         = ["tensibai@iabis.net"]
  spec.description   = "A Test Kitchen driver that provisions and destroys " \
                       "Scaleway Instances through the instance v2alpha1 API."
  spec.summary       = "Test Kitchen driver for Scaleway Instances"
  spec.homepage      = "https://github.com/test-kitchen/kitchen-scaleway"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR).grep(/LICENSE|^lib/)
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://kitchen.ci/docs/drivers/scaleway/",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
  }

  spec.add_dependency "test-kitchen", ">= 3.0", "< 5"
end
