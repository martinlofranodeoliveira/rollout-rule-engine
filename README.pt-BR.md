# rollout-rule-engine

[English](README.md) · [Contrato](docs/contract.md) · [Arquitetura](docs/design.md)

Versão de desenvolvimento **0.1.0**. Motor offline de feature flags em Ruby 3.4 da [Lofrano Tecnologia](https://lofranotecnologia.com.br), com regras ordenadas, DAG de pré-requisitos, rollouts percentuais determinísticos e trilhas de auditoria limitadas. Sem gems externas, chamadas de rede, telemetria ou dependência de modelos/APIs.

Repositório: https://github.com/martinlofranodeoliveira/rollout-rule-engine

## Instalação e execução

Requer Ruby **>= 3.4**, incluindo `json`, `digest` e RubyGems. No diretório do código, não é necessário instalar:

```bash
ruby -Ilib:test test/run_tests.rb
ruby -Ilib bin/rollout-engine demo
ruby -Ilib bin/rollout-engine demo --format text
ruby -Ilib bin/rollout-engine validate data/demo_catalog.json
```

Instalação opcional como gem local, sem baixar dependências:

```bash
gem build rollout-rule-engine.gemspec
gem install --local rollout-rule-engine-0.1.0.gem --no-document
rollout-engine demo
```

O executor autocontido verifica vetores SHA-256 literais independentes, caminhos exatos de ciclos, todos os operadores, sintaxe e precedência SemVer, imutabilidade, falhas da CLI, limites e contagem de avaliações de DAG por consulta.

A demonstração usa apenas dados sintéticos: quatro perfis avaliados em múltiplas flags, trilhas completas e distribuição de buckets/variantes para 200 sujeitos determinísticos. JSON é o formato padrão; a saída textual também contém trilhas. As contagens descrevem a fixture, não um benchmark ou garantia estatística.

Exemplo de saída da validação:

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

## Exemplo da biblioteca

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

Também existem `Engine.from_json`, `Catalog.from_h` e `evaluate_all(subject_id:, attributes:)`. Catálogos e decisões retornadas são profundamente congelados. `trace` explica as regras desta flag; `prerequisites` registra verificações diretas; `prerequisite_trace` lista decisões únicas de dependências, sem aninhamento recursivo, incluindo suas trilhas locais. Essas decisões não contêm IDs de sujeitos, nomes/valores de atributos ou operandos das condições.

## Exemplos da CLI

```bash
ruby -Ilib bin/rollout-engine evaluate --catalog data/demo_catalog.json --flag checkout --subject synthetic-subject-1 --attributes '{"plan_tier":"enterprise","region":"br-south","app_version":"1.10.0"}'
ruby -Ilib bin/rollout-engine bucket --flag a:b --salt c --subject d
```

O segundo comando emite:

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

Diferentemente das trilhas, o comando diagnóstico `bucket` exibe deliberadamente as entradas. Use identificadores sintéticos ao salvar essa saída. Os comandos retornam 0 no sucesso e 1 na falha; erros de entrada/validação são JSON em stderr, sem backtrace Ruby.

## Decisões de projeto

- Prefixos de comprimento UTF-8 evitam ambiguidades quando os campos contêm dois-pontos.
- A primeira variante binária ocupa `[0, limiar)`: aumentar esse limiar preserva os sujeitos já incluídos se flag, salt e identificador permanecerem iguais.
- Igualdade estrita distingue `"10"`, `10` e `10.0`. Comparações numéricas aceitam inteiros/floats finitos, nunca booleanos ou strings. Ausência/null resulta em falso inclusive nos operadores negativos.
- SemVer implementa a gramática estrita 2.0.0 e sua precedência dentro do limite de 128 bytes, incluindo pré-lançamentos e metadados ignorados na comparação.
- Limites explícitos, rejeição de membros JSON desconhecidos/duplicados, leitura limitada e memoização por consulta reduzem riscos de entradas hostis e erros de configuração.

## Escopo e limitações

É uma biblioteca em desenvolvimento, sem alegação de prontidão para produção. O catálogo é um subconjunto JSON documentado: 256 KiB, profundidade 16, 100 flags, 32 arestas de profundidade de pré-requisitos, 64 regras por flag e 16 condições por regra. Consulte o contrato para todos os limites e campos de saída.

Não oferece distribuição de flags, SDK de streaming, persistência, autorização, armazenamento de segredos ou cálculo de significância A/B. Bucketing determinístico não é controle de autorização. Reordenar variantes, alterar salt ou mudar regras pode mudar a coorte; a monotonicidade vale apenas para o limiar binário ancorado com as demais condições inalteradas. Arquivos são entradas locais explícitas, sem sandbox de sistema de arquivos. Identificadores e variantes do catálogo podem aparecer na auditoria e não devem conter segredos.

Contato geral: [site oficial](https://lofranotecnologia.com.br). Segurança: [relato privado no GitHub](https://github.com/martinlofranodeoliveira/rollout-rule-engine/security/advisories/new).

[MIT](LICENSE), copyright 2026 Lofrano Tecnologia.
