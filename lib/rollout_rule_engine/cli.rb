# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "engine"

module RolloutRuleEngine
  class CLI
    DEFAULT_DEMO_CATALOG = File.expand_path("../../data/demo_catalog.json", __dir__).freeze
    DEMO_COHORT_SIZE = 200
    MAX_ARGUMENT_BYTES = 262_144

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdout: $stdout, stderr: $stderr)
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      unless argv.is_a?(Array) && argv.size <= 32 && argv.all? { |arg| arg.is_a?(String) }
        raise InvalidInputError, "Expected at most 32 String arguments"
      end
      raise InvalidInputError, "Argument byte limit exceeded" if argv.sum(&:bytesize) > MAX_ARGUMENT_BYTES
      args = argv.map { |arg| Input.text!(arg, "Argument", MAX_ARGUMENT_BYTES, min_bytes: 0) }
      command = args.shift || "demo"
      status = case command
      when "demo" then run_demo(args)
      when "validate" then run_validate(args)
      when "evaluate" then run_evaluate(args)
      when "bucket" then run_bucket(args)
      when "--help", "-h", "help"
        raise InvalidInputError, "Help takes no additional arguments" unless args.empty?
        print_usage
        0
      else
        raise InvalidInputError, "Unknown command; use --help"
      end
      @stdout.flush if @stdout.respond_to?(:flush)
      status
    rescue Error => error
      begin
        @stderr.puts(JSON.generate({ "error" => error.class.name, "message" => error.message }))
        @stderr.flush if @stderr.respond_to?(:flush)
      rescue SystemCallError, IOError
        # Diagnostics cannot be guaranteed when their writer has also failed.
      end
      1
    rescue SystemCallError, IOError
      # A broken output pipe is an ordinary CLI failure, not a Ruby backtrace.
      1
    end

    private

    def parse_options(args, allowed)
      options = {}
      until args.empty?
        option = args.shift
        raise InvalidInputError, "Unknown option" unless allowed.include?(option)
        raise InvalidInputError, "Duplicate option: #{option}" if options.key?(option)
        if option == "--text"
          options[option] = true
        else
          value = args.shift
          raise InvalidInputError, "Missing value for #{option}" if value.nil?
          options[option] = value
        end
      end
      options
    end

    def required(options, key)
      options.fetch(key) { raise InvalidInputError, "Missing #{key}" }
    end

    def run_demo(args)
      options = parse_options(args, %w[--format --text --catalog])
      if options.key?("--format") && options.key?("--text")
        raise InvalidInputError, "Use only one demo format option"
      end
      output_format = options["--text"] ? "text" : options.fetch("--format", "json")
      raise InvalidInputError, "Demo format must be json or text" unless %w[json text].include?(output_format)
      engine = Engine.load_file(options.fetch("--catalog", DEFAULT_DEMO_CATALOG))
      report = build_demo_report(engine)
      @stdout.puts(output_format == "text" ? render_text_report(report) : JSON.pretty_generate(report))
      0
    end

    def run_validate(args)
      unless args.length == 1
        raise InvalidInputError, "Usage: rollout-engine validate <catalog.json>"
      end
      catalog = Catalog.load_file(args.fetch(0))
      @stdout.puts(JSON.pretty_generate({ "valid" => true, "schema_version" => catalog.schema_version,
                                         "flag_count" => catalog.flag_keys.length, "flag_keys" => catalog.flag_keys }))
      0
    end

    def run_evaluate(args)
      options = parse_options(args, %w[--catalog --flag --subject --attributes])
      path = required(options, "--catalog")
      flag = required(options, "--flag")
      subject = required(options, "--subject")
      attributes = Input.parse_json(options.fetch("--attributes", "{}"), label: "Attributes JSON",
                                    max_bytes: MAX_ARGUMENT_BYTES, max_depth: 4)
      raise InvalidInputError, "Attributes JSON must be an object" unless attributes.is_a?(Hash)
      result = Engine.load_file(path).evaluate(flag_key: flag, subject_id: subject, attributes: attributes)
      @stdout.puts(JSON.pretty_generate(result.to_h))
      0
    end

    def run_bucket(args)
      options = parse_options(args, %w[--flag --salt --subject])
      fields = { flag_key: required(options, "--flag"), salt: required(options, "--salt"),
                 subject_id: required(options, "--subject") }
      preimage = Bucketer.preimage(**fields)
      digest = Digest::SHA256.digest(preimage)
      @stdout.puts(JSON.pretty_generate({ "flag_key" => fields.fetch(:flag_key), "salt" => fields.fetch(:salt),
                                         "subject_id" => fields.fetch(:subject_id), "preimage_hex" => preimage.unpack1("H*"),
                                         "sha256" => digest.unpack1("H*"), "bucket_bps" => digest.unpack1("N") % 10_000 }))
      0
    end

    def build_demo_report(engine)
      required_keys = %w[platform_api checkout instant_settlement seasonal_banner]
      unless required_keys.all? { |key| engine.catalog.key?(key) } && engine.catalog.flags.fetch("checkout").rollout
        raise InvalidInputError, "Demo catalog must provide the four demo flags and an active checkout rollout"
      end
      profiles = [
        ["enterprise_br_modern_client", "synthetic-subject-1", "br-south", "enterprise", "1.10.0", 45],
        ["pro_high_volume_client", "synthetic-subject-2", "us-east", "pro", "1.4.2", 120],
        ["standard_rollout_candidate", "synthetic-subject-3", "eu-central", "starter", "1.3.0", 8],
        ["outdated_client_prerequisite_blocked", "synthetic-subject-4", "br-south", "enterprise", "0.9.5", 60]
      ]
      samples = profiles.map do |label, subject, region, plan, version, orders|
        attributes = { "region" => region, "plan_tier" => plan, "app_version" => version, "monthly_orders" => orders }
        { "cohort_label" => label, "results" => engine.evaluate_all(subject_id: subject, attributes: attributes).transform_values(&:to_h) }
      end
      buckets = []
      variants = Hash.new(0)
      quartiles = { "q1_0_2499" => 0, "q2_2500_4999" => 0, "q3_5000_7499" => 0, "q4_7500_9999" => 0 }
      DEMO_COHORT_SIZE.times do |index|
        result = engine.evaluate(flag_key: "checkout", subject_id: format("synthetic-cohort-%03d", index + 1),
                                 attributes: { "region" => "eu-central", "plan_tier" => "starter",
                                               "app_version" => "1.2.0", "monthly_orders" => 5 })
        unless result.reason == "percentage_rollout"
          raise InvalidInputError, "Demo catalog must route synthetic cohort queries to checkout percentage_rollout"
        end
        bucket = result.bucket_bps
        buckets << bucket
        variants[result.resolved_variant] += 1
        quartiles[quartiles.keys.fetch(bucket / 2500)] += 1
      end
      sorted = buckets.sort
      {
        "engine_version" => VERSION, "schema_version" => engine.catalog.schema_version,
        "flag_keys" => engine.catalog.flag_keys, "sample_evaluations" => samples,
        "bucket_distribution" => {
          "flag_key" => "checkout", "salt" => engine.catalog.flags.fetch("checkout").rollout.salt,
          "cohort_size" => DEMO_COHORT_SIZE, "min_bucket_bps" => sorted.first,
          "max_bucket_bps" => sorted.last, "median_bucket_bps" => sorted.fetch(DEMO_COHORT_SIZE / 2),
          "quartiles" => quartiles, "variant_counts" => variants,
          "monotonic_threshold_counts" => [1000, 2500, 5000, 7500].to_h do |threshold|
            [threshold.to_s, buckets.count { |bucket| bucket < threshold }]
          end
        }
      }
    end

    def render_text_report(report)
      lines = ["rollout-rule-engine v#{VERSION} offline demo", "Flags loaded: #{JSON.generate(report.fetch('flag_keys'))}"]
      report.fetch("sample_evaluations").each do |entry|
        lines << "[#{entry.fetch('cohort_label')}]"
        entry.fetch("results").each do |key, result|
          lines << "  #{JSON.generate(key)}: variant=#{JSON.generate(result.fetch('resolved_variant'))} reason=#{result.fetch('reason')} bucket=#{result.fetch('bucket_bps') || '-'}"
          lines << "    rules: #{JSON.generate(result.fetch('trace'))}"
          lines << "    prerequisites: #{JSON.generate(result.fetch('prerequisites'))}"
          lines << "    dependency decisions: #{JSON.generate(result.fetch('prerequisite_trace'))}"
        end
      end
      lines << "Bucket distribution (synthetic data; not a benchmark):"
      lines << JSON.pretty_generate(report.fetch("bucket_distribution"))
      lines.join("\n")
    end

    def print_usage
      @stdout.puts(<<~USAGE)
        Usage:
          rollout-engine demo [--format json|text | --text] [--catalog <path>]
          rollout-engine validate <catalog.json>
          rollout-engine evaluate --catalog <path> --flag <key> --subject <id> [--attributes <json>]
          rollout-engine bucket --flag <key> --salt <salt> --subject <id>
      USAGE
    end
  end
end
