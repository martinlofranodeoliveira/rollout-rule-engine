# frozen_string_literal: true

require "json"
require_relative "errors"

module RolloutRuleEngine
  # Shared input boundaries. This module is internal, not an application API.
  module Input
    MAX_INTEGER_BITS = 1024

    class UniqueObject < Hash
      def []=(key, value)
        raise ParseError, "JSON object contains a duplicate member" if key?(key)

        super
      end
    end

    module_function

    def text!(value, label, max_bytes, min_bytes: 1, error_class: InvalidInputError)
      unless value.is_a?(String) && value.bytesize.between?(min_bytes, max_bytes)
        raise error_class, "#{label} must be a String of #{min_bytes}..#{max_bytes} UTF-8 bytes"
      end
      unless [Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT].include?(value.encoding)
        raise error_class, "#{label} must use UTF-8 encoding"
      end

      normalized = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
      raise error_class, "#{label} contains invalid UTF-8" unless normalized.valid_encoding?

      normalized
    end

    def parse_json(raw, label:, max_bytes:, max_depth:)
      text = text!(raw, label, max_bytes, error_class: ParseError)
      JSON.parse(text, create_additions: false, allow_nan: false,
                 max_nesting: max_depth, object_class: UniqueObject)
    rescue JSON::NestingError
      raise ParseError, "#{label} exceeds nesting limit #{max_depth}"
    rescue JSON::ParserError
      # Parser diagnostics can contain raw input. Keep public errors data-free.
      raise ParseError, "#{label} is not valid JSON"
    end

    def snapshot(value, max_bytes:, max_depth:)
      remaining = max_bytes
      spend = lambda do |bytes|
        remaining -= bytes
        raise ValidationError, "Catalog exceeds byte limit #{max_bytes}" if remaining.negative?
      end
      copy = lambda do |item, depth|
        case item
        when Hash
          raise ValidationError, "Catalog exceeds nesting limit #{max_depth}" if depth >= max_depth
          raise ValidationError, "Catalog object is too large" if item.size > max_bytes / 2
          spend.call(2)
          result = {}
          item.each do |key, child|
            key = key.to_s if key.is_a?(Symbol)
            key = text!(key, "Object member name", max_bytes, min_bytes: 0).dup
            raise ValidationError, "Duplicate member after key normalization" if result.key?(key)
            spend.call(key.bytesize + 4)
            result[key] = copy.call(child, depth + 1)
          end
          result
        when Array
          raise ValidationError, "Catalog exceeds nesting limit #{max_depth}" if depth >= max_depth
          raise ValidationError, "Catalog array is too large" if item.size > max_bytes
          spend.call(2)
          item.map do |child|
            spend.call(1)
            copy.call(child, depth + 1)
          end
        when String
          text = text!(item, "Catalog string", max_bytes, min_bytes: 0)
          spend.call(text.bytesize + 2)
          text.dup
        when Integer
          raise ValidationError, "Integer exceeds #{MAX_INTEGER_BITS}-bit magnitude limit" if item.bit_length > MAX_INTEGER_BITS
          spend.call(item.to_s.bytesize)
          item
        when Float
          raise ValidationError, "Numbers must be finite" unless item.finite?
          spend.call(24)
          item
        when TrueClass, FalseClass, NilClass
          spend.call(5)
          item
        else
          raise ValidationError, "Catalog values must be JSON-compatible"
        end
      end
      result = copy.call(value, 0)
      if JSON.generate(result, max_nesting: max_depth).bytesize > max_bytes
        raise ValidationError, "Catalog exceeds serialized byte limit #{max_bytes}"
      end
      result
    end

    def read_catalog(path, max_bytes:)
      path = text!(path, "Catalog path", 4096)
      raise InvalidInputError, "Catalog path contains a NUL byte" if path.include?("\0")

      # Nonblocking open prevents a supplied FIFO from blocking before fstat.
      File.open(path, File::RDONLY | File::NONBLOCK) do |io|
        stat = io.stat
        raise InvalidInputError, "Catalog must be a regular file" unless stat.file?
        unless stat.size.between?(1, max_bytes)
          raise ParseError, "Catalog file must contain 1..#{max_bytes} bytes"
        end
        # Read a bounded amount from the checked descriptor, even if it grows.
        (io.read(max_bytes + 1) || "").force_encoding(Encoding::UTF_8)
      end
    rescue SystemCallError, IOError
      raise InvalidInputError, "Unable to read regular catalog file"
    end
  end
end
