# frozen_string_literal: true

require_relative "input"
require_relative "bucketer"
require_relative "operator"

module RolloutRuleEngine
  Prerequisite = Data.define(:flag_key, :variant)
  Condition = Data.define(:attribute, :operator, :value, :parsed_semver)
  Rule = Data.define(:id, :variant, :conditions)
  RolloutWeight = Data.define(:variant, :weight_bps)
  RolloutConfig = Data.define(:salt, :weights)
  FlagDefinition = Data.define(:key, :enabled, :default_variant, :prerequisites, :rules, :rollout)

  class Catalog
    MAX_CATALOG_BYTES = 262_144
    MAX_JSON_DEPTH = 16
    MAX_FLAGS = 100
    MAX_PREREQUISITES_PER_FLAG = 16
    MAX_PREREQUISITE_DEPTH = 32
    MAX_RULES_PER_FLAG = 64
    MAX_CONDITIONS_PER_RULE = 16
    MAX_ROLLOUT_WEIGHTS = 16
    MAX_IDENTIFIER_BYTES = 128
    SUPPORTED_SCHEMA_VERSIONS = ["1.0"].freeze

    attr_reader :schema_version, :flags

    def self.from_json(raw_json)
      from_h(Input.parse_json(raw_json, label: "Catalog JSON",
                             max_bytes: MAX_CATALOG_BYTES, max_depth: MAX_JSON_DEPTH))
    end

    def self.load_file(path)
      from_json(Input.read_catalog(path, max_bytes: MAX_CATALOG_BYTES))
    end

    def self.from_h(data)
      data = Input.snapshot(data, max_bytes: MAX_CATALOG_BYTES, max_depth: MAX_JSON_DEPTH)
      object!(data, %w[schema_version flags], %w[flags])
      schema = data.fetch("schema_version", "1.0")
      unless SUPPORTED_SCHEMA_VERSIONS.include?(schema)
        raise ValidationError, "Unsupported schema_version"
      end
      flags = parse_flags(data.fetch("flags"))
      validate_graph!(flags)
      new(schema_version: schema.dup.freeze, flags: flags.freeze)
    end

    def initialize(schema_version:, flags:)
      @schema_version = schema_version
      @flags = flags
      freeze
    end
    private_class_method :new

    def flag_keys
      flags.keys
    end

    def fetch(flag_key)
      flags.fetch(flag_key) { raise UnknownFlagError, "Unknown flag_key: #{flag_key.inspect}" }
    end

    def key?(flag_key)
      flags.key?(flag_key)
    end

    class << self
      private

      def object!(value, allowed, required = [])
        raise ValidationError, "Expected an object" unless value.is_a?(Hash)
        raise ValidationError, "Object contains an unknown member" unless (value.keys - allowed).empty?
        raise ValidationError, "Object is missing a required member" unless (required - value.keys).empty?
        value
      end

      def identifier(value, label)
        Bucketer.validate_utf8_field!(value, label, MAX_IDENTIFIER_BYTES).dup.freeze
      end

      def array!(value, maximum, label, minimum = 0)
        unless value.is_a?(Array) && value.length.between?(minimum, maximum)
          raise ValidationError, "#{label} must contain #{minimum}..#{maximum} items"
        end
        value
      end

      def embedded_key(definition)
        if definition.key?("key") && definition.key?("flag_key")
          raise ValidationError, "Use only one flag key alias"
        end
        definition["key"] || definition["flag_key"]
      end

      def parse_flags(raw)
        unless (raw.is_a?(Hash) || raw.is_a?(Array)) && raw.size.between?(1, MAX_FLAGS)
          raise ValidationError, "Catalog must define 1..#{MAX_FLAGS} flags"
        end
        entries = if raw.is_a?(Hash)
                    raw.to_a
                  else
                    raw.map do |definition|
                      raise ValidationError, "Flag entry must be an object" unless definition.is_a?(Hash)
                      [embedded_key(definition), definition]
                    end
                  end
        entries.each_with_object({}) do |(raw_key, definition), result|
          key = identifier(raw_key, "flag_key")
          raise ValidationError, "Duplicate flag_key definition" if result.key?(key)
          result[key] = parse_flag(key, definition)
        end
      end

      def parse_flag(key, raw)
        object!(raw, %w[key flag_key enabled default_variant prerequisites rules rollout],
                %w[enabled default_variant])
        if raw.key?("key") || raw.key?("flag_key")
          unless identifier(embedded_key(raw), "embedded flag_key") == key
            raise ValidationError, "Embedded flag key differs from map key"
          end
        end
        enabled = raw.fetch("enabled")
        unless enabled.equal?(true) || enabled.equal?(false)
          raise ValidationError, "enabled must be a boolean"
        end
        FlagDefinition.new(
          key: key, enabled: enabled,
          default_variant: identifier(raw.fetch("default_variant"), "default_variant"),
          prerequisites: parse_prerequisites(raw.fetch("prerequisites", nil)),
          rules: parse_rules(raw.fetch("rules", nil)),
          rollout: parse_rollout(raw.fetch("rollout", nil))
        )
      end

      def parse_prerequisites(raw)
        raw = [] if raw.nil?
        seen = {}
        array!(raw, MAX_PREREQUISITES_PER_FLAG, "prerequisites").map do |item|
          object!(item, %w[flag_key variant], %w[flag_key variant])
          key = identifier(item.fetch("flag_key"), "prerequisite.flag_key")
          raise ValidationError, "Duplicate prerequisite" if seen.key?(key)
          seen[key] = true
          Prerequisite.new(flag_key: key, variant: identifier(item.fetch("variant"), "prerequisite.variant"))
        end.freeze
      end

      def parse_rules(raw)
        raw = [] if raw.nil?
        seen = {}
        array!(raw, MAX_RULES_PER_FLAG, "rules").map do |item|
          object!(item, %w[id variant conditions], %w[id variant conditions])
          id = identifier(item.fetch("id"), "rule.id")
          raise ValidationError, "Duplicate rule ID" if seen.key?(id)
          seen[id] = true
          conditions = array!(item.fetch("conditions"), MAX_CONDITIONS_PER_RULE, "conditions", 1).map do |condition|
            object!(condition, %w[attribute operator value], %w[attribute operator value])
            operator = condition.fetch("operator")
            value = condition.fetch("value")
            parsed = Operator.validate_condition_definition!(operator: operator, value: value)
            frozen_value = if value.is_a?(Array)
                             value.map { |entry| entry.is_a?(String) ? entry.freeze : entry }.freeze
                           else
                             value.freeze
                           end
            Condition.new(attribute: identifier(condition.fetch("attribute"), "condition.attribute"),
                          operator: operator.freeze, value: frozen_value, parsed_semver: parsed)
          end.freeze
          Rule.new(id: id, variant: identifier(item.fetch("variant"), "rule.variant"), conditions: conditions)
        end.freeze
      end

      def parse_rollout(raw)
        return nil if raw.nil?
        object!(raw, %w[active salt weights])
        active = raw.fetch("active", true)
        unless active.equal?(true) || active.equal?(false)
          raise ValidationError, "rollout.active must be a boolean"
        end
        if active && (!raw.key?("salt") || !raw.key?("weights"))
          raise ValidationError, "Active rollout requires salt and weights"
        end
        salt = identifier(raw.fetch("salt"), "rollout.salt") if raw.key?("salt")
        weights = if raw.key?("weights")
                    Bucketer.normalize_weights!(raw.fetch("weights"), require_total: active).map do |entry|
                      RolloutWeight.new(variant: entry.fetch("variant"), weight_bps: entry.fetch("weight_bps"))
                    end.freeze
                  end
        return nil unless active

        RolloutConfig.new(salt: salt, weights: weights)
      end

      def validate_graph!(flags)
        flags.each_value do |flag|
          flag.prerequisites.each do |prerequisite|
            unless flags.key?(prerequisite.flag_key)
              raise UnknownPrerequisiteError, "Unknown prerequisite flag: #{prerequisite.flag_key.inspect}"
            end
          end
        end
        state = {}
        depths = {}
        stack = []
        visit = lambda do |key|
          state[key] = :visiting
          stack << key
          depth = 0
          flags.fetch(key).prerequisites.each do |prerequisite|
            target = prerequisite.flag_key
            if state[target] == :visiting
              raise CycleDetectedError.new(stack[stack.index(target)..] + [target])
            end
            visit.call(target) unless state[target] == :visited
            depth = [depth, 1 + depths.fetch(target)].max
          end
          if depth > MAX_PREREQUISITE_DEPTH
            raise ValidationError, "Prerequisite depth exceeds #{MAX_PREREQUISITE_DEPTH} edges"
          end
          depths[key] = depth
          stack.pop
          state[key] = :visited
        end
        flags.each_key { |key| visit.call(key) unless state[key] == :visited }
      end
    end
  end
end
