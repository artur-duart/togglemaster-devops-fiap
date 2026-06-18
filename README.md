# ToggleMaster — Plataforma de Feature Flags (Microsserviços)

Tech Challenge **Fase 2** — POSTECH DevOps & Arquitetura Cloud.

Evolução do ToggleMaster: o que na Fase 1 era um **monólito**, aqui foi reescrito como um
**ecossistema de 5 microsserviços** conteinerizados, orquestrados localmente via Docker Compose
(e, nas próximas fases, implantados em Kubernetes/EKS com escalabilidade).

> O histórico do monólito da Fase 1 continua preservado neste repositório (git log).

## Arquitetura

| Serviço | Linguagem | Porta | Responsabilidade | Data store |
|---|---|---|---|---|
| **auth-service** | Go | 8001 | Gerência de chaves de API e autenticação | PostgreSQL (`auth-db`) |
| **flag-service** | Python | 8002 | CRUD das definições de feature flags | PostgreSQL (`flag_db`) |
| **targeting-service** | Python | 8003 | Regras de segmentação | PostgreSQL (`targeting_db`) |
| **evaluation-service** | Go | 8004 | "Hot path": decisão final `true/false` | Redis (cache) |
| **analytics-service** | Python | 8005 | Consome eventos e grava análises | DynamoDB (+ SQS) |

### Data stores locais (4)

- **`auth-db`** — PostgreSQL dedicado ao auth (isolado por ser a fronteira de segurança).
- **`flag-targeting-db`** — PostgreSQL único hospedando **dois** databases (`flag_db` + `targeting_db`).
- **`redis`** — cache em memória para o evaluation-service.
- **`dynamodb-local`** — emulação local do DynamoDB para o analytics-service.

> **SQS** é usado em produção (nuvem). Localmente os serviços degradam graciosamente sem ele (por design).

### Fluxo de uma avaliação

```
GET /evaluate?user_id=...&flag_name=...
        │
  evaluation-service ──► flag-service      (busca a flag)
        │           └──► targeting-service (busca as regras)
        │                     │
        │              ambos validam a chave de API no ◄── auth-service
        └──► cacheia o resultado no Redis e devolve true/false
```

## Como rodar localmente

### Pré-requisitos
- Docker Desktop (com Docker Compose v2)

### Passos
```bash
# 1. Configure as variáveis de ambiente
cp .env.example .env
# (preencha os valores em .env — credenciais locais)

# 2. Suba todo o ecossistema (5 apps + 4 data stores = 9 contêineres)
docker compose up -d --build

# 3. Verifique a saúde
docker compose ps
```

Todos os serviços expõem `GET /health`. Os bancos sobem com healthcheck, e o Compose
garante a ordem de inicialização (um serviço só sobe quando suas dependências estão saudáveis).

Para derrubar:
```bash
docker compose down        # remove contêineres e rede
docker compose down -v     # idem, e também apaga os volumes (reinicializa os bancos)
```

## Testando a integração

A coleção **`togglemaster.postman_collection.json`** cobre o fluxo completo, na ordem:

1. **Health Checks** — confirma que os 5 serviços respondem.
2. **Auth → Create API Key** — cria uma chave (captura automática para os próximos requests).
3. **Flag → Create Flag** — cria uma feature flag.
4. **Targeting → Create Rule** — cria uma regra de segmentação (ex.: rollout de 50%).
5. **Evaluation → Evaluate** — obtém a decisão final.

Importe o arquivo no Postman e rode os requests na ordem das pastas.

## Estrutura do repositório

```
.
├── docker-compose.yml                # orquestração dos 9 contêineres
├── .env.example                      # template das variáveis de ambiente
├── togglemaster.postman_collection.json
└── services/
    ├── auth-service/                 # Go
    ├── flag-service/                 # Python
    ├── targeting-service/            # Python
    ├── evaluation-service/           # Go
    └── analytics-service/            # Python
```

Cada serviço contém seu próprio `Dockerfile`, `.dockerignore` e, quando aplicável,
o schema SQL de inicialização em `db/`.
