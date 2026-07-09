# NanoAPI Pricing Memo

This is a working pricing model for a hosted NanoAPI platform. It is intentionally ignored with the rest of `architecture/`.

## Positioning

NanoAPI should be priced as a fast backend/API hosting platform, not as raw cloud compute.

The customer is paying for:

- Native Zig runtime performance.
- Git-to-deploy workflow.
- Custom domains and managed TLS.
- Typed routes, generated OpenAPI, validation, middleware, uploads, streaming, SSE/WebSockets, and later QUIC.
- Managed builds, rollbacks, logs, metrics, and runtime operations.
- Avoiding Kubernetes, GCP, AWS, TLS, and deployment plumbing.

## Recommendation

Launch with simple workspace plans plus usage overages.

Do not charge only by seat. Do not charge only by request. Use included usage to make pricing predictable, then meter the expensive dimensions:

- HTTP requests.
- Runtime compute.
- Bandwidth/egress.
- Build minutes.
- Artifact/upload storage.
- Log retention.
- Realtime connection minutes if WebSockets/SSE become material.

## Public Plans

### Free

Price: `$0/month`

Use it for adoption, docs, tutorials, and small demos.

Included:

- 1 user.
- 1 project.
- `*.nanoapi.dev` subdomain only.
- 100k HTTP requests/month.
- 1 GB bandwidth/month.
- 100 build minutes/month.
- 1 GB artifact/upload storage.
- 24 hour logs.
- Community support.

Limits:

- No custom domains.
- No always-warm instances.
- No production SLA.
- Scale-to-zero only.
- Fair-use CPU limits.

### Starter

Price: `$19/month`

Use it for serious side projects, indie APIs, and early production apps.

Included:

- 1 workspace.
- 3 projects.
- 2 production services.
- 2 custom domains.
- 2 million HTTP requests/month.
- 25 GB bandwidth/month.
- 300 build minutes/month.
- 5 GB artifact/upload storage.
- 7 day logs.
- Email support.

Overages:

- `$1.00 / 1M` additional HTTP requests.
- `$0.15 / GB` additional bandwidth.
- `$0.05 / GB-month` additional storage.
- `$0.01 / build minute`.

### Pro

Price: `$49/month`

Use it for developers and small teams running real applications.

Included:

- 1 workspace.
- 10 projects.
- 10 production services.
- 10 custom domains.
- 10 million HTTP requests/month.
- 100 GB bandwidth/month.
- 1,000 build minutes/month.
- 25 GB artifact/upload storage.
- 14 day logs.
- Preview environments.
- Basic usage alerts and spend caps.
- Email support.

Overages:

- `$0.80 / 1M` additional HTTP requests.
- `$0.12 / GB` additional bandwidth.
- `$0.04 / GB-month` additional storage.
- `$0.008 / build minute`.

### Team

Price: `$199/month`

Use it for production teams.

Included:

- 1 workspace.
- Unlimited viewer seats.
- 25 developer seats.
- 50 projects.
- 50 production services.
- 50 custom domains.
- 50 million HTTP requests/month.
- 500 GB bandwidth/month.
- 5,000 build minutes/month.
- 100 GB artifact/upload storage.
- 30 day logs.
- Audit log.
- Role-based access control.
- Priority support.

Overages:

- `$0.60 / 1M` additional HTTP requests.
- `$0.10 / GB` additional bandwidth.
- `$0.03 / GB-month` additional storage.
- `$0.006 / build minute`.

### Business

Price: `$499/month`

Use it for companies that need reliability, security, and procurement-friendly packaging.

Included:

- 100 developer seats.
- 250 projects.
- 250 production services.
- 250 custom domains.
- 250 million HTTP requests/month.
- 2 TB bandwidth/month.
- 20,000 build minutes/month.
- 500 GB artifact/upload storage.
- 90 day logs.
- SSO/SAML.
- SCIM.
- Advanced audit logs.
- Static outbound IP option.
- Private networking option.
- Priority support with response target.

Overages:

- `$0.45 / 1M` additional HTTP requests.
- `$0.08 / GB` additional bandwidth.
- `$0.025 / GB-month` additional storage.
- `$0.004 / build minute`.

### Enterprise

Price: custom, start at `$2,000/month`.

Use it for dedicated infrastructure, compliance, BYOC, and high-scale customers.

Included or negotiated:

- Dedicated runtime pool.
- BYOC or private GCP project.
- Custom regions and data residency.
- Custom SLAs.
- HIPAA BAA or other compliance terms.
- Dedicated support channel.
- Custom usage commits.
- Security review.
- Contract invoicing.

## Add-ons

- Additional production service: `$10/month`.
- Additional custom domain pack of 10: `$10/month`.
- Always-warm runtime: pass through minimum-instance cost plus 30%.
- Dedicated runtime pool: starts at `$250/month`.
- Static outbound IP: `$25/month` plus provider cost.
- Extended log retention: `$20/month` per extra 30 days for small accounts, custom at scale.
- Extra preview environments: `$10/month` per pack.

## Metering Rules

Requests:

- Count ingress HTTP requests that reach NanoAPI.
- WebSocket upgrade counts as one request.
- WebSocket/SSE duration should be metered separately once realtime usage is material.

Compute:

- Keep compute as an internal cost metric at launch.
- Add public compute credits only if request-count pricing becomes unfair for CPU-heavy apps.
- Enforce CPU and memory fair-use limits per plan.

Bandwidth:

- Count outbound bytes to the client.
- Do not count inbound uploads as paid bandwidth at first, but count stored bytes and object operations internally.

Build minutes:

- Meter wall-clock build time.
- Round up to the nearest minute.
- Put hard caps on Free and Starter.

Storage:

- Count deployment artifacts, uploaded files, retained logs beyond included retention, and build cache if persistent.

## Cost Notes

GCP Cloud Run request-based pricing includes a free tier and then charges for CPU, memory, and requests. Cloud Run supports high concurrency, so many lightweight requests can share one warm instance. That helps NanoAPI because the native runtime should have low per-request overhead.

The global external Application Load Balancer has a baseline forwarding-rule cost and data-processing charges. Google-managed SSL certificates are free. This means custom domains are cheap at the margin but not free operationally because certificate provisioning, DNS support, and domain troubleshooting create support load.

The pricing model should leave at least 70% gross margin on normal HTTP traffic and much higher margin on low-traffic paid accounts. Heavy streaming, uploads, long-lived WebSockets, and always-warm runtimes need separate limits or add-ons so they do not subsidize each other.

## Cloud Run Pricing And Limits

Use Cloud Run request-based billing for public API services at launch.

Current Tier 1 rates to model against:

- Request-based services:
  - Free tier: 180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests per month.
  - Active CPU: `$0.000024 / vCPU-second`.
  - Active memory: `$0.0000025 / GiB-second`.
  - Requests: `$0.40 / 1M requests`.
  - Idle minimum-instance CPU: `$0.0000025 / vCPU-second`.
  - Idle minimum-instance memory: `$0.0000025 / GiB-second`.
- Instance-based services:
  - Free tier: 240,000 vCPU-seconds and 450,000 GiB-seconds per month.
  - CPU: `$0.000018 / vCPU-second`.
  - Memory: `$0.000002 / GiB-second`.
- Jobs:
  - Free tier: 240,000 vCPU-seconds and 450,000 GiB-seconds per month.
  - CPU: `$0.000018 / vCPU-second`.
  - Memory: `$0.000002 / GiB-second`.

Rough examples before region, networking, logging, storage, and free-tier effects:

- 1 million short requests on a 1 vCPU / 512 MiB service with 10 ms of billable active time each is about `$0.65` if no concurrency sharing is assumed: `$0.40` request fee, `$0.24` CPU, about `$0.01` memory.
- One always-warm request-based minimum instance at 1 vCPU / 512 MiB is about `$10/month` while idle.
- One always-running instance-based service at 1 vCPU / 512 MiB is about `$50/month`.
- One 10 minute build job using 2 vCPU / 2 GiB is about `$0.024`.

Cost controls:

- Keep `min-instances=0` for Free and Starter unless the user buys always-warm.
- Start with `max-instances=3` on early services, then raise it per plan or per workload.
- Use high concurrency for normal APIs so one warm NanoAPI process handles many requests.
- Use lower concurrency for CPU-heavy or latency-sensitive routes.
- Set runtime request timeout low by default, for example 30-60 seconds for normal APIs.
- Permit longer timeouts only for streaming/LLM routes with plan limits.
- Use Cloud Run Jobs for builds and set explicit task timeouts.
- Emit NanoAPI usage events and enforce plan limits in our control plane, not only in GCP billing.
- Add GCP budgets and alerts, but do not treat them as hard spending caps.

Runtime timeout policy:

- Cloud Run services default to a 5 minute request timeout and can be configured from 1 second to 60 minutes.
- When a service request times out, Cloud Run returns 504, but the container instance is not necessarily terminated. NanoAPI handlers should track remaining time and return early.
- Cloud Run jobs default to 10 minute task timeout and can run up to 168 hours per task, or 1 hour for GPU tasks.
- Jobs should be used for builds because the timeout terminates the task path more directly than a service request timeout.

## Competitive Anchors

- Vercel Pro is a mainstream developer anchor around a paid monthly plan with included usage and overages.
- Railway uses minimum monthly usage credits for Hobby and Pro, then charges resource usage.
- Fly.io emphasizes pay-as-you-go infrastructure.
- Render and Heroku keep simple monthly instance pricing as a clear mental model.
- Cloudflare Workers is extremely aggressive on request pricing, but it is a different runtime and product shape.

## Launch Strategy

Use this during private beta:

- Free for public examples and docs.
- Starter at `$19/month`.
- Pro at `$49/month`.
- Team at `$199/month`.
- Enterprise conversations only when someone asks for SSO, compliance, dedicated infra, or BYOC.

Offer founder discounts manually instead of publishing cheap permanent plans.

Good founder deal:

- 50% off Starter/Pro for 12 months.
- Or `$99/month` Team for 12 months for the first 20 production teams.

Avoid lifetime deals. They distort support obligations and infrastructure cost.

## Sources Checked

- Vercel pricing: https://vercel.com/pricing
- Railway pricing: https://railway.com/pricing
- Fly.io pricing: https://fly.io/pricing/
- Render pricing: https://render.com/pricing
- Heroku pricing: https://www.heroku.com/pricing/
- Cloudflare Workers pricing: https://developers.cloudflare.com/workers/platform/pricing/
- DigitalOcean App Platform pricing: https://www.digitalocean.com/pricing/app-platform
- Cloud Run pricing: https://cloud.google.com/run/pricing
- Cloud Run request timeout: https://cloud.google.com/run/docs/configuring/request-timeout
- Cloud Run max instances: https://cloud.google.com/run/docs/configuring/max-instances-limits
- Cloud Run concurrency: https://cloud.google.com/run/docs/configuring/concurrency
- Cloud Run jobs task timeout: https://cloud.google.com/run/docs/configuring/task-timeout
- Cloud Run container runtime contract: https://cloud.google.com/run/docs/container-contract
- Google Cloud budgets: https://cloud.google.com/billing/docs/how-to/budgets
- Cloud Load Balancing pricing: https://cloud.google.com/load-balancing/pricing
