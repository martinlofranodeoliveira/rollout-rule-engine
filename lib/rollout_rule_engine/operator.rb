# frozen_string_literal: true

require_relative "errors"
require_relative "semver"

module RolloutRuleEngine
  module Operator
    SUPPORTED_OPERATORS = %w[
      equals
      not_equals
      in
      not_in
      numeric_gt
      numeric_gte
      numeric_lt
      numeric_lte
      semver_eq
      semver_gte
      semver_lt
    ].freeze

    EQUALITY_OPERATORS = %w[equals not_equals].freeze
    SET_OPERATORS = %w[in not_in].freeze
    NUMERIC_OPERATORS = %w[numeric_gt numeric_gte numeric_lt numeric_lte].freeze
    SEMVER_OPERATORS = %w[semver_eq semver_gte semver_lt].freeze

    MAX_STRING_VALUE_BYTES = 1024
    MAX_IN_LIST_ITEMS = 64

    module_function

    def supported?(operator)
      SUPPORTED_OPERATORS.include?(operator)
    end

    def scalar_type_tag(value)
      case value
      when String
        return nil unless Semver.valid_utf8?(value) && value.bytesize <= MAX_STRING_VALUE_BYTES
        :string
      when Integer
        :integer
      when Float
        value.finite? ? :float : nil
      when TrueClass, FalseClass
        :boolean
      else
        nil
      end
    end

    def finite_number?(value)
      value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
    end

    def validate_condition_definition!(operator:, value:)
      unless operator.is_a?(String) && supported?(operator)
        raise ValidationError, "Unsupported operator: #{operator.inspect}"
      end

      if EQUALITY_OPERATORS.include?(operator)
        tag = scalar_type_tag(value)
        if tag.nil?
          raise ValidationError, "Operator '#{operator}' requires a strict finite scalar value (String, Integer, Float, or Boolean)"
        end
        nil
      elsif SET_OPERATORS.include?(operator)
        unless value.is_a?(Array) && !value.empty? && value.length <= MAX_IN_LIST_ITEMS
          raise ValidationError, "Operator '#{operator}' requires a non-empty Array of at most #{MAX_IN_LIST_ITEMS} items"
        end
        first_tag = scalar_type_tag(value.first)
        if first_tag.nil?
          raise ValidationError, "Operator '#{operator}' list items must be strict finite scalars"
        end
        value.each do |item|
          if scalar_type_tag(item) != first_tag
            raise ValidationError, "Operator '#{operator}' requires homogeneous scalar types in target list"
          end
        end
        nil
      elsif NUMERIC_OPERATORS.include?(operator)
        unless finite_number?(value)
          raise ValidationError, "Operator '#{operator}' requires a finite Integer or Float value"
        end
        nil
      elsif SEMVER_OPERATORS.include?(operator)
        unless value.is_a?(String)
          raise ValidationError, "Operator '#{operator}' requires a SemVer 2.0.0 String value"
        end
        Semver.parse(value)
      end
    end

    def evaluate(operator:, attributes:, attribute_name:, target_value:, parsed_target_semver: nil)
      if !attributes.key?(attribute_name) || attributes[attribute_name].nil?
        return { matched: false, reason: "missing_attribute" }
      end

      actual = attributes[attribute_name]

      if EQUALITY_OPERATORS.include?(operator)
        evaluate_equality(operator, actual, target_value)
      elsif SET_OPERATORS.include?(operator)
        evaluate_set(operator, actual, target_value)
      elsif NUMERIC_OPERATORS.include?(operator)
        evaluate_numeric(operator, actual, target_value)
      elsif SEMVER_OPERATORS.include?(operator)
        evaluate_semver(operator, actual, target_value, parsed_target_semver)
      else
        raise ValidationError, "Unsupported operator: #{operator.inspect}"
      end
    end

    def evaluate_equality(operator, actual, target_value)
      actual_tag = scalar_type_tag(actual)
      target_tag = scalar_type_tag(target_value)
      if actual_tag.nil? || actual_tag != target_tag
        return { matched: false, reason: "type_mismatch" }
      end

      matched = if operator == "equals"
                  actual.eql?(target_value)
                else
                  !actual.eql?(target_value)
                end
      { matched: matched, reason: matched ? "condition_matched" : "predicate_failed" }
    end

    def evaluate_set(operator, actual, target_value)
      actual_tag = scalar_type_tag(actual)
      target_tag = scalar_type_tag(target_value.first)
      if actual_tag.nil? || actual_tag != target_tag
        return { matched: false, reason: "type_mismatch" }
      end

      contains = target_value.any? { |item| actual.eql?(item) }
      matched = operator == "in" ? contains : !contains
      { matched: matched, reason: matched ? "condition_matched" : "predicate_failed" }
    end

    def evaluate_numeric(operator, actual, target_value)
      return { matched: false, reason: "type_mismatch" } unless finite_number?(actual)

      matched = case operator
                when "numeric_gt"  then actual > target_value
                when "numeric_gte" then actual >= target_value
                when "numeric_lt"  then actual < target_value
                when "numeric_lte" then actual <= target_value
                end
      { matched: matched, reason: matched ? "condition_matched" : "predicate_failed" }
    end

    def evaluate_semver(operator, actual, target_value, parsed_target_semver)
      return { matched: false, reason: "type_mismatch" } unless actual.is_a?(String) && Semver.valid_utf8?(actual)
      return { matched: false, reason: "type_mismatch" } if actual.bytesize > MAX_STRING_VALUE_BYTES

      actual_semver = Semver.try_parse(actual)
      return { matched: false, reason: "invalid_semver" } if actual_semver.nil?

      target_semver = parsed_target_semver || Semver.parse(target_value)
      cmp = actual_semver <=> target_semver
      matched = case operator
                when "semver_eq"  then cmp.zero?
                when "semver_gte" then cmp >= 0
                when "semver_lt"  then cmp.negative?
                end
      { matched: matched, reason: matched ? "condition_matched" : "predicate_failed" }
    end
  end
end
