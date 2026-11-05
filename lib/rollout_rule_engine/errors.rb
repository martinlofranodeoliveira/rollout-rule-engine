# frozen_string_literal: true

module RolloutRuleEngine
  class Error < StandardError; end
  class ValidationError < Error; end
  class ParseError < ValidationError; end
  class InvalidInputError < ValidationError; end
  class UnknownFlagError < ValidationError; end
  class UnknownPrerequisiteError < ValidationError; end

  class CycleDetectedError < ValidationError
    attr_reader :cycle_path

    def initialize(cycle_path)
      @cycle_path = cycle_path.map { |key| key.dup.freeze }.freeze
      super("Circular prerequisite dependency detected: #{@cycle_path.join(' -> ')}")
    end
  end
end
