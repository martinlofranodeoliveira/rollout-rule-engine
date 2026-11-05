# Development 0.1.0 contract / Contrato da versão de desenvolvimento 0.1.0

## English

### Public Ruby API and errors

Require `rollout_rule_engine`. Supported entry points:

- `Catalog.from_json(string)`, `.from_h(hash)`, `.load_file(path)`; readers `schema_version`, `flags`, `flag_keys`, `key?(key)`, `fetch(key)`.
- `Engine.new(catalog)`, `.from_json(string)`, `.load_file(path)`.
- `engine.evaluate(flag_key:, subject_id:, attributes: {})` returns `EvaluationResult`.
- `engine.evaluate_all(subject_id:, attributes: {})` returns a frozen flag-key/result Hash in catalog declaration order, using one query-local memo.
- Result readers, string/symbol `result[key]`, frozen string-keyed `to_h`, and `to_json`.
- `Bucketer.preimage`, `.preimage_hex`, `.sha256_hex`, `.bucket_bps`, each with `flag_key:, salt:, subject_id:`; `.in_threshold?(bucket_bps:, threshold_bps:)`; `.select_weighted_variant(bucket_bps:, weights:)`.
- `Semver.parse(string)`, `.try_parse(string)`, `.valid?(string)`, comparison via `<=>`/Comparable, and parsed component readers.

Other helpers and record constructors are internal. Catalog construction cannot bypass validation through `Catalog.new`.

Expected failures derive from `RolloutRuleEngine::Error`: `ValidationError`, its subclasses `ParseError`, `InvalidInputError`, `UnknownFlagError`, `UnknownPrerequisiteError`, and `CycleDetectedError`. Cycle errors expose a deeply frozen `cycle_path`. No silent fallback is returned for an invalid query or invalid catalog.

### Catalog schema

All object members are case-sensitive. Unknown and duplicate members are rejected at every schema level. JSON parsing disables object additions and non-finite numeric literals. Invalid UTF-8 is rejected. Ruby Hash input is bounded and copied before validation; string/symbol keys normalize to strings, with normalization collisions rejected. ASCII and binary-encoded strings containing valid UTF-8 bytes normalize to UTF-8; other Ruby encodings are rejected. No Unicode normalization is performed.

Root:

```json
{
  "schema_version": "1.0",
  "flags": {
    "sample": {
      "enabled": true,
      "default_variant": "off",
      "prerequisites": [],
      "rules": [
        {
          "id": "target",
          "variant": "on",
          "conditions": [
            { "attribute": "tier", "operator": "equals", "value": "synthetic-tier" }
          ]
        }
      ],
      "rollout": {
        "salt": "example",
        "weights": [
          { "variant": "on", "weight_bps": 2500 },
          { "variant": "off", "weight_bps": 7500 }
        ]
      }
    }
  }
}
```

`schema_version` defaults to `"1.0"` only when absent. `flags` is required, either a nonempty map or an array of definitions containing exactly one of `key`/`flag_key`. Map definitions may contain one such alias only if it equals the map key. Duplicate flag keys are invalid.

Each flag requires boolean `enabled` and string `default_variant`. Missing/null `prerequisites` and `rules` mean empty arrays; other types are invalid. A prerequisite has exactly `flag_key` and `variant`, both identifiers. Referenced flags must exist; duplicate prerequisite keys are invalid. A required variant is compared to the dependency's resolved variant; it need not be predeclared in a separate variant registry.

A rule has exactly `id`, `variant`, `conditions`. IDs are unique within a flag. Conditions are a nonempty ordered AND list; each has exactly `attribute`, `operator`, `value`. All configured conditions are validated, including on disabled flags.

Missing/null `rollout` means inactive. Otherwise `active` is an optional boolean defaulting to true. Active rollouts require `salt` and `weights`; weights are ordered, have unique variant identifiers, integer `weight_bps` in `0..10000`, and sum to 10000. Zero weights are allowed. With `active:false`, salt/weights are optional; any supplied fields are still validated, except the total need not be 10000. Inactive rollouts are not retained as active configurations. A weight entry has exactly `variant` and `weight_bps`. The public weighted selector accepts these string/symbol-keyed Hashes or catalog `RolloutWeight` records and validates the whole distribution before selection.

### Bucketing protocol and literal reference vectors

Each input is nonempty valid UTF-8. In `(flag_key, salt, subject_id)` order concatenate **a four-byte unsigned big-endian UTF-8 byte length followed by that field's UTF-8 bytes**:

`preimage = len32be(flag_key) || flag_key || len32be(salt) || salt || len32be(subject_id) || subject_id`

Compute SHA-256, interpret its first four digest bytes as an unsigned big-endian integer, and take modulo 10000. No delimiter concatenation, normalization, extra separators, or trailing terminator is used. Colons and NUL characters inside fields are permitted. Length bounds below apply to bytes, not characters.

Literal reference vectors computed independently with Python stdlib `hashlib`/`struct`:

| Fields `(flag, salt, subject)` | Preimage hex | SHA-256 | Bucket |
| --- | --- | --- | ---: |
| `checkout`, `spring-2026`, `synthetic-subject-1` | `00000008636865636b6f75740000000b737072696e672d323032360000001373796e7468657469632d7375626a6563742d31` | `4a47eed9c30fb6186573c730e07934526b35ad69cefe3877eba986c4dd3b8cef` | 8185 |
| `a:b`, `c`, `d` | `00000003613a6200000001630000000164` | `a66118c0cea04ce77c75f40a06a94d6a03f503ea23d5126393159c7cedcd1527` | 1184 |
| `a`, `b:c`, `d` | `000000016100000003623a630000000164` | `a99689be6cb6abfdbbd908bd94aa2171de8832fb70da65efada445d1ea5ab3dd` | 5166 |
| `checkout`, `v1`, `usuário-α` | `00000008636865636b6f75740000000276310000000b757375c3a172696f2dceb1` | `04c5d3c907c58b8d3d7878d5b7f435feaa6fc565dd3f4cc3b20a36de6d6fab36` | 3673 |

Weighted intervals are half-open cumulative ranges in declared order. For a binary distribution with target first, target occupies `[0,T)`. Raising `T` preserves existing target membership only when flag key, salt, subject ID, prerequisites and rule behavior remain unchanged. No monotonicity guarantee applies to arbitrary weight changes/reorderings. `in_threshold?` accepts bucket `0..9999` and threshold `0..10000`.

### Attribute predicates

Attribute keys are strings or symbols, normalized to unique UTF-8 string keys. Missing keys and nil/null always yield `matched:false, reason:"missing_attribute"`, including negative predicates.

| Operators | Semantics |
| --- | --- |
| `equals`, `not_equals` | Exact scalar type followed by equality/inequality. String, Integer, finite Float and Boolean are distinct categories. True/false share the Boolean category. `10` and `10.0` are not equal. |
| `in`, `not_in` | Nonempty homogeneous scalar target array. Actual must have the same scalar category; then membership/nonmembership uses strict equality. |
| `numeric_gt`, `numeric_gte`, `numeric_lt`, `numeric_lte` | Finite Integer/Float comparisons; cross-numeric comparisons allowed. Strings and booleans never coerced. |
| `semver_eq`, `semver_gte`, `semver_lt` | String SemVer precedence, with build metadata ignored. |

Wrong scalar categories, non-finite actual floats, and non-scalar actual values yield `type_mismatch` even for negative operators. Composite actual values are treated as opaque unsupported values without traversal or retention; no structural equality exists. Invalid/oversized strings and oversized integers anywhere in the attribute Hash are input errors, even if unused.

For SemVer, malformed actual strings yield `invalid_semver`; malformed configured versions are load errors. Grammar within the 128-byte limit is strict SemVer 2.0.0: exactly three unsigned decimal core components without leading zeroes, optional nonempty dot-separated ASCII `[0-9A-Za-z-]+` prerelease/build identifiers, no leading zeroes in numeric prerelease identifiers, no whitespace/prefixes. Numeric prerelease identifiers compare numerically and below nonnumeric ones; other identifiers compare ASCII lexically; a shorter equal-prefix prerelease sorts earlier; release sorts after prerelease. Core components compare numerically. Build metadata has no precedence effect. Bounds intentionally exclude longer otherwise-valid versions.

Matched conditions use `condition_matched`; comparable but false predicates use `predicate_failed`.

### Evaluation and traces

Catalog validation follows directed prerequisite edges and rejects cycles, including disabled flags. The error contains the exact encountered cycle slice, e.g. `A -> B -> C -> A`, excluding any acyclic entry prefix. Root/edge traversal follows declaration order. Longest prerequisite path is measured in **edges**, independent of declaration order.

Evaluation order:

1. Disabled: default variant, `flag_disabled`, no checks/rules/bucket.
2. Prerequisites in order, memoized per top-level query: first variant mismatch returns default with `prerequisite_failed`. Subsequent prerequisites and all local rules are skipped. A disabled dependency can satisfy a prerequisite through its default variant.
3. Rules in order, conditions in order, stopping at first false condition. First matching rule wins (`rule_match`). Subsequent rules are skipped.
4. Active weighted rollout (`percentage_rollout`).
5. Otherwise default (`default_fallback`).

Each result always contains:

- `flag_key`, `resolved_variant`, `reason` from the five codes above.
- `matched_rule_id`: rule ID only for `rule_match`, otherwise null.
- `bucket_bps`: integer only for `percentage_rollout`, otherwise null.
- `failed_prerequisite_key`: first failed dependency key or null.
- `trace`: local evaluated rules, each with `rule_id`, boolean `matched`, `reason`, zero-based `failed_condition_index` or null, and `conditions`. A matched rule uses `rule_matched`; a failed rule uses its failing condition's reason.
- Each evaluated condition has `condition_index`, `operator`, boolean `matched`, `reason`. Unevaluated conditions/rules are absent.
- `prerequisites`: direct checked dependencies in declared order, each with `flag_key`, `required_variant`, `resolved_variant`, dependency `reason`, and boolean `matched`.
- `prerequisite_trace`: flat unique dependency decisions in first-completion order. Each has the same local fields above except no nested `prerequisite_trace`. Only dependencies reachable through actually checked prerequisites appear, even when memoized by `evaluate_all`.

Decisions never contain raw subject IDs, attribute keys/values, or condition operands. Flag/rule/variant identifiers do appear and must not hold secrets. Catalogs and returned result trees are deeply frozen. There is no cross-query cache. Full dependency explanations are flat rather than exponentially duplicated nested trees.

### Resource bounds

| Resource | Limit |
| --- | ---: |
| Catalog raw JSON / serialized Hash snapshot | 262144 bytes |
| JSON/Hash container nesting | 16 |
| Flags | 1..100 |
| Prerequisites per flag / longest path | 16 / 32 edges |
| Rules per flag / conditions per rule | 64 / 1..16 |
| Set operands / rollout weights | 1..64 / 1..16 |
| Flag keys, variants, rule IDs, attribute keys, salts | 1..128 UTF-8 bytes |
| Subject ID | 1..256 UTF-8 bytes |
| String condition operand or attribute value | 0..1024 UTF-8 bytes |
| SemVer string | 1..128 bytes |
| Integer magnitude | Ruby `bit_length <= 1024` |
| Subject attributes | 128 |
| Explicit catalog path | 1..4096 bytes, no NUL |
| CLI arguments | 32 tokens, 262144 total bytes |
| CLI attribute JSON nesting | 4 |

The Hash loader also applies a conservative traversal budget: braces/brackets, separators, string byte lengths and scalar estimates must fit the catalog budget before final serialized-size verification. Consequently some near-limit Hashes can be rejected even if their JSON encoding would just fit.

One local trace has at most 64 rule records and 1024 condition records; one result adds at most 16 direct checks and 99 flat dependency records. A query evaluates at most 100 unique flags, 1600 dependency checks and 102400 conditions. `evaluate_all` still evaluates each flag at most once, but serializing separate complete results can repeat shared dependency records: at most 10000 local flag-record occurrences across its output. Actual catalog byte limits usually constrain these maxima further. Output memory is bounded, but not constant.

File loading opens one explicit local path, checks the opened descriptor is a regular file, and reads at most 262145 bytes. Symlinks to regular files are allowed. File growth cannot cause an unbounded read; no atomic filesystem snapshot or sandbox is promised. Concurrent mutation of caller-owned Ruby input during a call is unsupported.

### CLI

Commands are listed by `ruby -Ilib bin/rollout-engine --help`. No arguments selects `demo`; default format is JSON. `demo --format text` and `demo --text` are equivalent. `demo --catalog path` requires the four demo flag keys, an active checkout rollout, and checkout cohort queries resolving through percentage rollout; incompatible catalogs fail explicitly. Distribution salt comes from that catalog. Median is the sorted element at index `cohort_size / 2` (upper middle for the 200-subject cohort).

`validate` accepts exactly one path. `evaluate` requires `--catalog`, `--flag`, `--subject`, with optional JSON-object `--attributes`. `bucket` requires `--flag`, `--salt`, `--subject` and deliberately echoes those diagnostic inputs. Option values are the next token. Duplicate/unknown options and extra arguments are errors. Exit codes: 0 success, 1 failure. Expected input failures emit one JSON error object on stderr and no success output; output-device failures may simply exit 1. Parse errors omit input excerpts.

## Português

### API, esquema e erros

A versão de desenvolvimento 0.1.0 expõe os carregadores `Catalog.from_json`, `.from_h`, `.load_file`, os construtores/carregadores de `Engine`, `evaluate`, `evaluate_all`, os leitores/serializadores de resultado, `Bucketer` e `Semver` descritos acima. Catálogos e decisões são profundamente congelados. Erros previstos derivam de `RolloutRuleEngine::Error`; configuração ou consulta inválida nunca vira fallback silencioso. `CycleDetectedError.cycle_path` contém o caminho exato e congelado.

O esquema compartilhado acima é normativo: membros desconhecidos ou duplicados são rejeitados; chaves String/Symbol normalizam para strings, sem colisões. `schema_version` ausente significa `"1.0"`; null/false são inválidos. Flags podem ser mapa ou array com um único alias `key`/`flag_key`. `enabled` e `default_variant` são obrigatórios. Regras e pré-requisitos ausentes/null significam listas vazias. Pré-requisitos precisam existir e não podem repetir a mesma flag. IDs de regras são únicos por flag; condições formam AND ordenado não vazio.

Rollout ausente/null é inativo. `active` é booleano, true por padrão. Quando ativo, exige salt e variantes únicas com pesos inteiros entre 0 e 10000 somando 10000. Quando inativo, campos fornecidos continuam validados, mas a soma não é exigida. Nenhuma condição de flag desabilitada escapa da validação.

### Hash, tipos e SemVer

A pré-imagem é exatamente a concatenação, na ordem flag/salt/sujeito, de comprimento UTF-8 em quatro bytes big-endian seguido dos bytes do campo. O bucket é o inteiro big-endian dos primeiros quatro bytes de SHA-256 módulo 10000. Os vetores literais da tabela acima também são os vetores de referência em português. Dois-pontos e NUL são permitidos nos campos. Não há normalização Unicode. Strings Ruby ASCII/binárias com bytes UTF-8 válidos são normalizadas para UTF-8; outras codificações são rejeitadas.

Igualdade e pertinência exigem a mesma categoria escalar: String, Integer, Float finito ou Boolean. `"10"`, `10` e `10.0` são distintos. Comparações numéricas permitem Integer/Float finitos, sem coerção de booleanos/strings. Ausência/null sempre produz `missing_attribute`, inclusive em `not_equals`/`not_in`. Tipos incompatíveis, floats não finitos e valores compostos produzem `type_mismatch`; compostos são opacos e não são percorridos ou retidos. Strings/inteiros fora dos limites são erros de entrada, mesmo em atributos não usados.

SemVer aceita a gramática estrita 2.0.0 dentro de 128 bytes: três componentes numéricos sem zeros iniciais, identificadores ASCII não vazios de pré-lançamento/metadados, rejeição de zeros iniciais em identificadores numéricos de pré-lançamento e precedência numérica/ASCII conforme descrita acima. Metadados não alteram precedência. Versão configurada inválida falha na carga; versão real malformada produz `invalid_semver`. Predicados verdadeiros usam `condition_matched`; falsos comparáveis, `predicate_failed`.

### Ordem, trilha e limites

A ordem é: desabilitada (`flag_disabled`), pré-requisitos (`prerequisite_failed` na primeira falha), primeira regra satisfeita (`rule_match`), rollout (`percentage_rollout`), padrão (`default_fallback`). Regras, condições e pré-requisitos usam curto-circuito. Dependência desabilitada pode satisfazer uma variante por seu fallback. Ciclos são rejeitados inclusive em flags desabilitadas; a profundidade máxima é medida em arestas, sem depender da ordem das definições.

Os campos e limites das tabelas acima são compartilhados e normativos. `trace` registra regras locais avaliadas, com índices de condição começando em zero e motivo exato da primeira falha; condições não executadas não aparecem. `prerequisites` registra verificações diretas. `prerequisite_trace` reúne decisões únicas das dependências efetivamente verificadas, em ordem de conclusão, sem aninhamento recursivo. Não há IDs de sujeitos, nomes/valores de atributos ou operandos de condições na saída. Identificadores de flags/regras/variantes aparecem e não devem conter segredos.

A profundidade de pré-requisitos é limitada a 32 arestas, com 100 flags no máximo. Memoização é restrita à consulta. Cada trilha local tem até 64 regras e 1024 condições; um resultado inclui até 99 decisões de dependências. `evaluate_all` avalia cada flag uma vez, mas sua serialização pode repetir dependências compartilhadas em diferentes resultados, até 10000 ocorrências locais. A carga de Hash também aplica orçamento conservador de percurso antes da conferência do JSON serializado. A memória é limitada, não constante.

A leitura verifica o descritor aberto e lê no máximo 262145 bytes de um arquivo regular explícito. Links simbólicos para arquivos regulares são aceitos; não há sandbox nem snapshot atômico. Mutação concorrente de entradas Ruby durante uma chamada não é suportada.

### CLI e monotonicidade

Os comandos e opções são os mesmos da seção inglesa. Sem argumentos, executa `demo`; JSON é padrão, `--format text`/`--text` exibem texto. Catálogos personalizados da demonstração precisam das quatro flags e encaminhar a coorte de checkout ao rollout ativo; incompatibilidades falham explicitamente. A mediana usa o elemento de índice `n / 2` após ordenação. O comando `bucket` exibe deliberadamente suas entradas. Retorno 0 indica sucesso; 1 indica falha. Erros previstos são JSON em stderr sem trechos da entrada; falha no dispositivo de saída pode apenas retornar 1.

A monotonicidade vale para a variante binária inicial no intervalo `[0,T)`, com flag, salt, sujeito, pré-requisitos e regras inalterados. Não se aplica a reordenações arbitrárias de pesos. O motor não oferece distribuição remota, persistência, autorização ou análise estatística A/B.


CLI success is returned only after its output writer flushes, when the writer supports flush. Write/flush failures return 1; a failed diagnostic writer is contained without exposing its native exception text.

A CLI retorna sucesso após flush quando o writer oferece esse método. Falhas de escrita/flush retornam 1; falhas do writer de diagnóstico são contidas sem expor a exceção nativa.
