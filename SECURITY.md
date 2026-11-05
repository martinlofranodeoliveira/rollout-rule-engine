# Security / Segurança

## English

Development version 0.1.0 is the current documented development line. This policy does not promise a response-time SLA or production readiness.

Report vulnerabilities privately, not in public issues:

https://github.com/martinlofranodeoliveira/rollout-rule-engine/security/advisories/new

For general contact, use the official homepage: https://lofranotecnologia.com.br

### Boundaries

- No telemetry, network services, credentials, external commands, plugins or dynamic code evaluation at runtime.
- JSON object additions are disabled; duplicate/unknown members, invalid UTF-8, excessive size/depth/counts and oversized numeric magnitudes are rejected.
- File reads check the opened descriptor and are bounded even if a regular file grows. Nonregular files are rejected. Explicit paths and symlinks to regular files remain accessible; this is not a filesystem sandbox.
- Prerequisite cycles and excessive depth fail at load time. Query-local memoization prevents exponential repeated evaluation. Trace/output expansion has explicit bounds in the contract.
- Evaluation results omit subject identifiers, attribute names/values and condition operands. Flag/rule/variant identifiers do appear: do not put secrets or personal data in them.
- The diagnostic `bucket` command deliberately echoes subject ID, salt and hash preimage. Do not log real identifiers with that command. Demo fixtures are synthetic only.
- Parse errors omit input excerpts. Applications remain responsible for file permissions, handling result logs, protecting identifiers and deciding whether a flag decision is suitable for their use case.

Bucketing is predictable and is not authorization, access control or a cryptographic secret. This development library has no remote rule distribution, authentication or secure storage. Concurrent mutation of caller-owned Ruby input during evaluation/loading is unsupported.

## Português

A versão de desenvolvimento 0.1.0 é a linha documentada atual. Esta política não promete prazo de resposta nem prontidão para produção.

Relate vulnerabilidades de forma privada, não em issues públicas:

https://github.com/martinlofranodeoliveira/rollout-rule-engine/security/advisories/new

Contato geral pelo site oficial: https://lofranotecnologia.com.br

### Fronteiras

- Sem telemetria, serviços de rede, credenciais, comandos externos, plugins ou avaliação dinâmica no runtime.
- JSON não instancia objetos adicionais; membros duplicados/desconhecidos, UTF-8 inválido e excessos de tamanho/profundidade/quantidade/magnitude são rejeitados.
- A leitura verifica o descritor aberto e permanece limitada se um arquivo regular crescer. Arquivos não regulares são rejeitados. Caminhos explícitos e links para arquivos regulares continuam acessíveis; não é sandbox de arquivos.
- Ciclos e profundidade excessiva falham na carga. Memoização por consulta impede avaliação repetida exponencial. O contrato limita trilhas e expansão da saída.
- Resultados não expõem IDs de sujeitos, nomes/valores de atributos ou operandos. Identificadores de flags/regras/variantes aparecem: não inclua segredos ou dados pessoais neles.
- O comando diagnóstico `bucket` exibe deliberadamente sujeito, salt e pré-imagem. Não registre identificadores reais com esse comando. As fixtures da demonstração são somente sintéticas.
- Erros de parsing omitem trechos da entrada. Permissões de arquivos, tratamento dos logs, proteção de identificadores e adequação das decisões são responsabilidade da aplicação.

Bucketing é previsível e não representa autorização, controle de acesso ou segredo criptográfico. Não há distribuição remota, autenticação ou armazenamento seguro. Mutação concorrente de entradas Ruby durante as chamadas não é suportada.
