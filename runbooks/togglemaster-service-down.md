# Runbook: ToggleMasterServiceDown

**Severidade:** Nível 2 (Crítico) por 2 minutos, escalando para Nível 1 (Emergência) aos 7 minutos.

## O que o alerta significa

Nenhum container de um pod do namespace `togglemaster` está pronto há mais de 2 minutos. O
serviço está indisponível, não apenas degradado.

## Camada 1: Diagnóstico

```
kubectl get pods -n togglemaster -o wide
kubectl -n togglemaster describe pod <pod>
kubectl -n togglemaster logs <pod> --previous --tail=100
```

O campo `--previous` é o que importa quando o pod está em CrashLoopBackOff, porque mostra o log
da execução que falhou e não o da tentativa atual.

Causas a distinguir pelo `describe`:

| Sintoma no describe | Causa provável |
|---|---|
| `ImagePullBackOff` | tag de imagem inexistente no ECR |
| `CreateContainerConfigError` | Secret ou ConfigMap ausente |
| `Readiness probe failed` | aplicação sobe mas não responde ao health check |
| `OOMKilled` | limite de memória insuficiente |

## Camada 2: Mitigação automática

O responder já tentou o restart. Verifique o resultado em
`kubectl -n observability logs deploy/self-healing-responder --tail=50`.

O restart resolve travamento e vazamento de memória. Não resolve imagem inexistente, Secret
ausente nem erro de configuração, porque o pod novo nasce com o mesmo defeito. Se o alerta
escalou para Nível 1, assuma que a causa está nessa segunda categoria.

## Camada 3: Remediação com aprovação

**Secret ausente** é a causa mais comum após recriar o cluster. Os Secrets não estão no Git por
decisão de segurança e precisam ser reinjetados a cada ambiente novo. Confira quais existem:

```
kubectl get secrets -n togglemaster
kubectl get secrets -n observability
```

**Imagem inexistente**: confirme que a tag referenciada no manifest existe no ECR. Como o
registro agora vive no stack persistente do Terraform, as imagens sobrevivem ao teardown.

## Critério de resolução

Pelo menos uma réplica pronta, sustentada por 2 minutos.
