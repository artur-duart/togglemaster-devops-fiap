#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${EKS_CLUSTER:-togglemaster}"
SECRETS_FILE="${TOGGLEMASTER_SECRETS:-$HOME/.togglemaster-secrets.env}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGMAP="$REPO_ROOT/gitops/base/evaluation-service/configmap.yaml"

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || die "python nao encontrado no PATH."
for bin in aws kubectl; do
  command -v "$bin" >/dev/null || die "$bin nao encontrado no PATH."
done

urlencode() { "$PY" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
jqpy()     { "$PY" -c 'import sys,json;d=json.load(sys.stdin);exec("v=d"+sys.argv[1]);print(v)' "$1"; }
apply_secret() { kubectl create secret generic "$1" -n "$2" "${@:3}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; info "secret $1 (ns $2)"; }

step "1/7 Carregando segredos locais"
[ -f "$SECRETS_FILE" ] || die "$SECRETS_FILE nao existe. Copie scripts/secrets.env.example para la e preencha."
set -a; . "$SECRETS_FILE"; set +a
for v in NEW_RELIC_LICENSE_KEY PAGERDUTY_SERVICE_KEY DISCORD_WEBHOOK_GERAL DISCORD_WEBHOOK_EMERGENCIA AUTH_MASTER_KEY SERVICE_API_KEY GRAFANA_ADMIN_PASSWORD; do
  [ -n "${!v:-}" ] || die "$v esta vazio em $SECRETS_FILE"
done
info "7 valores carregados de $SECRETS_FILE"

step "2/7 Apontando o kubectl para o cluster atual"
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
  || die "cluster $CLUSTER nao existe em $REGION. Rode 'terraform -chdir=infra apply' antes."
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl get nodes >/dev/null || die "kubectl nao conseguiu falar com o cluster."
info "$(kubectl get nodes --no-headers | wc -l) node(s) prontos"

step "3/7 Garantindo namespaces"
for ns in togglemaster observability; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "namespace $ns"
done

step "4/7 Sincronizando o endpoint do Redis no GitOps"
REDIS_HOST="$(aws elasticache describe-replication-groups \
  --replication-group-id togglemaster-redis --region "$REGION" \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)"
[ -n "$REDIS_HOST" ] && [ "$REDIS_HOST" != "None" ] || die "nao consegui ler o endpoint do Redis."
NEW_URL="redis://${REDIS_HOST}:6379"
OLD_URL="$(grep -oP '(?<=REDIS_URL: ")[^"]+' "$CONFIGMAP" || true)"
if [ "$OLD_URL" = "$NEW_URL" ]; then
  info "endpoint ja correto: $NEW_URL"
  REDIS_CHANGED=0
else
  "$PY" - "$CONFIGMAP" "$NEW_URL" <<'PYEOF'
import io, re, sys
path, new = sys.argv[1], sys.argv[2]
txt = io.open(path, encoding="utf-8").read()
txt = re.sub(r'(REDIS_URL: ")[^"]+(")', lambda m: m.group(1) + new + m.group(2), txt)
io.open(path, "w", encoding="utf-8", newline="\n").write(txt)
PYEOF
  info "endpoint atualizado: $OLD_URL -> $NEW_URL"
  REDIS_CHANGED=1
fi

step "5/7 Criando os Secrets da aplicacao a partir do RDS"
for svc in auth flag targeting; do
  DB_JSON="$(aws rds describe-db-instances --db-instance-identifier "togglemaster-$svc" --region "$REGION")"
  HOST="$(printf '%s' "$DB_JSON" | jqpy '["DBInstances"][0]["Endpoint"]["Address"]')"
  PORT="$(printf '%s' "$DB_JSON" | jqpy '["DBInstances"][0]["Endpoint"]["Port"]')"
  DBNM="$(printf '%s' "$DB_JSON" | jqpy '["DBInstances"][0]["DBName"]')"
  USER="$(printf '%s' "$DB_JSON" | jqpy '["DBInstances"][0]["MasterUsername"]')"
  ARN="$(printf '%s' "$DB_JSON" | jqpy '["DBInstances"][0]["MasterUserSecret"]["SecretArn"]')"
  PASS="$(aws secretsmanager get-secret-value --secret-id "$ARN" --region "$REGION" \
            --query SecretString --output text | jqpy '["password"]')"
  DSN="postgres://${USER}:$(urlencode "$PASS")@${HOST}:${PORT}/${DBNM}"
  if [ "$svc" = "auth" ]; then
    apply_secret auth-secret togglemaster --from-literal=DATABASE_URL="$DSN" --from-literal=MASTER_KEY="$AUTH_MASTER_KEY"
  else
    apply_secret "${svc}-secret" togglemaster --from-literal=DATABASE_URL="$DSN"
  fi
done
apply_secret evaluation-secret togglemaster --from-literal=SERVICE_API_KEY="$SERVICE_API_KEY"

step "6/7 Criando os Secrets de observabilidade"
apply_secret newrelic-license observability --from-literal=license-key="$NEW_RELIC_LICENSE_KEY"
apply_secret alertmanager-integrations observability \
  --from-literal=pagerduty-service-key="$PAGERDUTY_SERVICE_KEY" \
  --from-literal=discord-webhook-geral="$DISCORD_WEBHOOK_GERAL" \
  --from-literal=discord-webhook-emergencia="$DISCORD_WEBHOOK_EMERGENCIA"
apply_secret grafana-admin observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"

step "7/7 Aplicando as Applications do ArgoCD"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  kubectl apply -f "$REPO_ROOT/gitops/apps/" >/dev/null
  info "$(ls -1 "$REPO_ROOT/gitops/apps/" | wc -l) Applications aplicadas"
else
  info "CRD do ArgoCD ausente; o Terraform ainda esta instalando o ArgoCD."
  info "Rode novamente este script daqui a alguns minutos, ou so o passo:"
  info "  kubectl apply -f gitops/apps/"
fi

printf '\n\033[1;32mBootstrap concluido.\033[0m\n\n'
if [ "${REDIS_CHANGED:-0}" = "1" ]; then
  cat <<EOF
FALTA UM PASSO SEU: o endpoint do Redis mudou e precisa ir para o Git, senao o
ArgoCD vai reverter o valor antigo (selfHeal esta ligado).

  git add gitops/base/evaluation-service/configmap.yaml
  git commit -m "chore(gitops): point evaluation-service at the current Redis endpoint"
  git push

EOF
fi
cat <<'EOF'
Verificacao:
  kubectl get applications -n argocd
  kubectl get pods -n togglemaster
  kubectl get pods -n observability

Grafana: a senha e a do GRAFANA_ADMIN_PASSWORD, usuario admin, e nao muda mais a cada sync.
EOF
