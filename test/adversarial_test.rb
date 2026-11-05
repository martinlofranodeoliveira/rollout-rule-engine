# frozen_string_literal: true

require "stringio"
require "tempfile"
require_relative "test_helper"

module ReviewFixtures
  module_function

  def flag
    { "enabled" => true, "default_variant" => "off" }
  end

  def catalog(definition = flag)
    { "flags" => { "f" => definition } }
  end

  def condition(operator = "equals", value = 10)
    { "attribute" => "v", "operator" => operator, "value" => value }
  end

  def targeted(operator = "equals", value = 10)
    flag.merge("rules" => [{ "id" => "r", "variant" => "on", "conditions" => [condition(operator, value)] }])
  end

  def engine(definition = flag)
    RolloutRuleEngine::Engine.new(RolloutRuleEngine::Catalog.from_h(catalog(definition)))
  end

  def chain(edges, reverse: false)
    flags = (0..edges).to_h do |index|
      definition = flag
      if index < edges
        definition["prerequisites"] = [{ "flag_key" => "n#{index + 1}", "variant" => "off" }]
      end
      ["n#{index}", definition]
    end
    flags = flags.to_a.reverse.to_h if reverse
    { "flags" => flags }
  end

  def diamond
    flags = { "leaf_0" => flag }
    (1..12).each do |level|
      %w[left right].each do |side|
        flags["#{side}_#{level}"] = flag.merge("prerequisites" => [
          { "flag_key" => "leaf_#{level - 1}", "variant" => "off" }
        ])
      end
      flags["leaf_#{level}"] = flag.merge("prerequisites" => [
        { "flag_key" => "left_#{level}", "variant" => "off" },
        { "flag_key" => "right_#{level}", "variant" => "off" }
      ])
    end
    { "flags" => flags }
  end

  def cli(args)
    out = StringIO.new
    err = StringIO.new
    [RolloutRuleEngine::CLI.run(args, stdout: out, stderr: err), out.string, err.string]
  end
end

TestHarness.define_suite("Independent adversarial boundaries") do
  test("every operator handles absence, null, positive, negative and wrong-type inputs") do
    rows = [
      ["equals", 10, 10, 11, "10"],
      ["not_equals", 10, 11, 10, 10.0],
      ["in", [10, 20], 20, 30, "20"],
      ["not_in", [10, 20], 30, 20, 20.0],
      ["numeric_gt", 10, 10.5, 10, true],
      ["numeric_gte", 10, 10.0, 9, "10"],
      ["numeric_lt", 10, 9.5, 10, false],
      ["numeric_lte", 10, 10.0, 11, []],
      ["semver_eq", "1.10.0+one", "1.10.0+two", "1.10.1", 10],
      ["semver_gte", "1.2.0", "1.10.0", "1.1.99", {}],
      ["semver_lt", "1.0.0", "1.0.0-rc.1", "1.0.0", true]
    ]
    rows.each do |operator, target, positive, negative, wrong|
      engine = ReviewFixtures.engine(ReviewFixtures.targeted(operator, target))
      [{}, { "v" => nil }].each do |attributes|
        result = engine.evaluate(flag_key: "f", subject_id: "synthetic", attributes: attributes)
        assert_equal("off", result.resolved_variant)
        assert_equal("missing_attribute", result.trace.first.fetch("reason"))
      end
      [[positive, "on", "condition_matched"], [negative, "off", "predicate_failed"],
       [wrong, "off", "type_mismatch"]].each do |actual, variant, reason|
        result = engine.evaluate(flag_key: "f", subject_id: "synthetic", attributes: { "v" => actual })
        assert_equal(variant, result.resolved_variant, operator)
        assert_equal(reason, result.trace.first.fetch("conditions").first.fetch("reason"), operator)
      end
    end
    boolean = ReviewFixtures.engine(ReviewFixtures.targeted("not_equals", true))
    assert_equal("on", boolean.evaluate(flag_key: "f", subject_id: "s", attributes: { "v" => false }).resolved_variant)
    %w[semver_eq semver_gte semver_lt].each do |operator|
      result = ReviewFixtures.engine(ReviewFixtures.targeted(operator, "1.0.0")).evaluate(
        flag_key: "f", subject_id: "s", attributes: { "v" => "1.0.0-01" }
      )
      assert_equal("invalid_semver", result.trace.first.fetch("reason"))
    end
  end

  test("attribute bounds apply even to unused values and composite values are opaque mismatches") do
    engine = ReviewFixtures.engine(ReviewFixtures.targeted("not_equals", "usuário"))
    result = engine.evaluate(flag_key: "f", subject_id: "s", attributes: { "v" => "usuário".b })
    assert_equal("off", result.resolved_variant)
    assert_equal("predicate_failed", result.trace.first.fetch("reason"))
    cyclic = []
    cyclic << cyclic
    [cyclic, { "raw" => "not-retained" }, Object.new, Float::NAN, Float::INFINITY].each do |value|
      result = engine.evaluate(flag_key: "f", subject_id: "s", attributes: { "v" => value })
      assert_equal("type_mismatch", result.trace.first.fetch("reason"))
      refute(result.to_json.include?("not-retained"))
    end
    [{ "unused" => "x" * 1025 }, { "unused" => [255].pack("C*") },
     { "unused" => 1 << 1024 }, { "v" => 1, v: 2 }, { 1 => "x" },
     (1..129).to_h { |index| ["a#{index}", 0] }].each do |attributes|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        engine.evaluate(flag_key: "f", subject_id: "s", attributes: attributes)
      end
    end
    valid = (1..128).to_h { |index| ["a#{index}", "x" * 1024] }
    assert_equal("off", engine.evaluate(flag_key: "f", subject_id: "s", attributes: valid).resolved_variant)
  end

  test("rejects duplicate JSON members, unknown members, alias conflicts and false optional arrays") do
    duplicates = [
      '{"flags":{"f":{"enabled":true,"enabled":false,"default_variant":"off"}}}',
      '{"flags":{"f":{"enabled":true,"default_variant":"off"},"f":{"enabled":false,"default_variant":"on"}}}'
    ]
    duplicates.each do |raw|
      assert_raises(RolloutRuleEngine::ParseError) { RolloutRuleEngine::Catalog.from_json(raw) }
    end
    base = ReviewFixtures.flag
    invalid = [
      ReviewFixtures.catalog.merge("unexpected" => 1),
      ReviewFixtures.catalog.merge("schema_version" => nil),
      ReviewFixtures.catalog.merge("schema_version" => false),
      ReviewFixtures.catalog(base.merge("enable" => false)),
      ReviewFixtures.catalog(base.merge("enabled" => 1)),
      ReviewFixtures.catalog(base.merge("rules" => false)),
      ReviewFixtures.catalog(base.merge("prerequisites" => false)),
      ReviewFixtures.catalog(base.merge("key" => "other")),
      ReviewFixtures.catalog(base.merge("key" => "f", "flag_key" => "f")),
      ReviewFixtures.catalog(base.merge("rollout" => { "active" => nil })),
      ReviewFixtures.catalog(base.merge("rollout" => { "active" => false, "typo" => 1 })),
      ReviewFixtures.catalog(base.merge("rollout" => { "active" => false, "weights" => [{ "variant" => "x", "weight_bps" => -1 }] })),
      ReviewFixtures.catalog(base.merge("prerequisites" => [{ "flag_key" => "f", "variant" => "off", "typo" => 1 }])),
      ReviewFixtures.catalog(base.merge("rules" => [{ "id" => "r", "variant" => "on", "conditions" => [], "typo" => 1 }])),
      ReviewFixtures.catalog(base.merge("rules" => [{ "id" => "r", "variant" => "on", "conditions" => [ReviewFixtures.condition.merge("typo" => 1)] }]))
    ]
    invalid.each do |raw|
      assert_raises(RolloutRuleEngine::ValidationError) { RolloutRuleEngine::Catalog.from_h(raw) }
    end
    assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_h({ "flags" => { "f" => base }, flags: { "g" => base } })
    end
    aliases = { flags: [{ key: "f", enabled: true, default_variant: "off", rules: nil, prerequisites: nil,
                          rollout: { active: false, weights: [{ variant: "on", weight_bps: 1 }] } }] }
    assert_equal(["f"], RolloutRuleEngine::Catalog.from_h(aliases).flag_keys)
  end

  test("uses real nested JSON and bounds direct Hash input, integers, and non-finite numbers") do
    nested = "[" * 17 + "0" + "]" * 17
    error = assert_raises(RolloutRuleEngine::ParseError) { RolloutRuleEngine::Catalog.from_json(nested) }
    assert_includes(error.message, "nesting")
    cycle = {}
    cycle["self"] = cycle
    [cycle, ReviewFixtures.catalog.merge("extra" => "x" * 262_145),
     ReviewFixtures.catalog(ReviewFixtures.targeted("equals", 1 << 1024)),
     ReviewFixtures.catalog(ReviewFixtures.targeted("numeric_gt", Float::INFINITY)),
     ReviewFixtures.catalog(ReviewFixtures.targeted("equals", Object.new))].each do |raw|
      assert_raises(RolloutRuleEngine::ValidationError) { RolloutRuleEngine::Catalog.from_h(raw) }
    end
    assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_json('{"flags":{"f":{"enabled":true,"default_variant":"off","rules":[{"id":"r","variant":"on","conditions":[{"attribute":"v","operator":"numeric_gt","value":1e9999}]}]}}}')
    end
  end

  test("validates entire weighted distributions before selection and rejects malformed public input") do
    bad = [nil, [], [Object.new], [{ "variant" => "on", "weight_bps" => nil }],
           [{ "variant" => "on", "weight_bps" => 10_001 }],
           [{ "variant" => "on", "weight_bps" => 9999 }],
           [{ "variant" => "on", "weight_bps" => 10_000 }, { "variant" => "bad", "weight_bps" => -1 }],
           [{ "variant" => "on", "weight_bps" => 5000 }, { "variant" => "on", "weight_bps" => 5000 }],
           [{ "variant" => "on", variant: "on", "weight_bps" => 10_000 }],
           [{ "variant" => "on", "weight_bps" => 10_000, "typo" => 0 }],
           (1..17).map { |index| { "variant" => "v#{index}", "weight_bps" => 0 } }]
    bad.each do |weights|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.select_weighted_variant(bucket_bps: 0, weights: weights)
      end
    end
    [-1, 10_000, 1.0, true, nil].each do |bucket|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.in_threshold?(bucket_bps: bucket, threshold_bps: 1000)
      end
    end
    [-1, 10_001, 1.0, true].each do |threshold|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.in_threshold?(bucket_bps: 0, threshold_bps: threshold)
      end
    end
  end

  test("enforces exact and one-over DAG depth in both catalog declaration orders") do
    [false, true].each do |reverse|
      catalog = RolloutRuleEngine::Catalog.from_h(ReviewFixtures.chain(32, reverse: reverse))
      result = RolloutRuleEngine::Engine.new(catalog).evaluate(flag_key: "n0", subject_id: "s")
      assert_equal("off", result.resolved_variant)
      assert_equal(32, result.prerequisite_trace.size)
      error = assert_raises(RolloutRuleEngine::ValidationError) do
        RolloutRuleEngine::Catalog.from_h(ReviewFixtures.chain(33, reverse: reverse))
      end
      assert_includes(error.message, "32 edges")
    end
  end

  test("12-level diamond evaluates each flag exactly once per query, without cross-query caching") do
    catalog = RolloutRuleEngine::Catalog.from_h(ReviewFixtures.diamond)
    engine = RolloutRuleEngine::Engine.new(catalog)
    counts = Hash.new(0)
    probe = TracePoint.new(:call) do |event|
      if event.defined_class == RolloutRuleEngine::Catalog && event.method_id == :fetch && event.self.equal?(catalog)
        counts[event.binding.local_variable_get(:flag_key)] += 1
      end
    end
    result = nil
    probe.enable do
      result = engine.evaluate(flag_key: "leaf_12", subject_id: "synthetic-diamond")
    end
    assert_equal(37, counts.size)
    assert_equal([1], counts.values.uniq)
    assert_equal(36, result.prerequisite_trace.size)
    assert_equal(36, result.prerequisite_trace.map { |entry| entry.fetch("flag_key") }.uniq.size)
    probe.enable { engine.evaluate(flag_key: "leaf_12", subject_id: "synthetic-diamond") }
    assert_equal([2], counts.values.uniq)
    counts.clear
    all = nil
    probe.enable { all = engine.evaluate_all(subject_id: "synthetic-diamond") }
    assert_equal(37, all.size)
    assert_equal(37, counts.size)
    assert_equal([1], counts.values.uniq)
    assert_equal([], all.fetch("leaf_0").prerequisite_trace)
  end

  test("prerequisite failure includes complete flat dependency decisions but skips subsequent dependencies") do
    flags = {
      "parent" => ReviewFixtures.flag.merge("prerequisites" => [
        { "flag_key" => "child", "variant" => "on" }, { "flag_key" => "skipped", "variant" => "on" }
      ]),
      "child" => ReviewFixtures.targeted("equals", "private-operand"),
      "skipped" => ReviewFixtures.flag
    }
    engine = RolloutRuleEngine::Engine.new(RolloutRuleEngine::Catalog.from_h({ "flags" => flags }))
    result = engine.evaluate(flag_key: "parent", subject_id: "private-subject", attributes: { "v" => "private-actual" })
    assert_equal("prerequisite_failed", result.reason)
    assert_equal("child", result.failed_prerequisite_key)
    assert_equal([], result.trace)
    assert_equal(["child"], result.prerequisites.map { |entry| entry.fetch("flag_key") })
    child = result.prerequisite_trace.fetch(0)
    assert_equal("child", child.fetch("flag_key"))
    assert_equal("predicate_failed", child.fetch("trace").first.fetch("reason"))
    refute(child.key?("prerequisite_trace"))
    %w[private-subject private-actual private-operand].each { |secret| refute(result.to_json.include?(secret)) }
    flags["parent"]["enabled"] = false
    disabled = RolloutRuleEngine::Engine.new(RolloutRuleEngine::Catalog.from_h({ "flags" => flags })).evaluate(
      flag_key: "parent", subject_id: "s"
    )
    assert_equal("flag_disabled", disabled.reason)
    assert_equal([], disabled.prerequisites)
    assert_equal([], disabled.prerequisite_trace)
  end

  test("maximum rule trace is complete and count limits reject one-over cases") do
    conditions = Array.new(15) { ReviewFixtures.condition("equals", true) } + [ReviewFixtures.condition("equals", false)]
    rules = (1..64).map { |index| { "id" => "r#{index}", "variant" => "on", "conditions" => conditions } }
    definition = ReviewFixtures.flag.merge("rules" => rules)
    result = ReviewFixtures.engine(definition).evaluate(flag_key: "f", subject_id: "s", attributes: { "v" => true })
    assert_equal("default_fallback", result.reason)
    assert_equal(64, result.trace.size)
    assert_equal(1024, result.trace.sum { |entry| entry.fetch("conditions").size })
    assert_equal([15], result.trace.map { |entry| entry.fetch("failed_condition_index") }.uniq)
    too_many_rules = ReviewFixtures.catalog(definition.merge("rules" => rules + [rules.first.merge("id" => "extra")]))
    too_many_conditions = ReviewFixtures.catalog(ReviewFixtures.flag.merge("rules" => [rules.first.merge("conditions" => conditions + [conditions.first])]))
    too_many_flags = { "flags" => (1..101).to_h { |index| ["f#{index}", ReviewFixtures.flag] } }
    too_many_prerequisites = ReviewFixtures.catalog(ReviewFixtures.flag.merge("prerequisites" =>
      (1..17).map { |index| { "flag_key" => "f#{index}", "variant" => "off" } }))
    too_many_items = ReviewFixtures.catalog(ReviewFixtures.targeted("in", (1..65).to_a))
    [too_many_rules, too_many_conditions, too_many_flags, too_many_prerequisites, too_many_items].each do |raw|
      assert_raises(RolloutRuleEngine::ValidationError) { RolloutRuleEngine::Catalog.from_h(raw) }
    end
  end

  test("CLI handles write, flush and diagnostic writer failures without native errors") do
    flush_failure = Object.new
    def flush_failure.puts(*) = nil
    def flush_failure.flush = raise(IOError, "SYNTHETIC_PRIVATE_WRITER")
    error = StringIO.new
    assert_equal(1, RolloutRuleEngine::CLI.run(["--help"], stdout: flush_failure, stderr: error))
    refute(error.string.include?("SYNTHETIC_PRIVATE_WRITER"))
    write_failure = Object.new
    def write_failure.puts(*) = raise(IOError, "SYNTHETIC_PRIVATE_WRITER")
    assert_equal(1, RolloutRuleEngine::CLI.run(["unknown"], stdout: StringIO.new, stderr: write_failure))
  end

  test("catalog, parsed versions, cycle diagnostics and returned decisions are deeply immutable") do
    original_version = +"1.2.0"
    refute(original_version.frozen?)
    raw = ReviewFixtures.catalog(ReviewFixtures.targeted("semver_gte", original_version))
    catalog = RolloutRuleEngine::Catalog.from_h(raw)
    refute(original_version.frozen?, "Loading must not freeze caller-owned strings")
    raw.fetch("flags").fetch("f").fetch("rules").first.fetch("conditions").first["value"].replace("9.0.0")
    result = RolloutRuleEngine::Engine.new(catalog).evaluate(flag_key: "f", subject_id: "s", attributes: { "v" => "1.10.0" })
    assert_equal("on", result.resolved_variant)
    check = lambda do |value|
      assert(value.frozen?, "Expected deeply frozen #{value.class}")
      case value
      when Hash
        value.each { |key, child| check.call(key); check.call(child) }
      when Array
        value.each { |child| check.call(child) }
      when Data
        value.to_h.each_value { |child| check.call(child) }
      end
    end
    check.call(catalog.flags)
    parsed = catalog.flags.fetch("f").rules.first.conditions.first.parsed_semver
    [parsed, parsed.raw, parsed.prerelease, parsed.build_metadata].each { |value| assert(value.frozen?) }
    check.call(result.to_h)
    assert_raises(FrozenError) { result.trace.first.fetch("conditions").clear }
    assert_raises(NoMethodError) { RolloutRuleEngine::Catalog.new(schema_version: "1.0", flags: {}) }
    cycle = ReviewFixtures.catalog(ReviewFixtures.flag.merge("enabled" => false, "prerequisites" => [{ "flag_key" => "f", "variant" => "off" }]))
    error = assert_raises(RolloutRuleEngine::CycleDetectedError) { RolloutRuleEngine::Catalog.from_h(cycle) }
    assert_equal(["f", "f"], error.cycle_path)
    check.call(error.cycle_path)
  end

  test("file reader and CLI return bounded structured errors, not backtraces or raw parser data") do
    Tempfile.create(["rollout-synthetic-", ".json"]) do |file|
      file.write(JSON.generate(ReviewFixtures.catalog))
      file.flush
      assert_equal(["f"], RolloutRuleEngine::Catalog.load_file(file.path).flag_keys)
      code, out, err = ReviewFixtures.cli(["validate", file.path])
      assert_equal(0, code)
      assert_equal(true, JSON.parse(out).fetch("valid"))
      assert_equal("", err)
      failures = [
        ["validate", file.path, "extra"],
        ["demo", "--catalog", file.path],
        ["evaluate", "--catalog", file.path, "--flag", "f", "--subject", "s", "--attributes", '{"v":1,"v":2}'],
        ["evaluate", "--catalog", file.path, "--flag", "f", "--subject", "s", "--attributes", '{"private-parser-token":'],
        ["bucket", "--flag", "f", "--flag", "g", "--salt", "s", "--subject", "s"],
        ["demo", "--format"], ["demo", "--text", "--format", "json"], ["demo", "--catalog"],
        ["help", "extra"], ["unknown"], ["bucket", "--flag", [255].pack("C*")]
      ]
      failures.each do |args|
        code, out, err = ReviewFixtures.cli(args)
        assert_equal(1, code)
        assert_equal("", out)
        parsed = JSON.parse(err)
        assert(parsed.fetch("error").start_with?("RolloutRuleEngine::"))
        refute(err.include?("private-parser-token"))
        refute(err.include?("backtrace"))
      end
      file.rewind
      file.truncate(0)
      file.write(" " * 262_145)
      file.flush
      assert_raises(RolloutRuleEngine::ParseError) { RolloutRuleEngine::Catalog.load_file(file.path) }
    end
    [__dir__, "test/nonexistent-synthetic-catalog.json", "bad\0path"].each do |path|
      assert_raises(RolloutRuleEngine::InvalidInputError) { RolloutRuleEngine::Catalog.load_file(path) }
    end
    code, out, err = ReviewFixtures.cli(Array.new(33, "demo"))
    assert_equal(1, code)
    assert_equal("", out)
    assert_includes(err, "32")
  end

  test("demo is byte-deterministic and distribution totals agree with anchored variant counts") do
    first = ReviewFixtures.cli(["demo"])
    second = ReviewFixtures.cli(["demo"])
    assert_equal(first, second)
    assert_equal(0, first.fetch(0))
    report = JSON.parse(first.fetch(1))
    distribution = report.fetch("bucket_distribution")
    assert_equal(200, distribution.fetch("quartiles").values.sum)
    assert_equal(200, distribution.fetch("variant_counts").values.sum)
    assert_equal(distribution.fetch("quartiles").fetch("q1_0_2499"), distribution.fetch("variant_counts").fetch("express", 0))
    assert_equal(distribution.fetch("quartiles").fetch("q1_0_2499"), distribution.fetch("monotonic_threshold_counts").fetch("2500"))
    enterprise = report.fetch("sample_evaluations").first.fetch("results")
    assert_equal("one_click", enterprise.fetch("checkout").fetch("resolved_variant"))
    assert_equal("enabled", enterprise.fetch("instant_settlement").fetch("resolved_variant"))
    assert_equal("flag_disabled", enterprise.fetch("seasonal_banner").fetch("reason"))
    code, out, err = ReviewFixtures.cli(["demo", "--format", "text"])
    assert_equal(0, code)
    assert_equal("", err)
    assert_includes(out, "rule-enterprise-br")
    assert_includes(out, "condition_index")
    assert_includes(out, "Bucket distribution")
  end
end
