# frozen_string_literal: true

require "json"
require_relative "catalog"

module RolloutRuleEngine
  class EvaluationResult
    REASONS = %w[flag_disabled prerequisite_failed rule_match percentage_rollout default_fallback].freeze

    attr_reader :flag_key, :resolved_variant, :reason, :matched_rule_id, :bucket_bps,
                :failed_prerequisite_key, :trace, :prerequisites, :prerequisite_trace

    def initialize(flag_key:, resolved_variant:, reason:, matched_rule_id:, bucket_bps:,
                   failed_prerequisite_key:, trace:, prerequisites: [], prerequisite_trace: [])
      @flag_key = flag_key
      @resolved_variant = resolved_variant
      @reason = reason
      @matched_rule_id = matched_rule_id
      @bucket_bps = bucket_bps
      @failed_prerequisite_key = failed_prerequisite_key
      @trace = trace
      @prerequisites = prerequisites
      @prerequisite_trace = prerequisite_trace
      @hash_repr = deep_freeze({
        "flag_key" => flag_key, "resolved_variant" => resolved_variant, "reason" => reason,
        "matched_rule_id" => matched_rule_id, "bucket_bps" => bucket_bps,
        "failed_prerequisite_key" => failed_prerequisite_key, "trace" => trace,
        "prerequisites" => prerequisites, "prerequisite_trace" => prerequisite_trace
      })
      freeze
    end

    def [](key)
      @hash_repr[key.to_s]
    end

    def to_h
      @hash_repr
    end

    def to_json(*args)
      JSON.generate(@hash_repr, *args)
    end

    def with_prerequisite_trace(entries)
      self.class.new(flag_key: flag_key, resolved_variant: resolved_variant, reason: reason,
                     matched_rule_id: matched_rule_id, bucket_bps: bucket_bps,
                     failed_prerequisite_key: failed_prerequisite_key, trace: trace,
                     prerequisites: prerequisites, prerequisite_trace: entries)
    end

    private

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end

  class Engine
    MAX_SUBJECT_ATTRIBUTES = 128
    UNSUPPORTED_ATTRIBUTE = Object.new.freeze

    attr_reader :catalog

    def self.from_json(raw_json)
      new(Catalog.from_json(raw_json))
    end

    def self.load_file(path)
      new(Catalog.load_file(path))
    end

    def initialize(catalog)
      raise InvalidInputError, "Expected a RolloutRuleEngine::Catalog" unless catalog.is_a?(Catalog)
      @catalog = catalog
      freeze
    end

    def evaluate(flag_key:, subject_id:, attributes: {})
      key = Bucketer.validate_utf8_field!(flag_key, "flag_key", Catalog::MAX_IDENTIFIER_BYTES)
      subject = Bucketer.validate_utf8_field!(subject_id, "subject_id", Bucketer::MAX_SUBJECT_ID_BYTES)
      normalized = normalize_attributes!(attributes)
      memo = {}
      local = evaluate_flag(key, subject, normalized, memo)
      complete_result(local, memo)
    end

    def evaluate_all(subject_id:, attributes: {})
      subject = Bucketer.validate_utf8_field!(subject_id, "subject_id", Bucketer::MAX_SUBJECT_ID_BYTES)
      normalized = normalize_attributes!(attributes)
      memo = {}
      catalog.flag_keys.each { |key| evaluate_flag(key, subject, normalized, memo) }
      catalog.flag_keys.to_h { |key| [key, complete_result(memo.fetch(key), memo)] }.freeze
    end

    private

    def normalize_attributes!(attributes)
      unless attributes.is_a?(Hash) && attributes.size <= MAX_SUBJECT_ATTRIBUTES
        raise InvalidInputError, "attributes must be a Hash of at most #{MAX_SUBJECT_ATTRIBUTES} members"
      end
      attributes.each_with_object({}) do |(raw_key, value), normalized|
        raw_key = raw_key.to_s if raw_key.is_a?(Symbol)
        key = Bucketer.validate_utf8_field!(raw_key, "attribute key", Catalog::MAX_IDENTIFIER_BYTES).dup.freeze
        raise InvalidInputError, "Duplicate normalized attribute key" if normalized.key?(key)
        normalized[key] = case value
                          when String
                            Input.text!(value, "Attribute string", Operator::MAX_STRING_VALUE_BYTES,
                                        min_bytes: 0).dup.freeze
                          when Integer
                            if value.bit_length > Input::MAX_INTEGER_BITS
                              raise InvalidInputError, "Attribute integer exceeds magnitude limit"
                            end
                            value
                          when Float
                            value.finite? ? value : UNSUPPORTED_ATTRIBUTE
                          when TrueClass, FalseClass, NilClass
                            value
                          else
                            # Do not traverse, compare, retain, or serialize composite values.
                            UNSUPPORTED_ATTRIBUTE
                          end
      end.freeze
    end

    def result(flag, variant, reason, trace, prerequisites, rule_id: nil, bucket: nil, failed: nil)
      EvaluationResult.new(flag_key: flag.key, resolved_variant: variant, reason: reason,
                           matched_rule_id: rule_id, bucket_bps: bucket,
                           failed_prerequisite_key: failed, trace: trace, prerequisites: prerequisites)
    end

    def evaluate_flag(key, subject, attributes, memo)
      return memo.fetch(key) if memo.key?(key)
      flag = catalog.fetch(key)
      checks = []
      trace = []
      unless flag.enabled
        return memo[key] = result(flag, flag.default_variant, "flag_disabled", trace, checks)
      end
      flag.prerequisites.each do |prerequisite|
        dependency = evaluate_flag(prerequisite.flag_key, subject, attributes, memo)
        matched = dependency.resolved_variant == prerequisite.variant
        checks << {
          "flag_key" => prerequisite.flag_key, "required_variant" => prerequisite.variant,
          "resolved_variant" => dependency.resolved_variant, "reason" => dependency.reason,
          "matched" => matched
        }
        unless matched
          return memo[key] = result(flag, flag.default_variant, "prerequisite_failed", trace, checks,
                                    failed: prerequisite.flag_key)
        end
      end
      flag.rules.each do |rule|
        clauses = []
        failed_index = nil
        rule.conditions.each_with_index do |condition, index|
          outcome = Operator.evaluate(operator: condition.operator, attributes: attributes,
                                      attribute_name: condition.attribute, target_value: condition.value,
                                      parsed_target_semver: condition.parsed_semver)
          clauses << { "condition_index" => index, "operator" => condition.operator,
                       "matched" => outcome.fetch(:matched), "reason" => outcome.fetch(:reason) }
          unless outcome.fetch(:matched)
            failed_index = index
            break
          end
        end
        matched = failed_index.nil?
        trace << { "rule_id" => rule.id, "matched" => matched,
                   "reason" => matched ? "rule_matched" : clauses.last.fetch("reason"),
                   "failed_condition_index" => failed_index, "conditions" => clauses }
        if matched
          return memo[key] = result(flag, rule.variant, "rule_match", trace, checks, rule_id: rule.id)
        end
      end
      if flag.rollout
        bucket = Bucketer.bucket_bps(flag_key: flag.key, salt: flag.rollout.salt, subject_id: subject)
        variant = Bucketer.select_weighted_variant(bucket_bps: bucket, weights: flag.rollout.weights)
        return memo[key] = result(flag, variant, "percentage_rollout", trace, checks, bucket: bucket)
      end
      memo[key] = result(flag, flag.default_variant, "default_fallback", trace, checks)
    end

    def complete_result(local, memo)
      # Flat dependency records avoid recursively serializing a diamond as a tree.
      needed = {}
      pending = local.prerequisites.map { |entry| entry.fetch("flag_key") }
      until pending.empty?
        key = pending.pop
        next if needed.key?(key)
        needed[key] = true
        memo.fetch(key).prerequisites.each { |entry| pending << entry.fetch("flag_key") }
      end
      entries = memo.values.filter_map do |dependency|
        next unless needed.key?(dependency.flag_key)
        dependency.to_h.reject { |name, _| name == "prerequisite_trace" }
      end
      local.with_prerequisite_trace(entries)
    end
  end
end
