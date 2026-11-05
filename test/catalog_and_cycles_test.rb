# frozen_string_literal: true

require_relative "test_helper"

TestHarness.define_suite("Catalog Validation and Prerequisite Cycle Detection") do
  test("rejects direct self-loop prerequisite cycle with exact path") do
    raw = {
      "schema_version" => "1.0",
      "flags" => {
        "flag_a" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [
            { "flag_key" => "flag_a", "variant" => "on" }
          ]
        }
      }
    }

    err = assert_raises(RolloutRuleEngine::CycleDetectedError) do
      RolloutRuleEngine::Catalog.from_h(raw)
    end
    assert_equal(["flag_a", "flag_a"], err.cycle_path)
    assert_includes(err.message, "flag_a -> flag_a")
  end

  test("rejects multi-hop prerequisite cycle A -> B -> C -> A with exact path") do
    raw = {
      "schema_version" => "1.0",
      "flags" => {
        "flag_a" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "flag_b", "variant" => "on" }]
        },
        "flag_b" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "flag_c", "variant" => "on" }]
        },
        "flag_c" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "flag_a", "variant" => "on" }]
        }
      }
    }

    err = assert_raises(RolloutRuleEngine::CycleDetectedError) do
      RolloutRuleEngine::Catalog.from_h(raw)
    end
    assert_equal(["flag_a", "flag_b", "flag_c", "flag_a"], err.cycle_path)
    assert_includes(err.message, "flag_a -> flag_b -> flag_c -> flag_a")
  end

  test("extracts only the cycle portion when entered from an acyclic root node") do
    raw = {
      "schema_version" => "1.0",
      "flags" => {
        "entry_flag" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "node_x", "variant" => "on" }]
        },
        "node_x" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "node_y", "variant" => "on" }]
        },
        "node_y" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "node_x", "variant" => "on" }]
        }
      }
    }

    err = assert_raises(RolloutRuleEngine::CycleDetectedError) do
      RolloutRuleEngine::Catalog.from_h(raw)
    end
    assert_equal(["node_x", "node_y", "node_x"], err.cycle_path)
    assert_includes(err.message, "node_x -> node_y -> node_x")
  end

  test("rejects unknown prerequisite flag references") do
    raw = {
      "flags" => {
        "checkout" => {
          "enabled" => true,
          "default_variant" => "off",
          "prerequisites" => [{ "flag_key" => "missing_flag", "variant" => "on" }]
        }
      }
    }

    assert_raises(RolloutRuleEngine::UnknownPrerequisiteError) do
      RolloutRuleEngine::Catalog.from_h(raw)
    end
  end

  test("rejects rollout weights not summing to 10000 basis points") do
    raw = {
      "flags" => {
        "checkout" => {
          "enabled" => true,
          "default_variant" => "off",
          "rollout" => {
            "salt" => "s1",
            "weights" => [
              { "variant" => "on", "weight_bps" => 3000 },
              { "variant" => "off", "weight_bps" => 6000 }
            ]
          }
        }
      }
    }

    err = assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_h(raw)
    end
    assert_includes(err.message, "10000")
  end

  test("rejects heterogeneous 'in' arrays, non-numeric operands, and invalid SemVer in catalog") do
    heterogeneous_in = {
      "flags" => {
        "f1" => {
          "enabled" => true,
          "default_variant" => "off",
          "rules" => [
            {
              "id" => "r1",
              "variant" => "on",
              "conditions" => [
                { "attribute" => "code", "operator" => "in", "value" => ["10", 10] }
              ]
            }
          ]
        }
      }
    }
    assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_h(heterogeneous_in)
    end

    boolean_numeric = {
      "flags" => {
        "f1" => {
          "enabled" => true,
          "default_variant" => "off",
          "rules" => [
            {
              "id" => "r1",
              "variant" => "on",
              "conditions" => [
                { "attribute" => "count", "operator" => "numeric_gt", "value" => true }
              ]
            }
          ]
        }
      }
    }
    assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_h(boolean_numeric)
    end

    bad_semver = {
      "flags" => {
        "f1" => {
          "enabled" => true,
          "default_variant" => "off",
          "rules" => [
            {
              "id" => "r1",
              "variant" => "on",
              "conditions" => [
                { "attribute" => "ver", "operator" => "semver_gte", "value" => "1.2" }
              ]
            }
          ]
        }
      }
    }
    assert_raises(RolloutRuleEngine::ValidationError) do
      RolloutRuleEngine::Catalog.from_h(bad_semver)
    end
  end

  test("enforces JSON size and nesting depth limits") do
    oversized = " " * (RolloutRuleEngine::Catalog::MAX_CATALOG_BYTES + 10)
    assert_raises(RolloutRuleEngine::ParseError) do
      RolloutRuleEngine::Catalog.from_json(oversized)
    end

    deeply_nested = ("{" * 25) + ("}" * 25)
    assert_raises(RolloutRuleEngine::ParseError) do
      RolloutRuleEngine::Catalog.from_json(deeply_nested)
    end
  end
end
