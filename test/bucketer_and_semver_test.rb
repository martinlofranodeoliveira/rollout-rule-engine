# frozen_string_literal: true

require_relative "test_helper"

TestHarness.define_suite("Bucketer Independent Vectors and Monotonicity") do
  INDEPENDENT_VECTORS = [
    {
      fields: ["checkout", "spring-2026", "synthetic-subject-1"],
      preimage_hex: "00000008636865636b6f75740000000b737072696e672d323032360000001373796e7468657469632d7375626a6563742d31",
      sha256: "4a47eed9c30fb6186573c730e07934526b35ad69cefe3877eba986c4dd3b8cef",
      bucket_bps: 8185
    },
    {
      fields: ["a:b", "c", "d"],
      preimage_hex: "00000003613a6200000001630000000164",
      sha256: "a66118c0cea04ce77c75f40a06a94d6a03f503ea23d5126393159c7cedcd1527",
      bucket_bps: 1184
    },
    {
      fields: ["a", "b:c", "d"],
      preimage_hex: "000000016100000003623a630000000164",
      sha256: "a99689be6cb6abfdbbd908bd94aa2171de8832fb70da65efada445d1ea5ab3dd",
      bucket_bps: 5166
    },
    {
      fields: ["checkout", "v1", "usuário-α"],
      preimage_hex: "00000008636865636b6f75740000000276310000000b757375c3a172696f2dceb1",
      sha256: "04c5d3c907c58b8d3d7878d5b7f435feaa6fc565dd3f4cc3b20a36de6d6fab36",
      bucket_bps: 3673
    }
  ].freeze

  test("matches independent length-prefixed UTF-8 SHA-256 test vectors") do
    INDEPENDENT_VECTORS.each do |vector|
      flag, salt, subject = vector.fetch(:fields)
      fields = { flag_key: flag, salt: salt, subject_id: subject }
      assert_equal(vector.fetch(:preimage_hex), RolloutRuleEngine::Bucketer.preimage_hex(**fields))
      assert_equal(vector.fetch(:sha256), RolloutRuleEngine::Bucketer.sha256_hex(**fields))
      assert_equal(vector.fetch(:bucket_bps), RolloutRuleEngine::Bucketer.bucket_bps(**fields))
      assert_equal(vector.fetch(:bucket_bps), RolloutRuleEngine::Bucketer.bucket_bps(**fields))
    end
  end

  test("prevents delimiter collision when inputs contain colons") do
    left = RolloutRuleEngine::Bucketer.bucket_bps(flag_key: "a:b", salt: "c", subject_id: "d")
    right = RolloutRuleEngine::Bucketer.bucket_bps(flag_key: "a", salt: "b:c", subject_id: "d")
    assert_equal(1184, left)
    assert_equal(5166, right)
    refute(left == right)
    refute(RolloutRuleEngine::Bucketer.preimage(flag_key: "a:b", salt: "c", subject_id: "d") ==
           RolloutRuleEngine::Bucketer.preimage(flag_key: "a", salt: "b:c", subject_id: "d"))
  end

  test("rejects real invalid UTF-8, empty strings, and oversized fields") do
    invalid_utf8 = [0xff, 0xfe].pack("C*").force_encoding(Encoding::UTF_8)
    invalid_binary = [0xff, 0xfe].pack("C*")
    refute(invalid_utf8.valid_encoding?)
    assert_equal([255, 254], invalid_binary.bytes)
    [invalid_utf8, invalid_binary, "", "f" * 129, 123].each do |flag|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.bucket_bps(flag_key: flag, salt: "s", subject_id: "u")
      end
    end
    [invalid_utf8, invalid_binary, "", "s" * 129].each do |salt|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.bucket_bps(flag_key: "f", salt: salt, subject_id: "u")
      end
    end
    [invalid_utf8, invalid_binary, "", "x" * 257].each do |subject|
      assert_raises(RolloutRuleEngine::InvalidInputError) do
        RolloutRuleEngine::Bucketer.bucket_bps(flag_key: "f", salt: "s", subject_id: subject)
      end
    end
    assert_equal(8185, RolloutRuleEngine::Bucketer.bucket_bps(
      flag_key: "checkout".b, salt: "spring-2026".b, subject_id: "synthetic-subject-1".b
    ))
  end

  test("preserves monotonic membership across 10%, 20%, 25%, 50%, 75%, 100%") do
    thresholds = [1000, 2000, 2500, 5000, 7500, 10_000]
    subjects = (1..400).map { |index| "monotonic-subject-#{index}" }
    engines = thresholds.to_h do |threshold|
      raw = { "flags" => { "search_v2" => {
        "enabled" => true, "default_variant" => "control",
        "rollout" => { "salt" => "q1-2026", "weights" => [
          { "variant" => "treatment", "weight_bps" => threshold },
          { "variant" => "control", "weight_bps" => 10_000 - threshold }
        ] }
      } } }
      [threshold, RolloutRuleEngine::Engine.new(RolloutRuleEngine::Catalog.from_h(raw))]
    end
    previous = []
    thresholds.each do |threshold|
      current = subjects.select do |subject|
        result = engines.fetch(threshold).evaluate(flag_key: "search_v2", subject_id: subject)
        expected = result.bucket_bps < threshold ? "treatment" : "control"
        assert_equal(expected, result.resolved_variant)
        result.resolved_variant == "treatment"
      end
      assert_equal([], previous - current)
      assert(current.length >= previous.length)
      previous = current
    end
    assert_equal(400, previous.length)
  end

  test("anchored thresholds and weighted intervals have exact half-open boundaries") do
    weights = [
      { "variant" => "zero", "weight_bps" => 0 },
      { "variant" => "target", "weight_bps" => 2500 },
      { "variant" => "control", "weight_bps" => 7500 }
    ]
    10_000.times do |bucket|
      expected = bucket < 2500 ? "target" : "control"
      assert_equal(expected, RolloutRuleEngine::Bucketer.select_weighted_variant(bucket_bps: bucket, weights: weights))
      assert_equal(bucket < 2500, RolloutRuleEngine::Bucketer.in_threshold?(bucket_bps: bucket, threshold_bps: 2500))
    end
    refute(RolloutRuleEngine::Bucketer.in_threshold?(bucket_bps: 0, threshold_bps: 0))
    assert(RolloutRuleEngine::Bucketer.in_threshold?(bucket_bps: 9999, threshold_bps: 10_000))
  end
end

TestHarness.define_suite("Strict SemVer 2.0.0 Parser and Precedence") do
  test("compares multi-digit minor and patch versions numerically") do
    assert(RolloutRuleEngine::Semver.parse("1.10.0") > RolloutRuleEngine::Semver.parse("1.2.0"))
    assert(RolloutRuleEngine::Semver.parse("2.0.0") > RolloutRuleEngine::Semver.parse("1.10.0"))
    assert(RolloutRuleEngine::Semver.parse("1.10.12") > RolloutRuleEngine::Semver.parse("1.10.3"))
  end

  test("enforces the SemVer prerelease precedence chain") do
    ordered = %w[1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0]
    ordered.map { |version| RolloutRuleEngine::Semver.parse(version) }.each_cons(2) do |lower, higher|
      assert(lower < higher)
      assert(higher > lower)
    end
    assert(RolloutRuleEngine::Semver.parse("1.0.0-9") < RolloutRuleEngine::Semver.parse("1.0.0-A"))
    assert(RolloutRuleEngine::Semver.parse("1.0.0-A") < RolloutRuleEngine::Semver.parse("1.0.0-a"))
  end

  test("ignores build metadata for precedence") do
    assert_equal(0, RolloutRuleEngine::Semver.parse("1.0.0-alpha+001") <=> RolloutRuleEngine::Semver.parse("1.0.0-alpha+20130313144700"))
    assert_equal(0, RolloutRuleEngine::Semver.parse("1.0.0+exp.sha.5114f85") <=> RolloutRuleEngine::Semver.parse("1.0.0+21AF26D3----117B344092BD"))
    assert(RolloutRuleEngine::Semver.parse("1.0.0-alpha+1") < RolloutRuleEngine::Semver.parse("1.0.0+1"))
  end

  test("validates all grammar components and the explicit byte boundary") do
    parsed = RolloutRuleEngine::Semver.parse("1.0.0-0a.01-beta")
    assert_equal(["0a", "01-beta"], parsed.prerelease)
    %w[0.0.0 1.2.3-- 1.2.3+00.01 1.2.3--.-+--.001 999999999999999999999.0.0].each do |version|
      assert(RolloutRuleEngine::Semver.valid?(version), version)
    end
    valid_at_limit = "1.0.0+" + "a" * 122
    assert_equal(128, valid_at_limit.bytesize)
    assert(RolloutRuleEngine::Semver.valid?(valid_at_limit))
    invalid = ["1.0", "1", "1.2.3.4", "v1.2.3", "01.2.3", "1.02.3", "1.2.03", "1.0.0-01",
               "1.0.0-alpha.00", "1.0.0-", "1.0.0+", "1.0.0-alpha..1", "1.0.0+build..1",
               "1.0.0+a+b", "1.0.0-alpha_1", " 1.0.0", "1.0.0\n", "1.0.0-α", "1.0.0+é",
               "1.0.0\0", valid_at_limit + "a", [255].pack("C*")]
    invalid.each do |version|
      assert_raises(RolloutRuleEngine::InvalidInputError) { RolloutRuleEngine::Semver.parse(version) }
    end
  end
end
