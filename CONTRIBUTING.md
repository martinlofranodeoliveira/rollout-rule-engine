# Contributing / Contribuindo

## English

Contributions are welcome via pull requests on GitHub at `https://github.com/martinlofranodeoliveira/rollout-rule-engine`.

### Guidelines

1. Maintain zero external gem dependencies; use only Ruby 3.4 standard libraries (`json`, `digest`).
2. Preserve deterministic behavior, strict input bounds, and privacy-preserving traces.
3. Add regression and adversarial tests for any new validation rule or operator edge case.
4. Verify tests and the offline demo before submitting:
   ```bash
   ruby -Ilib:test test/run_tests.rb
   ruby -Ilib bin/rollout-engine demo
   ```

---

## Português

Contribuições são bem-vindas via pull requests no GitHub em `https://github.com/martinlofranodeoliveira/rollout-rule-engine`.

### Diretrizes

1. Mantenha zero dependências externas; utilize apenas a biblioteca padrão do Ruby 3.4 (`json`, `digest`).
2. Preserve o comportamento determinístico, os limites estritos de entrada e a privacidade da trilha de avaliação.
3. Adicione testes de regressão e casos adversariais para qualquer alteração.
4. Execute os testes e a demonstração offline antes de abrir um pull request:
   ```bash
   ruby -Ilib:test test/run_tests.rb
   ruby -Ilib bin/rollout-engine demo
   ```
