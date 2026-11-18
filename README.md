# data-pipeline

Ingestão e camada analítica **Saipos** + **iFood** → Neon (PostgreSQL), Lambdas na AWS `sa-east-1`.

| Lambda AWS | Workflow GHA | Papel |
|------------|--------------|--------|
| `ingest-saipos` | [deploy_saipos.yml](.github/workflows/deploy_saipos.yml) | Vendas, itens, histórico de status (Saipos API) |
| `ingest_ifood` | [deploy_ifood.yml](.github/workflows/deploy_ifood.yml) | Financial, Review, Analytics (iFood) |
| `sheets-ingest` | [deploy_sheets.yml](.github/workflows/deploy_sheets.yml) | `dim_lojas` e cadastros (Google Sheets) |

Schedulers EventBridge (AWS): `ducadu-ingest-saipos-hourly`, `ducadu-ingest-ifood-hourly`.

A pasta **`scripts/`** não é versionada — backfill e ingest pontual rodam só na máquina do operador.

App consumidor: [sistema-unico-ducadu](https://github.com/ducadu-br/sistema-unico-ducadu) (repo separado).