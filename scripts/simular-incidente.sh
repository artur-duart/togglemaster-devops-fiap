#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-togglemaster}"
OBS_NS="${OBS_NS:-observability}"
SVC="${1:-flag-service}"
SECRET="${SVC%-service}-secret"
BACKUP="${TMPDIR:-/tmp}/${SECRET}-backup.yaml"

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
marco(){ printf '\n\033[1;33m### %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

restaurar() {
  if [ -f "$BACKUP" ]; then
    printf '\n'
    step "Restaurando o ambiente"
    kubectl apply -f "$BACKUP" >/dev/null && info "secret $SECRET recriado"
    kubectl -n "$NS" rollout restart "deploy/$SVC" >/dev/null && info "deploy/$SVC reiniciado"
    rm -f "$BACKUP"
    info "aguardando o pod ficar pronto..."
    kubectl -n "$NS" rollout status "deploy/$SVC" --timeout=180s || info "nao ficou pronto no prazo; investigue com kubectl describe"
  fi
}
trap restaurar EXIT INT TERM

if [ "${1:-}" = "--restaurar" ]; then
  [ -f "$BACKUP" ] || die "nao ha backup em $BACKUP para restaurar."
  SVC="$("$PY" -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["metadata"]["name"].replace("-secret","-service"))' "$BACKUP")"
  restaurar; trap - EXIT; exit 0
fi

PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || die "python nao encontrado no PATH."
command -v kubectl >/dev/null || die "kubectl nao encontrado."
kubectl get nodes >/dev/null 2>&1 || die "kubectl nao fala com nenhum cluster. Rode 'aws eks update-kubeconfig --name togglemaster --region us-east-1'."
kubectl -n "$NS" get "deploy/$SVC" >/dev/null 2>&1 || die "deploy/$SVC nao existe no namespace $NS."
kubectl -n "$NS" get "secret/$SECRET" >/dev/null 2>&1 || die "secret/$SECRET nao existe. Rode scripts/bootstrap-cluster.sh antes."
kubectl -n "$OBS_NS" get deploy/self-healing-responder >/dev/null 2>&1 || die "o responder de self-healing nao esta no ar."

cat <<EOF

Este script provoca um incidente REAL em $SVC removendo o Secret $SECRET.
Os pods sao apagados para que os recriados nascam sem ele. Apenas remover o
Secret nao basta: o pod em execucao ja tem as variaveis injetadas, e o rolling
update nunca o derruba enquanto o substituto nao fica pronto.

Esse e o cenario de falha de configuracao:
o restart automatico NAO resolve, e por isso o alerta escala para o plantonista.

Linha do tempo esperada:
  T+0      Secret removido e pods em execucao apagados
  ~T+3min  ToggleMasterServiceDown (Nivel 2) -> responder + Discord geral
  ~T+8min  ToggleMasterServiceDownSustained (Nivel 1) -> PagerDuty + Discord emergencia
  ao sair  Secret recriado e servico de volta (automatico, inclusive com Ctrl+C)

EOF
read -r -p "Digite PROVOCAR para continuar: " CONFIRMA
[ "$CONFIRMA" = "PROVOCAR" ] || { trap - EXIT; echo "cancelado."; exit 0; }

step "Salvando o Secret antes de remover"
kubectl -n "$NS" get "secret/$SECRET" -o json | "$PY" -c '
import sys, json, yaml
d = json.load(sys.stdin)
yaml.safe_dump({"apiVersion": "v1", "kind": "Secret",
                "type": d.get("type", "Opaque"),
                "metadata": {"name": d["metadata"]["name"],
                             "namespace": d["metadata"]["namespace"]},
                "data": d["data"]}, sys.stdout, sort_keys=False)
' > "$BACKUP"
[ -s "$BACKUP" ] || die "o backup saiu vazio; abortando sem mexer em nada."
info "backup em $BACKUP ($(wc -l < "$BACKUP") linhas)"

step "Provocando a falha"
kubectl -n "$NS" delete "secret/$SECRET" >/dev/null && info "secret $SECRET removido"
kubectl -n "$NS" delete pods -l app="$SVC" --wait=false >/dev/null && info "pods de $SVC removidos; os recriados nascem sem o Secret"
INICIO="$(date +%s)"

kubectl -n "$OBS_NS" logs -f deploy/self-healing-responder --tail=0 2>/dev/null \
  | sed 's/^/    [RESPONDER] /' & TAIL_PID=$!
trap 'kill $TAIL_PID 2>/dev/null || true; restaurar' EXIT INT TERM

acompanhar() {
  local alvo="$1" rotulo="$2"
  while :; do
    local t=$(( $(date +%s) - INICIO ))
    [ "$t" -ge "$alvo" ] && break
    printf '\r    T+%03ds  aguardando %s  |  pods: %s   ' "$t" "$rotulo" \
      "$(kubectl -n "$NS" get pods -l app="$SVC" --no-headers 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ',' | sed 's/,$//')"
    sleep 5
  done
  printf '\r%*s\r' 80 ''
}

acompanhar 210 "ToggleMasterServiceDown (Nivel 2)"
marco "T+3min30s  O alerta de Nivel 2 ja deve ter chegado"
info "confira o canal GERAL do Discord"
info "o PagerDuty deve seguir SILENCIOSO, de proposito"

acompanhar 570 "ToggleMasterServiceDownSustained (Nivel 1)"
marco "T+9min30s  O alerta de Nivel 1 ja deve ter escalado"
info "confira o PagerDuty e o canal de EMERGENCIA do Discord"
info "repare que o responder tentou o restart e o pod continuou falhando:"
kubectl -n "$NS" get pods -l app="$SVC" 2>/dev/null || true

marco "Encerrando. O ambiente sera restaurado automaticamente."
