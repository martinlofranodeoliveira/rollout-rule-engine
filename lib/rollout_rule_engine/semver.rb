# frozen_string_literal: true

require_relative "input"

module RolloutRuleEngine
  class Semver
    include Comparable

    MAX_SEMVER_BYTES = 128
    GRAMMAR = /\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/
    DIGITS = /\A[0-9]+\z/

    attr_reader :raw, :major, :minor, :patch, :prerelease, :build_metadata

    def self.parse(value)
      text = Input.text!(value, "SemVer", MAX_SEMVER_BYTES)
      match = GRAMMAR.match(text)
      raise InvalidInputError, "Invalid SemVer 2.0.0 syntax" unless match

      prerelease = (match[4] || "").split(".").map do |identifier|
        if DIGITS.match?(identifier)
          if identifier.length > 1 && identifier.start_with?("0")
            raise InvalidInputError, "Numeric prerelease identifier has leading zeroes"
          end
          Integer(identifier, 10)
        else
          identifier.freeze
        end
      end.freeze
      build = (match[5] || "").split(".").map(&:freeze).freeze
      new(raw: text.dup.freeze, major: Integer(match[1], 10),
          minor: Integer(match[2], 10), patch: Integer(match[3], 10),
          prerelease: prerelease, build_metadata: build)
    end

    def self.try_parse(value)
      parse(value)
    rescue ValidationError
      nil
    end

    def self.valid?(value)
      !try_parse(value).nil?
    end

    def self.valid_utf8?(value)
      return false unless value.is_a?(String)
      return false unless [Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT].include?(value.encoding)

      value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    def initialize(raw:, major:, minor:, patch:, prerelease:, build_metadata:)
      @raw = raw
      @major = major
      @minor = minor
      @patch = patch
      @prerelease = prerelease
      @build_metadata = build_metadata
      freeze
    end
    private_class_method :new

    def <=>(other)
      return nil unless other.is_a?(Semver)

      core = [major, minor, patch] <=> [other.major, other.minor, other.patch]
      return core unless core.zero?
      return 0 if prerelease.empty? && other.prerelease.empty?
      return 1 if prerelease.empty?
      return -1 if other.prerelease.empty?

      [prerelease.length, other.prerelease.length].min.times do |index|
        left = prerelease[index]
        right = other.prerelease[index]
        comparison = if left.is_a?(Integer) && right.is_a?(String)
                       -1
                     elsif left.is_a?(String) && right.is_a?(Integer)
                       1
                     else
                       left <=> right
                     end
        return comparison unless comparison.zero?
      end
      prerelease.length <=> other.prerelease.length
    end

    def to_s
      raw
    end
  end
end
