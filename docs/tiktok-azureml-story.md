# TikTok on Azure ML — a worked example

A fictional but realistic walkthrough of how a company at TikTok's scale would lay out Azure ML governance and entities. Names invented; the structure mirrors patterns Microsoft recommends for large enterprises.

---

## The setup

TikTok runs ML across many domains. Three are relevant for this story:

- **For You recommendations** (video ranking)
- **Trust & Safety** (content moderation, fraud)
- **Creator economy** (monetization, ad targeting)

ML Platform Engineering is a central team that owns the shared plumbing. Each domain has its own data scientists and ML engineers.

---

## Tenant & subscription layout

```
Tenant: tiktok.onmicrosoft.com
│
├── Management Group: ML-Platform
│   ├── Subscription: sub-ml-shared          ← owned by ML Platform team
│   │     └── rg-platform-shared             (registries, hub, monitoring)
│   │
│   ├── Subscription: sub-ml-foryou          ← owned by For You team
│   │     ├── rg-foryou-dev
│   │     ├── rg-foryou-staging
│   │     └── rg-foryou-prod
│   │
│   ├── Subscription: sub-ml-trust           ← owned by Trust & Safety
│   │     ├── rg-trust-dev
│   │     ├── rg-trust-staging
│   │     └── rg-trust-prod
│   │
│   └── Subscription: sub-ml-creator         ← owned by Creator Economy
│         ├── rg-creator-dev
│         ├── rg-creator-staging
│         └── rg-creator-prod
```

**Why:** subscription = billing + quota + blast-radius boundary. Each domain gets its own so a runaway training run in Trust & Safety doesn't blow For You's GPU quota.

---

## Entities, end to end

### 1. Org-level: one shared registry

ML Platform deploys **one registry** in `sub-ml-shared`:

```
registry: reg-tiktok-shared    (multi-region: eastus2, westeurope, southeastasia)
```

What's in it:

- **Environments**: `pytorch-2.6-cuda12`, `tf-2.18`, `tt-base-py312` — vetted, security-scanned bases that every domain uses.
- **Components**: shared pipeline steps — `feature-validation`, `bias-eval`, `model-card-generator`.
- **Models (curated)**: promoted production models from any domain land here once approved.
- **Microsoft's `azureml` system registry** is also visible — used for Phi, Llama, etc. when domains experiment with GenAI features (e.g. caption generation for Creator).

**Cardinality**: 1 shared registry → consumed by **every workspace in every domain**.

---

### 2. Domain-level: one feature store per domain

```
Feature stores (each in its domain's prod subscription):
  fs-foryou       in sub-ml-foryou   / region: eastus2     (offline: ADLS Gen2, online: Redis Premium)
  fs-trust        in sub-ml-trust    / region: westeurope
  fs-creator      in sub-ml-creator  / region: eastus2
```

Examples of what they hold:

- `fs-foryou`: `user_30d_engagement_vector`, `video_topic_embedding_v2`, `creator_velocity_features`
- `fs-trust`: `account_age_bucket`, `report_density_24h`, `device_fingerprint_risk_score`
- `fs-creator`: `creator_revenue_l30d`, `audience_geo_distribution`, `ad_ctr_baseline`

**Why one per domain:** features in Trust shouldn't be casually reused by Ads (compliance), and online-store sizing/cost is paid per feature store.

**Cross-domain consumption** is possible via RBAC. The For You ranking model *does* read a couple of `fs-trust` features (e.g. `account_age_bucket`) to down-rank suspicious accounts — that's a deliberate, audited grant.

**Cardinality**: 1 feature store per domain → consumed by all that domain's workspaces, plus a few cross-domain grants.

---

### 3. Project-level: workspaces per use case × stage

The For You team alone has several models. Each gets its own workspace, in each stage:

```
sub-ml-foryou
├── rg-foryou-dev
│   ├── ws-foryou-ranking-dev
│   ├── ws-foryou-candidate-gen-dev
│   └── ws-foryou-shorts-rerank-dev
├── rg-foryou-staging
│   ├── ws-foryou-ranking-staging
│   ├── ws-foryou-candidate-gen-staging
│   └── ws-foryou-shorts-rerank-staging
└── rg-foryou-prod
    ├── ws-foryou-ranking-prod
    ├── ws-foryou-candidate-gen-prod
    └── ws-foryou-shorts-rerank-prod
```

Each workspace contains:

- Datastores → pointing at the domain's ADLS Gen2 lake (engagement logs, video metadata)
- Compute → GPU clusters (`Standard_ND96asr_v4` for training, `Standard_NC24ads_A100_v4` for serving)
- Jobs / pipelines, models, endpoints — all scoped to that one use case
- An attached Azure Container Registry (per workspace) for built images

**Why per-use-case workspaces:** clean RBAC (the candidate-gen team can't accidentally retrain ranking), independent costs, independent quotas, independent endpoint SLAs.

---

### 4. GenAI surface: a Foundry hub for the Creator team

The Creator team is also building an AI assistant for creators ("help me write a caption"). That's GenAI, so they use the **Foundry** stack:

```
sub-ml-creator / rg-creator-genai
└── foundry-resource: foundry-creator-genai     (kind: AIServices)
    ├── project: caption-assistant
    ├── project: thumbnail-suggestor
    └── project: brand-safety-rewriter
```

These projects:

- Pull base models (Phi-4, GPT-5) from the **Microsoft `azureml` system registry**.
- Pull fine-tuned models from **`reg-tiktok-shared`** (the central registry).
- Connect to the same ADLS Gen2 lake via Foundry "connections."
- Don't touch the classic feature stores — they don't need tabular features.

**Cardinality:** 1 Foundry resource → 3 projects under it, all sharing networking and connections.

---

## A day in the life: shipping a new For You ranking model

Here's how an actual project flows through this landscape.

### Step 1 — Develop in `ws-foryou-ranking-dev`

A data scientist:

```python
# Pull a vetted base environment from the shared registry
environment = "azureml://registries/reg-tiktok-shared/environments/pytorch-2.6-cuda12/versions/4"

# Pull features from the domain feature store
fs = FeatureStoreClient(sub="sub-ml-foryou", rg="rg-foryou-prod", name="fs-foryou")
training_df = fs.get_offline_features(
    feature_sets=["user_engagement:5", "video_topic:3"],
    observation_data=clicks_df,
)

# Submit training job in the dev workspace
ml_client_dev.jobs.create_or_update(train_job)
```

Outputs land in `ws-foryou-ranking-dev`: a model `ranking:127`, runs, metrics in MLflow.

### Step 2 — Promote model to the shared registry

When the candidate is good:

```bash
az ml model share \
  --name ranking --version 127 \
  --workspace-name ws-foryou-ranking-dev \
  --registry-name reg-tiktok-shared \
  --share-with-name foryou-ranking --share-with-version 1.4.0
```

Now it's in `reg-tiktok-shared/models/foryou-ranking/versions/1.4.0` — multi-region replicated, immutable, governed.

### Step 3 — Deploy to staging

`ws-foryou-ranking-staging` runs an endpoint that pulls from the registry:

```yaml
model: azureml://registries/reg-tiktok-shared/models/foryou-ranking/versions/1.4.0
environment: azureml://registries/reg-tiktok-shared/environments/pytorch-2.6-cuda12-serving/versions/4
```

Shadow traffic is mirrored from prod. Online metrics + a `bias-eval` component (also from the shared registry) run nightly.

### Step 4 — Promote to prod

The exact same registry references are deployed in `ws-foryou-ranking-prod`. Nothing rebuilt, no drift — same image, same weights, same component code.

### Step 5 — Governance trail

- Lineage in MLflow + AzureML jobs links **training run → feature set versions → model version → endpoint deployment**.
- A `model-card-generator` component (shared) emits a model card to the central docs portal.
- Trust & Safety RBAC owns sign-off on any model that uses `fs-trust` features — the registry promotion is gated on their approval in the CI pipeline.

---

## RBAC summary

| Identity | Role on what |
|---|---|
| For You data scientist | `AzureML Data Scientist` on `ws-foryou-*-dev`; **read** on `fs-foryou`; **read** on `reg-tiktok-shared` |
| For You ML engineer | Above + `AzureML Compute Operator` on staging/prod workspaces |
| Trust feature owner | `AzureML Data Scientist` on `fs-trust`; grants Read to specific cross-domain workspaces |
| ML Platform engineer | `Contributor` on `reg-tiktok-shared`; `Owner` on `sub-ml-shared` only |
| Release CI service principal | `AzureML Registry User` on `reg-tiktok-shared`; deploy rights on prod workspaces only |
| Compliance auditor | `Reader` across all subscriptions |

Note: no one has standing `Owner` rights on prod workspaces — promotions go through the CI principal.

---

## Putting cardinalities on the picture

```
                                ┌────────────────────────────┐
                                │   reg-tiktok-shared        │  1
                                │   (multi-region registry)  │
                                └─────────────┬──────────────┘
                                              │ consumed (read) + published (write)
              ┌───────────────────────────────┼───────────────────────────────┐
              ▼                               ▼                               ▼
       ┌────────────┐                 ┌────────────┐                  ┌──────────────┐
       │ fs-foryou  │ N domain        │ fs-trust   │                  │ fs-creator   │
       └─────┬──────┘   feature stores└─────┬──────┘                  └──────┬───────┘
             │                              │                                │
             ▼                              ▼                                ▼
   ┌────────────────────┐         ┌────────────────────┐         ┌────────────────────────┐
   │ ws-foryou-* × 3    │         │ ws-trust-* × 3     │         │ ws-creator-* × 3       │
   │ (use case × stage) │         │                    │         │ + foundry-creator-genai│
   │   N workspaces     │         │   N workspaces     │         │   + N Foundry projects │
   └────────────────────┘         └────────────────────┘         └────────────────────────┘
```

- **1** shared registry → consumed by **dozens** of workspaces.
- **3** feature stores (one per domain) → each consumed by that domain's workspaces, plus a few cross-domain grants.
- **N** workspaces per domain — one per (use case × stage). Each fully isolated.
- **1** Foundry resource for Creator GenAI → **N** Foundry projects under it.

---

## The takeaways

1. **Subscriptions split by domain** for billing, quotas, blast radius.
2. **One shared registry** at the org level for everything reusable (envs, components, prod models). Multi-region.
3. **One feature store per domain**, single region, near the data.
4. **One workspace per (use case × stage)** — not one giant workspace per team. Cheap, isolated, easy to RBAC.
5. **Hub / Foundry resources only where GenAI is needed**, kept separate from the classic ML estate.
6. **Promotion happens via the registry**, not by retraining in each stage. Same artifact, controlled rollout.

The starter kit in [infra/main.bicep](../infra/main.bicep) is the atomic unit at the bottom of all this — one workspace, one stage, one use case. The story above is what happens when you stamp that unit out dozens of times and wrap it in the right shared infrastructure.
