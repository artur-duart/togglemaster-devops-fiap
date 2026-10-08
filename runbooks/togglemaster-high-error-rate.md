# Runbook: ToggleMasterHighErrorRate

**Severidade:** Nível 2 (Crítico) — notifica o canal de ChatOps, não aciona o plantonista.
**Escala para:** `ToggleMasterHighErrorRateSustained` (Nível 1) após 20 minutos.

## O que o alerta significa

Mais de 5% das respostas HTTP de um serviço do ToggleMaster foram 5xx durante 5 minutos
consecutivos. A métrica vem da instrumentação OpenTelemetry da própria aplicação
(`http_server_duration_milliseconds_count`), não da infraestrutura, então ela mede o sintoma que
o usuário sente e não um proxy dele.

## Camada 1: Diagnóstico

Identifique o serviço pelo rótulo `exported_job` da notificação e confirme o quadro:

```
kubectl get pods -n togglemaster
kubectl -n togglemaster logs deploy/<servico> --tail=100
```

No Grafana, painel "Erros HTTP por serviço (4xx e 5xx)" do dashboard ToggleMaster. No painel de
logs, filtre por `{namespace="togglemaster"} |= "ERROR"`.

No New Relic, abra o Service Map e procure a aresta vermelha. Como os traces são distribuídos,
o span que falha indica se o erro nasce no serviço alertado ou em uma dependência.

## Camada 2: Mitigação automática

O responder de self-healing já tentou reiniciar o deployment antes de você ler isto. Confirme:

```
kubectl -n observability logs deploy/self-healing-responder --tail=50
```

Procure os estágios `recebido`, `validacao_aprovada`, `acao_executada` e `verificacao`. Se a
validação reprovou, o motivo aparece no campo correspondente (deployment inexistente, réplicas
desejadas zeradas ou cooldown de 30 minutos ativo).

## Camada 3: Remediação com aprovação

Se o restart não resolveu, as causas prováveis em ordem de frequência:

**Schema de banco ausente.** Sintoma no log: `relation "<tabela>" does not exist`. Os Jobs de
migração rodam como hook PreSync do ArgoCD. Force a reexecução sincronizando a Application:

```
kubectl -n argocd patch application <servico> --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
```

**Dependência indisponível.** O evaluation-service depende de auth, flag, targeting e Redis.
Verifique se o endpoint do Redis no ConfigMap corresponde ao ElastiCache atual, porque ele muda
a cada `terraform apply`.

**Regressão de código.** Confirme pelo histórico de deploy se a taxa de erro subiu logo após um
sync. Se sim, reverta a tag da imagem no manifest do GitOps e deixe o ArgoCD aplicar.

## Camada 4: Causa raiz

Registre no postmortem o que a telemetria mostrou, sem atribuir culpa a pessoas: a pergunta é
como o sistema permitiu que o erro tivesse esse impacto, não quem errou.

## Critério de resolução

Taxa de 5xx abaixo de 5% por 5 minutos. O alerta se resolve sozinho e o Alertmanager envia a
resolução para o PagerDuty e para o Discord automaticamente.
