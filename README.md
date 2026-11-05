# rollout-rule-engine

[Português](README.pt-BR.md) · [Contract](docs/contract.md) · [Design](docs/design.md)

Development version **0.1.0**. An offline Ruby 3.4 feature-flag evaluator from [Lofrano Tecnologia](https://lofranotecnologia.com.br), with ordered attribute rules, prerequisite DAGs, deterministic percentage rollouts, and bounded, privacy-conscious audit traces. No external gems, network calls, telemetry, or model/API dependency.

Repository: https://github.com/martinlofranodeoliveira/rollout-rule-engine

## Install and run

Ruby **>= 3.4**, including its standard `json`, `digest`, and RubyGems facilities. From the source directory, no installation is necessary:

```bash
ruby -Ilib:test test/run_tests.rb
ruby -Ilib bin/rollout-engine demo
ruby -Ilib bin/rollout-engine demo --format text
ruby -Ilib bin/rollout-engine validate data/demo_catalog.json
```

Optional local gem installation, without downloading dependencies:

```bash
gem build rollout-rule-engine.gemspec
gem install --local rollout-rule-engine-0.1.0.gem --no-document
rollout-engine demo
```

The dependency-free test runner checks literal independent SHA-256 vectors, exact cycle paths, every targeting operator, SemVer grammar/precedence, immutable results, CLI failures, resource boundaries, and per-query DAG evaluation counts.

The bundled synthetic demo emits JSON by default: four multi-flag sample profiles with complete decision traces, plus bucket/variant counts for 200 deterministic synthetic subjects. Text mode includes the traces too. Counts describe that fixture, not a performance benchmark or statistical guarantee.

Example validation output:

```json
{
  "valid": true,
  "schema_version": "1.0",
  "flag_count": 4,
  "flag_keys": [
    "platform_api",
    "checkout",
    "instant_settlement",
    "seasonal_banner"
  ]
}
```

## Library example

```ruby
require "rollout_rule_engine"

engine = RolloutRuleEngine::Engine.load_file("data/demo_catalog.json")
result = engine.evaluate(
  flag_key: "checkout",
  subject_id: "synthetic-subject-1",
  attributes: {
    "plan_tier" => "enterprise",
    "region" => "br-south",
    "app_version" => "1.10.0",
    "monthly_orders" => 45
  }
)
puts result.resolved_variant # one_click
puts result.reason           # rule_match
puts result.matched_rule_id  # rule-enterprise-br
puts result.to_json
```

`Engine.from_json`, `Catalog.from_h`, and `evaluate_all(subject_id:, attributes:)` are also available. Catalogs and returned decisions are deeply frozen. `trace` explains this flag's evaluated rules; `prerequisites` records direct checks; `prerequisite_trace` contains unique, flat dependency decisions, including their local rule traces. No subject IDs, attribute names/values, or rule operand values are included in these decisions.

## CLI examples

```bash
ruby -Ilib bin/rollout-engine evaluate --catalog data/demo_catalog.json --flag checkout --subject synthetic-subject-1 --attributes '{"plan_tier":"enterprise","region":"br-south","app_version":"1.10.0"}'
ruby -Ilib bin/rollout-engine bucket --flag a:b --salt c --subject d
```

The second command emits:

```json
{
  "flag_key": "a:b",
  "salt": "c",
  "subject_id": "d",
  "preimage_hex": "00000003613a6200000001630000000164",
  "sha256": "a66118c0cea04ce77c75f40a06a94d6a03f503ea23d5126393159c7cedcd1527",
  "bucket_bps": 1184
}
```

Unlike evaluation traces, the diagnostic `bucket` command deliberately echoes its inputs. Use synthetic identifiers when saving its output. Commands return 0 on success and 1 on failure; validation/input failures are JSON on stderr without a Ruby backtrace.

## Why these choices?

- Length-prefixed UTF-8 fields prevent ambiguous colon-delimited hash inputs.
- Anchoring the first binary variant to `[0, threshold)` preserves existing membership when increasing that threshold with the same flag, salt, and subject ID.
- Strict scalar equality distinguishes `"10"`, `10`, and `10.0`. Numeric predicates accept finite integers/floats, not booleans or strings. Missing/null values are false even for negative predicates.
- The SemVer parser implements the strict 2.0.0 grammar and precedence within a 128-byte version limit, including prerelease identifiers and ignored build metadata.
- Explicit limits, rejection of unknown/duplicate JSON members, bounded file reads, and query-local memoization keep configuration mistakes and hostile inputs contained.

## Scope and limitations

This is a development library, not a production-readiness claim. Catalog JSON is a documented bounded subset: 256 KiB, depth 16, 100 flags, prerequisite depth 32 edges, 64 rules/flag, and 16 conditions/rule. See the contract for every limit and result field.

There is no flag distribution service, streaming SDK, persistence, authorization system, secret storage, or A/B significance calculator. Bucketing is deterministic, not an authorization boundary. Reordering weighted variants, changing a salt, or changing targeting rules can change membership; monotonicity applies only to an otherwise unchanged anchored binary threshold. Files are explicit local inputs, not a filesystem sandbox. All catalog identifiers and variants can appear in audit output and must not contain secrets.

General contact: [official homepage](https://lofranotecnologia.com.br). Security reports: [GitHub private vulnerability reporting](https://github.com/martinlofranodeoliveira/rollout-rule-engine/security/advisories/new).

[MIT](LICENSE), copyright 2026 Lofrano Tecnologia.
