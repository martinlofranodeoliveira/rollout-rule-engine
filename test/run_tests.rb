# frozen_string_literal: true

require_relative "test_helper"
require_relative "bucketer_and_semver_test"
require_relative "catalog_and_cycles_test"
require_relative "engine_and_cli_test"
require_relative "adversarial_test"

exit(TestHarness.run_all!)
