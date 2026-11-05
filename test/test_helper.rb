# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "rollout_rule_engine"

module TestHarness
  class AssertionError < StandardError; end

  @suites = []

  class << self
    attr_reader :suites

    def define_suite(name, &block)
      suite = Suite.new(name)
      suite.instance_eval(&block)
      @suites << suite
    end

    def run_all!
      total_tests = 0
      total_assertions = 0
      failures = []

      @suites.each do |suite|
        suite.tests.each do |test_name, test_proc|
          total_tests += 1
          context = Context.new
          begin
            context.instance_eval(&test_proc)
            total_assertions += context.assertions
          rescue StandardError => e
            failures << {
              suite: suite.name,
              test: test_name,
              error: e
            }
          end
        end
      end

      if failures.empty?
        puts "OK: #{total_tests} tests, #{total_assertions} assertions passed."
        0
      else
        failures.each_with_index do |f, idx|
          warn "#{idx + 1}) FAILURE in [#{f[:suite]}] #{f[:test]}: #{f[:error].class}: #{f[:error].message}"
          warn f[:error].backtrace.first(6).map { |line| "    #{line}" }.join("\n")
        end
        warn "FAILED: #{failures.length} of #{total_tests} tests failed."
        1
      end
    end
  end

  class Suite
    attr_reader :name, :tests

    def initialize(name)
      @name = name
      @tests = []
    end

    def test(description, &block)
      @tests << [description, block]
    end
  end

  class Context
    attr_reader :assertions

    def initialize
      @assertions = 0
    end

    def assert(condition, message = "Expected truthy value")
      @assertions += 1
      raise AssertionError, message unless condition
    end

    def refute(condition, message = "Expected falsy value")
      @assertions += 1
      raise AssertionError, message if condition
    end

    def assert_equal(expected, actual, message = nil)
      @assertions += 1
      return if expected == actual

      msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
      raise AssertionError, msg
    end

    def assert_nil(actual, message = nil)
      @assertions += 1
      return if actual.nil?

      raise AssertionError, message || "Expected nil, got #{actual.inspect}"
    end

    def assert_includes(collection, item, message = nil)
      @assertions += 1
      return if collection.include?(item)

      raise AssertionError, message || "Expected #{collection.inspect} to include #{item.inspect}"
    end

    def assert_raises(expected_class)
      @assertions += 1
      begin
        yield
      rescue StandardError => e
        if e.is_a?(expected_class)
          return e
        end
        raise AssertionError, "Expected #{expected_class}, but raised #{e.class}: #{e.message}"
      end
      raise AssertionError, "Expected #{expected_class} to be raised, but nothing was raised"
    end
  end
end
