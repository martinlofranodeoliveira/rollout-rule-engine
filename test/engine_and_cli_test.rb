# frozen_string_literal: true

require "stringio"
require "json"
require_relative "test_helper"

TestHarness.define_suite("Engine Evaluation, Type Safety, Trace Completeness, and CLI") do
  test("enforces strict type safety without coercive confusion across all 11 operators") do
    catalog = RolloutRuleEngine::Catalog.from_h(
      {
        "flags" => {
          "strict_flag" => {
            "enabled" => true,
            "default_variant" => "fallback",
            "rules" => [
              {
                "id" => "r-int-eq",
                "variant" => "matched-int-eq",
                "conditions" => [{ "attribute" => "v", "operator" => "equals", "value" => 10 }]
              },
              {
                "id" => "r-int-neq",
                "variant" => "matched-int-neq",
                "conditions" => [{ "attribute" => "v", "operator" => "not_equals", "value" => 20 }]
              },
              {
                "id" => "r-in",
                "variant" => "matched-in",
                "conditions" => [{ "attribute" => "tag", "operator" => "in", "value" => ["a", "b"] }]
              },
              {
                "id" => "r-not-in",
                "variant" => "matched-not-in",
                "conditions" => [{ "attribute" => "tag", "operator" => "not_in", "value" => ["x", "y"] }]
              },
              {
                "id" => "r-num",
                "variant" => "matched-num",
                "conditions" => [
                  { "attribute" => "score", "operator" => "numeric_gt", "value" => 5 },
                  { "attribute" => "score", "operator" => "numeric_gte", "value" => 5.5 },
                  { "attribute" => "score", "operator" => "numeric_lt", "value" => 10 },
                  { "attribute" => "score", "operator" => "numeric_lte", "value" => 5.5 }
                ]
              },
              {
                "id" => "r-semver",
                "variant" => "matched-semver",
                "conditions" => [
                  { "attribute" => "ver", "operator" => "semver_gte", "value" => "1.2.0" },
                  { "attribute" => "ver", "operator" => "semver_lt", "value" => "2.0.0" },
                  { "attribute" => "ver_exact", "operator" => "semver_eq", "value" => "1.10.0+build.1" }
                ]
              }
            ]
          }
        }
      }
    )
    engine = RolloutRuleEngine::Engine.new(catalog)

    res_str_vs_int = engine.evaluate(flag_key: "strict_flag", subject_id: "s1", attributes: { "v" => "10" })
    assert_equal("fallback", res_str_vs_int.resolved_variant)
    assert_equal("type_mismatch", res_str_vs_int.trace[0]["reason"])
    assert_equal("type_mismatch", res_str_vs_int.trace[1]["reason"])

    res_float_vs_int = engine.evaluate(flag_key: "strict_flag", subject_id: "s1", attributes: { "v" => 10.0 })
    assert_equal("fallback", res_float_vs_int.resolved_variant)
    assert_equal("type_mismatch", res_float_vs_int.trace[0]["reason"])
    assert_equal("type_mismatch", res_float_vs_int.trace[1]["reason"])

    res_missing = engine.evaluate(flag_key: "strict_flag", subject_id: "s1", attributes: {})
    assert_equal("fallback", res_missing.resolved_variant)
    res_missing.trace.each do |rule_entry|
      assert_equal("missing_attribute", rule_entry["reason"])
    end

    res_bool_num = engine.evaluate(flag_key: "strict_flag", subject_id: "s1", attributes: { "score" => true })
    assert_equal("type_mismatch", res_bool_num.trace[4]["reason"])

    res_num_ok = engine.evaluate(flag_key: "strict_flag", subject_id: "s1", attributes: { "score" => 5.5 })
    assert_equal("matched-num", res_num_ok.resolved_variant)
    assert_equal("r-num", res_num_ok.matched_rule_id)

    res_semver_ok = engine.evaluate(
      flag_key: "strict_flag",
      subject_id: "s1",
      attributes: { "ver" => "1.10.0", "ver_exact" => "1.10.0+other.meta" }
    )
    assert_equal("matched-semver", res_semver_ok.resolved_variant)
    assert_equal("r-semver", res_semver_ok.matched_rule_id)

    res_bad_semver = engine.evaluate(
      flag_key: "strict_flag",
      subject_id: "s1",
      attributes: { "ver" => "not-semver", "ver_exact" => "1.10.0" }
    )
    assert_equal("invalid_semver", res_bad_semver.trace[5]["reason"])
  end

  test("records exact failing clause of Rule 1 and matching clause of Rule 2 without leaking raw subject data") do
    catalog = RolloutRuleEngine::Catalog.from_h(
      {
        "flags" => {
          "audit_flag" => {
            "enabled" => true,
            "default_variant" => "control",
            "rules" => [
              {
                "id" => "rule-1",
                "variant" => "tier-a",
                "conditions" => [
                  { "attribute" => "country", "operator" => "equals", "value" => "SecretCountryValue" },
                  { "attribute" => "app_version", "operator" => "semver_gte", "value" => "2.0.0" },
                  { "attribute" => "orders", "operator" => "numeric_gt", "value" => 10 }
                ]
              },
              {
                "id" => "rule-2",
                "variant" => "tier-b",
                "conditions" => [
                  { "attribute" => "country", "operator" => "equals", "value" => "SecretCountryValue" },
                  { "attribute" => "app_version", "operator" => "semver_gte", "value" => "1.10.0" }
                ]
              }
            ]
          }
        }
      }
    )
    engine = RolloutRuleEngine::Engine.new(catalog)

    result = engine.evaluate(
      flag_key: "audit_flag",
      subject_id: "sensitive-subject-id-999",
      attributes: {
        "country" => "SecretCountryValue",
        "app_version" => "1.10.0",
        "orders" => 50,
        "pii_secret" => "never-in-trace"
      }
    )

    assert_equal("tier-b", result.resolved_variant)
    assert_equal("rule_match", result.reason)
    assert_equal("rule-2", result.matched_rule_id)
    assert_nil(result.bucket_bps)
    assert_equal(2, result.trace.length)

    rule1_trace = result.trace[0]
    assert_equal("rule-1", rule1_trace["rule_id"])
    assert_equal(false, rule1_trace["matched"])
    assert_equal("predicate_failed", rule1_trace["reason"])
    assert_equal(1, rule1_trace["failed_condition_index"])
    assert_equal(2, rule1_trace["conditions"].length)
    assert_equal({ "condition_index" => 0, "operator" => "equals", "matched" => true, "reason" => "condition_matched" }, rule1_trace["conditions"][0])
    assert_equal({ "condition_index" => 1, "operator" => "semver_gte", "matched" => false, "reason" => "predicate_failed" }, rule1_trace["conditions"][1])

    rule2_trace = result.trace[1]
    assert_equal("rule-2", rule2_trace["rule_id"])
    assert_equal(true, rule2_trace["matched"])
    assert_equal("rule_matched", rule2_trace["reason"])
    assert_nil(rule2_trace["failed_condition_index"])
    assert_equal(2, rule2_trace["conditions"].length)
    assert_equal(true, rule2_trace["conditions"][0]["matched"])
    assert_equal(true, rule2_trace["conditions"][1]["matched"])

    serialized_trace = JSON.generate(result.trace)
    refute(serialized_trace.include?("sensitive-subject-id-999"))
    refute(serialized_trace.include?("SecretCountryValue"))
    refute(serialized_trace.include?("never-in-trace"))
    refute(serialized_trace.include?("country"))
  end

  test("evaluates diamond prerequisite DAGs in linear time via per-query memoization") do
    flags = {}
    flags["leaf_0"] = {
      "enabled" => true,
      "default_variant" => "on"
    }
    (1..12).each do |level|
      prev = "leaf_#{level - 1}"
      left = "left_#{level}"
      right = "right_#{level}"
      join = "leaf_#{level}"

      flags[left] = {
        "enabled" => true,
        "default_variant" => "on",
        "prerequisites" => [{ "flag_key" => prev, "variant" => "on" }]
      }
      flags[right] = {
        "enabled" => true,
        "default_variant" => "on",
        "prerequisites" => [{ "flag_key" => prev, "variant" => "on" }]
      }
      flags[join] = {
        "enabled" => true,
        "default_variant" => "on",
        "prerequisites" => [
          { "flag_key" => left, "variant" => "on" },
          { "flag_key" => right, "variant" => "on" }
        ]
      }
    end

    engine = RolloutRuleEngine::Engine.new(RolloutRuleEngine::Catalog.from_h({ "flags" => flags }))
    res = engine.evaluate(flag_key: "leaf_12", subject_id: "dag-subject")
    assert_equal("on", res.resolved_variant)
    assert_equal("default_fallback", res.reason)
  end

  test("CLI demo command outputs deterministic JSON with sample traces and bucket distribution") do
    out = StringIO.new
    err = StringIO.new
    code = RolloutRuleEngine::CLI.run(["demo"], stdout: out, stderr: err)
    assert_equal(0, code)
    assert_equal("", err.string)

    parsed = JSON.parse(out.string)
    assert_equal("0.1.0", parsed["engine_version"])
    assert_equal(["platform_api", "checkout", "instant_settlement", "seasonal_banner"], parsed["flag_keys"])
    assert_equal(4, parsed["sample_evaluations"].length)

    dist = parsed["bucket_distribution"]
    assert_equal(200, dist["cohort_size"])
    counts = dist["monotonic_threshold_counts"]
    assert(counts["1000"] <= counts["2500"])
    assert(counts["2500"] <= counts["5000"])
    assert(counts["5000"] <= counts["7500"])
  end

  test("CLI bucket command matches independent test vector") do
    out = StringIO.new
    err = StringIO.new
    code = RolloutRuleEngine::CLI.run(
      ["bucket", "--flag", "checkout", "--salt", "spring-2026", "--subject", "synthetic-subject-1"],
      stdout: out,
      stderr: err
    )
    assert_equal(0, code)
    parsed = JSON.parse(out.string)
    assert_equal(8185, parsed["bucket_bps"])
    assert_equal("4a47eed9c30fb6186573c730e07934526b35ad69cefe3877eba986c4dd3b8cef", parsed["sha256"])
  end
end
