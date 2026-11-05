# frozen_string_literal: true

require "digest"
require_relative "input"

module RolloutRuleEngine
  module Bucketer
    BASIS_POINTS_MODULUS = 10_000
    MAX_KEY_BYTES = 128
    MAX_SALT_BYTES = 128
    MAX_SUBJECT_ID_BYTES = 256
    MAX_WEIGHTS = 16

    module_function

    def validate_utf8_field!(value, field_name, max_bytes)
      Input.text!(value, field_name, max_bytes)
    end

    def preimage(flag_key:, salt:, subject_id:)
      fields = [
        validate_utf8_field!(flag_key, "flag_key", MAX_KEY_BYTES),
        validate_utf8_field!(salt, "salt", MAX_SALT_BYTES),
        validate_utf8_field!(subject_id, "subject_id", MAX_SUBJECT_ID_BYTES)
      ]
      fields.map { |field| [field.bytesize].pack("N") + field.b }.join.b
    end

    def preimage_hex(**fields)
      preimage(**fields).unpack1("H*")
    end

    def sha256_hex(**fields)
      Digest::SHA256.hexdigest(preimage(**fields))
    end

    def bucket_bps(**fields)
      Digest::SHA256.digest(preimage(**fields)).unpack1("N") % BASIS_POINTS_MODULUS
    end

    def validate_bucket!(bucket)
      unless bucket.is_a?(Integer) && bucket.between?(0, BASIS_POINTS_MODULUS - 1)
        raise InvalidInputError, "bucket_bps must be an Integer in 0..9999"
      end
    end

    def in_threshold?(bucket_bps:, threshold_bps:)
      validate_bucket!(bucket_bps)
      unless threshold_bps.is_a?(Integer) && threshold_bps.between?(0, BASIS_POINTS_MODULUS)
        raise InvalidInputError, "threshold_bps must be an Integer in 0..10000"
      end
      bucket_bps < threshold_bps
    end

    # Internal shared validation; validate the entire distribution before selecting.
    def normalize_weights!(weights, require_total: true)
      unless weights.is_a?(Array) && weights.length.between?(1, MAX_WEIGHTS)
        raise InvalidInputError, "weights must contain 1..#{MAX_WEIGHTS} entries"
      end
      seen = {}
      normalized = weights.map do |entry|
        if defined?(RolloutWeight) && entry.is_a?(RolloutWeight)
          variant = entry.variant
          weight = entry.weight_bps
        elsif entry.is_a?(Hash)
          fields = {}
          entry.each do |key, value|
            key = key.to_s if key.is_a?(Symbol)
            unless %w[variant weight_bps].include?(key) && !fields.key?(key)
              raise InvalidInputError, "Invalid or duplicate weight member"
            end
            fields[key] = value
          end
          variant = fields["variant"]
          weight = fields["weight_bps"]
        else
          raise InvalidInputError, "Weight entry must be an object or RolloutWeight"
        end
        variant = validate_utf8_field!(variant, "weight.variant", MAX_KEY_BYTES).dup.freeze
        unless weight.is_a?(Integer) && weight.between?(0, BASIS_POINTS_MODULUS)
          raise InvalidInputError, "weight_bps must be an Integer in 0..10000"
        end
        raise InvalidInputError, "Duplicate weighted variant" if seen.key?(variant)
        seen[variant] = true
        { "variant" => variant, "weight_bps" => weight }.freeze
      end.freeze
      if require_total && normalized.sum { |entry| entry.fetch("weight_bps") } != BASIS_POINTS_MODULUS
        raise InvalidInputError, "Rollout weights must sum to 10000 basis points"
      end
      normalized
    end

    def select_weighted_variant(bucket_bps:, weights:)
      validate_bucket!(bucket_bps)
      validated = normalize_weights!(weights)
      cursor = 0
      validated.each do |entry|
        cursor += entry.fetch("weight_bps")
        return entry.fetch("variant") if bucket_bps < cursor
      end
      raise ValidationError, "Validated distribution did not cover bucket"
    end
  end
end
