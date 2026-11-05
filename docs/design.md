# Design / Arquitetura — development 0.1.0

## English

### Small offline core

The runtime uses Ruby built-ins plus standard `json` and `digest`. Catalog loading is separate from evaluation. It makes a bounded normalized snapshot, rejects unknown/duplicate members, validates every definition, checks references and the prerequisite graph, then retains frozen records. No runtime fetch, plugin loading, dynamic evaluation, telemetry, or mutable global decision cache exists.

The schema accepts map and array flag definitions and Ruby string/symbol keys for convenience, but refuses ambiguous aliases and normalization collisions. Strict errors are preferable to silently ignoring an operator typo. JSON object additions are disabled. Parser errors omit input excerpts.

### Boundaries before work

The file loader opens the requested path nonblocking, checks its descriptor for a regular file and allowed size, then reads at most limit + 1 bytes. This avoids an unbounded `stat`/`binread` race and a blocking FIFO. The library is not a file-access sandbox. Both JSON and Hash loaders enforce byte/nesting budgets; attributes have independent key/count/value bounds. Composite attribute values are opaque mismatches, not recursively interpreted data.

Identifiers, strings and numeric magnitudes are bounded before use. Rule limits imply a maximum of 1024 condition records per flag, not an unbounded append-only log. Full dependency traces are flat and deduplicated per result. `evaluate_all` can serialize shared dependencies in several results; the contract explicitly bounds that output expansion rather than calling all output work linear.

### Determinism and rollout meaning

Colon joining is ambiguous: `(a:b,c,d)` and `(a,b:c,d)` would produce the same joined text. Four-byte length prefixes make tuple encoding unambiguous, including multibyte UTF-8. The digest protocol is fixed and tested against literal independent vectors; hashing is not a substitute for authorization.

Weighted variants occupy ordered half-open intervals. Only an anchored binary threshold gives a simple monotonicity proof: for fixed buckets and `T1 <= T2`, `[0,T1)` is a subset of `[0,T2)`. Reordering intervals, changing salt, or changing prerequisite/rule behavior invalidates that premise.

### Graph validation and explanation

Three-color DFS reports the exact stack slice at a back edge. Longest-path memoization enforces depth in edges, including paths through previously visited subgraphs. The maximum is 32 edges: enough for the 24-edge, 12-level adversarial diamond fixture, while evaluation recursion remains bounded. Graph validation itself can visit at most 100 flags. Tests cover exactly 32 and 33 edges in root-first and leaf-first declaration order.

One query memoizes each local decision by flag key, so evaluating a prerequisite DAG does not unfold it into an exponential tree. Instrumented regression tests count actual catalog fetches on the 37-node diamond, including repeated top-level queries and `evaluate_all`; no wall-clock benchmark is used.

Local rule traces preserve every evaluated clause and the precise short-circuit failure. Direct prerequisite checks plus flat dependency decisions explain prerequisite outcomes without recursively duplicating a diamond. Traces omit subject data and condition operands, but retain public configuration identifiers and resolved variants. These identifiers must not contain secrets.

### Types and versions

Equality uses exact scalar categories and Ruby `eql?`; numeric predicates explicitly permit finite Integer/Float comparisons. Negative predicates cannot turn absence or a wrong type into inclusion. Strings normalize to UTF-8 bytes consistently in config and attributes, without Unicode normalization.

A bounded ASCII grammar implements SemVer 2.0.0 rather than RubyGems `Gem::Version`. Core components and numeric prerelease identifiers compare numerically; nonnumeric identifiers compare ASCII lexically; metadata is retained but ignored for precedence. The 128-byte limit is an intentional resource restriction, not a claim to accept arbitrarily large versions.

### Non-goals

No daemon, remote distribution, streaming SDK, persistence, experiment significance analysis, credential handling, or production-readiness claim. Rules describe local deterministic decisions, not a secure entitlement system. Configuration mutation concurrent with a call is outside the contract.

Primary sources:

- https://docs.ruby-lang.org/en/3.4/Digest/SHA2.html
- https://docs.ruby-lang.org/en/3.4/JSON.html
- https://semver.org/spec/v2.0.0.html

## Português

### Núcleo offline e limites

O runtime utiliza recursos nativos do Ruby, `json` e `digest`, sem gems externas. A carga cria uma cópia normalizada limitada, rejeita membros desconhecidos/duplicados, valida definições e referências, verifica o grafo e retém registros congelados. Não existe rede, carregamento de plugins, avaliação dinâmica, telemetria ou cache global de decisões.

A abertura não bloqueante seguida de verificação do descritor e leitura de no máximo limite + 1 evita leitura ilimitada por crescimento do arquivo e bloqueio em FIFO. Não é sandbox de arquivos. JSON e Hash possuem limites de bytes/profundidade; atributos possuem limites próprios. Valores compostos de atributos são incompatibilidades opacas, sem percurso recursivo.

Os limites de regras implicam até 1024 registros de condições por flag. Decisões de dependências são planas e únicas por resultado. `evaluate_all` pode repetir registros compartilhados em resultados diferentes; esse custo de saída é explicitamente limitado, sem promessa de serialização linear.

### Determinismo e grafos

Prefixos de comprimento eliminam a ambiguidade de dois-pontos, inclusive com UTF-8 multibyte. Os vetores literais independentes fixam o protocolo. Apenas o limiar binário ancorado possui a garantia de inclusão monotônica: `[0,T1)` está contido em `[0,T2)` quando `T1 <= T2` e todas as demais entradas/comportamentos permanecem iguais. Bucketing não é autorização.

DFS com três estados extrai o trecho exato do ciclo na pilha. A memoização de maior caminho mede profundidade em arestas, inclusive em subgrafos já visitados. O limite de 32 arestas comporta o diamante adversarial de 12 níveis/24 arestas e mantém recursão limitada. A validação visita no máximo 100 flags. Testes verificam 32/33 arestas em ordens de declaração opostas.

Memoização por consulta evita expansão exponencial do DAG. Testes instrumentados contam avaliações reais dos 37 nós do diamante, sem depender de tempo de execução. Trilhas locais registram cláusulas executadas e falhas exatas; verificações diretas e decisões planas explicam pré-requisitos. Não expõem dados do sujeito nem operandos, mas mostram identificadores e variantes do catálogo, que não devem conter segredos.

### Tipos, SemVer e escopo

Igualdade exige categoria escalar exata; comparações numéricas aceitam Integer/Float finitos explicitamente. Operadores negativos não convertem ausência ou tipo errado em inclusão. Configurações e atributos usam UTF-8 sem normalização Unicode.

SemVer utiliza gramática ASCII limitada e precedência 2.0.0, não `Gem::Version`. Componentes numéricos comparam numericamente; identificadores não numéricos comparam em ordem ASCII; metadados não alteram precedência. O limite de 128 bytes é deliberado.

Não há servidor, distribuição remota, SDK de streaming, persistência, análise de significância, credenciais ou alegação de prontidão para produção. Mutação concorrente de entradas não faz parte do contrato. As fontes primárias são os três links oficiais acima.
