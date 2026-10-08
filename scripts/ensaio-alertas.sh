#!/usr/bin/env bash
set -euo pipefail

# No Git Bash/MSYS, caminhos que parecem absolutos sao traduzidos para o formato
# do Windows. Isso e desejavel para o python.exe, mas quebra os argumentos do
# docker, cujos caminhos sao de DENTRO do container. Por isso a desativacao vale
# apenas para o docker, atraves do wrapper abaixo, e nao para o script inteiro.
dk() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"; }

SECRETS_FILE="${TOGGLEMASTER_SECRETS:-$HOME/.togglemaster-secrets.env}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/gitops/apps/kube-prometheus-stack.yaml"
CHART_VERSION="91.4.1"
AM_IMAGE="quay.io/prometheus/alertmanager:v0.34.0"
NET="togglemaster-ensaio"
WORK="$(mktemp -d)"
# O docker precisa do caminho do HOST no formato nativo (C:/... no Windows).
if command -v cygpath >/dev/null 2>&1; then WORK_HOST="$(cygpath -m "$WORK")"; else WORK_HOST="$WORK"; fi

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  printf '\n'
  dk rm -f ensaio-alertmanager ensaio-responder >/dev/null 2>&1 || true
  dk network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || die "python nao encontrado."
for bin in docker helm curl; do command -v "$bin" >/dev/null || die "$bin nao encontrado."; done
[ -f "$SECRETS_FILE" ] || die "$SECRETS_FILE nao existe. Veja scripts/secrets.env.example."
set -a; . "$SECRETS_FILE"; set +a
for v in PAGERDUTY_SERVICE_KEY DISCORD_WEBHOOK_GERAL DISCORD_WEBHOOK_EMERGENCIA; do
  [ -n "${!v:-}" ] || die "$v esta vazio em $SECRETS_FILE"
done

step "1/5 Renderizando a configuracao real do Alertmanager"
mkdir -p "$WORK/config" "$WORK/secrets"
"$PY" - "$APP" "$WORK/values.yaml" <<'PYEOF'
import sys, yaml
app = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
yaml.safe_dump(app["spec"]["source"]["helm"]["valuesObject"],
               open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False, allow_unicode=True)
PYEOF
helm template kps --repo https://prometheus-community.github.io/helm-charts \
  kube-prometheus-stack --version "$CHART_VERSION" -f "$WORK/values.yaml" > "$WORK/rendered.yaml" 2>"$WORK/helm.err" \
  || { cat "$WORK/helm.err"; die "helm template falhou."; }
"$PY" - "$WORK/rendered.yaml" "$WORK/config/alertmanager.yml" <<'PYEOF'
import sys, base64, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Secret" and "alertmanager.yaml" in (d.get("data") or {}):
        open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(
            base64.b64decode(d["data"]["alertmanager.yaml"]).decode("utf-8"))
        break
else:
    raise SystemExit("Secret do Alertmanager nao encontrado no render")
PYEOF
info "$(wc -l < "$WORK/config/alertmanager.yml") linhas, a mesma config que o cluster receberia"

step "2/5 Escrevendo os segredos nos caminhos que o Alertmanager espera"
printf '%s' "$PAGERDUTY_SERVICE_KEY"      > "$WORK/secrets/pagerduty-service-key"
printf '%s' "$DISCORD_WEBHOOK_GERAL"      > "$WORK/secrets/discord-webhook-geral"
printf '%s' "$DISCORD_WEBHOOK_EMERGENCIA" > "$WORK/secrets/discord-webhook-emergencia"
info "3 arquivos sem quebra de linha final (como o --from-literal faz)"

step "3/5 Subindo o Alertmanager e o stub do self-healing"
dk network create "$NET" >/dev/null 2>&1 || true
cat > "$WORK/sink.py" <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        p = json.loads(raw.decode())
        for a in p.get("alerts", []):
            l = a.get("labels", {})
            print("[RESPONDER] recebeu alerta=%s status=%s severidade=%s alvo=%s"
                  % (l.get("alertname"), a.get("status"), l.get("severity"),
                     l.get("exported_job") or l.get("pod")), flush=True)
    def log_message(self, *a): pass
HTTPServer(("0.0.0.0", 8080), H).serve_forever()
PYEOF
dk run -d --name ensaio-responder --network "$NET" \
  --network-alias self-healing-responder.observability.svc \
  -v "$WORK_HOST/sink.py:/app/sink.py:ro" python:3.11-slim \
  python /app/sink.py >/dev/null
dk run -d --name ensaio-alertmanager --network "$NET" -p 9093:9093 \
  -v "$WORK_HOST/config:/etc/alertmanager/config:ro" \
  -v "$WORK_HOST/secrets:/etc/alertmanager/secrets/alertmanager-integrations:ro" \
  "$AM_IMAGE" --config.file=/etc/alertmanager/config/alertmanager.yml \
  --storage.path=/alertmanager --log.level=info --cluster.listen-address= >/dev/null
for i in $(seq 1 30); do
  curl -sf localhost:9093/-/ready >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { dk logs ensaio-alertmanager; die "Alertmanager nao ficou pronto."; }
  sleep 1
done
info "Alertmanager pronto em http://localhost:9093"

NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
fire() {
  local alertname="$1" severity="$2" nivel="$3" incident="$4" summary="$5" acao="$6" runbook="$7" status="$8"
  local ends=""
  [ "$status" = "resolved" ] && ends=",\"endsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\""
  curl -s -o /dev/null -w "" -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d "[{
    \"labels\":{\"alertname\":\"$alertname\",\"severity\":\"$severity\",\"nivel\":\"$nivel\",
      \"incident\":\"$incident\",\"team\":\"togglemaster\",\"namespace\":\"togglemaster\",
      \"pod\":\"flag-service-7d9c6b8f4-ensaio\"},
    \"annotations\":{\"summary\":\"$summary\",
      \"impacto\":\"Ensaio local. Nenhum usuario real afetado.\",
      \"acao\":\"$acao\",
      \"runbook_url\":\"$runbook\",
      \"dashboard_url\":\"https://grafana.togglemaster.local/d/togglemaster-overview\"},
    \"startsAt\":\"$NOW\"$ends}]"
}

RB="https://github.com/artur-duart/togglemaster-devops-fiap/blob/main/runbooks/togglemaster-service-down.md"

step "4/5 Encenando o incidente"
info "T+0s   Nivel 2: pod sem replica pronta"
fire ToggleMasterServiceDown critical 2 togglemaster-indisponibilidade \
  "[ENSAIO] Pod sem replica pronta: flag-service-7d9c6b8f4-ensaio" \
  "O responder de self-healing reinicia o deployment." "$RB" firing
info "       aguardando o group_wait de 10s do self-healing..."
sleep 14
dk logs ensaio-responder 2>&1 | grep -a RESPONDER || info "       (stub ainda nao recebeu)"
info "       aguardando o group_wait de 30s do Discord..."
sleep 22
info "       >>> confira o canal GERAL do Discord agora"

info "T+40s  Nivel 1: a mitigacao automatica nao resolveu"
fire ToggleMasterServiceDownSustained emergency 1 togglemaster-indisponibilidade \
  "[ENSAIO] Servico indisponivel ha 7 minutos: flag-service-7d9c6b8f4-ensaio" \
  "Siga o runbook a partir da Camada 3." "$RB" firing
sleep 35
info "       >>> confira o PagerDuty e o canal de EMERGENCIA do Discord"

step "5/5 Resolvendo o incidente"
fire ToggleMasterServiceDown critical 2 togglemaster-indisponibilidade \
  "[ENSAIO] Pod sem replica pronta: flag-service-7d9c6b8f4-ensaio" "-" "$RB" resolved
fire ToggleMasterServiceDownSustained emergency 1 togglemaster-indisponibilidade \
  "[ENSAIO] Servico indisponivel ha 7 minutos: flag-service-7d9c6b8f4-ensaio" "-" "$RB" resolved
sleep 20
info ">>> o incidente no PagerDuty deve ter fechado sozinho"
info ">>> os dois canais do Discord devem ter recebido [RESOLVIDO]"
info ""
info "O incidente aberto no PagerDuty e REAL: a Events API v1 ignora redirecionamento"
info "de URL, entao nao ha como intercepta-lo localmente. Se sobrar algum incidente"
info "aberto, resolva pela interface do PagerDuty."

step "Veredito de entrega"
FALHAS="$(dk logs ensaio-alertmanager 2>&1 | grep -a "level=ERROR" || true)"
if [ -z "$FALHAS" ]; then
  info "nenhuma falha registrada. O Alertmanager so loga ERROR quando o destino"
  info "recusa a entrega, entao silencio aqui significa que os tres aceitaram."
else
  info "HOUVE FALHA DE ENTREGA:"
  echo "$FALHAS"
fi

echo
echo "Ensaio concluido. Os containers serao removidos agora."
