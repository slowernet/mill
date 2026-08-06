# Branch/preview deploys for human + machine validation — options

Research notes, 2026-08-06. **Out of scope for Mill v1**; captured for later.

## What machine validation needs that human review doesn't

A human just needs a link. An agent driving a preview needs four things, and most
preview platforms are built for the human case:

1. **A stable, discoverable URL** — readable off the PR (deployment status or bot
   comment) without scraping HTML.
2. **Deterministic seeded data** — an agent asserting "the ranking changed" needs
   known inputs. A preview pointed at empty or drifting data produces unfalsifiable
   verdicts.
3. **An auth bypass** — a preview-only signed token or seeded test user, scoped to
   preview hosts. Otherwise the agent stalls at a login form.
4. **Readable logs** — the agent should be able to fetch app logs to explain a
   failure, not just screenshot a 500 page.

## Tier A — frontend only (free, near-zero config)

Vercel, Netlify, Cloudflare Pages. Automatic per-PR URL, free tier, comment bot posts
the link. Per Northflank's comparison, Vercel has "no built-in support for backend or
DB services" and Netlify is "not intended for backend previews or multi-service apps."
Fine for a static or JS-framework front end; useless for a Roda app with a database.

## Tier B — full-stack managed

### Fly.io + `superfly/fly-pr-review-apps` — best fit for Ruby/Rack
- GitHub Action (currently v1.5.0) that creates, deploys, and destroys a Fly app per
  PR. Only secret needed is `FLY_API_TOKEN`.
- Default app naming `pr-{number}-{repo_org}-{repo_name}`; the name **must** contain
  the PR number as a safety guard.
- Copies an existing `fly.toml` under the new name, so preview config tracks prod config.
- Postgres: pass the `postgres` input and it runs `flyctl postgres attach`, which
  creates a database named after the app and sets `DATABASE_URL`.
- Machines auto-stop, so idle cost is near zero — important when agents open many PRs.
- Known wart: destroys the Fly app but **not** the GitHub environment record, so stale
  environments accumulate in the GitHub UI.

### Render Preview Environments
- Spins up a full copy of services per PR from `render.yaml`, optionally including a database.
- **Requires a Professional workspace plan or higher** ($25/mo, unlimited members, no
  per-seat fee). Preview resources are billed as normal services, prorated by the second.
- Northflank's comparison notes it "does not auto-clone production data or inject
  secrets automatically," and teardown is tied to PR lifecycle with no scheduling.
- Per-second billing of always-on services is the cost model most likely to surprise
  you when an agent opens twelve PRs overnight.

### Heavier platforms
Northflank (managed or BYOC on GCP/AWS/Azure, database cloning, teardown scheduling),
Qovery, Bunnyshell (template-based multi-service), Porter and Okteto (both want your
own Kubernetes), Codefresh (ArgoCD + Helm), Shipyard (no-code QA workflows). All are
built for teams; overkill for a single-operator factory.

## Tier C — self-hosted on a VPS

- **Coolify** — native per-branch preview environments plus a GitHub App for PR
  previews. Closest thing to Vercel on your own hardware.
- **Dokploy** — also supports per-PR previews.
- **Dokku** — needs a plugin and configuration; the git-push workflow is otherwise
  excellent for single-server apps.
- **Kamal** and **CapRover** — no native preview support; require fully custom CI
  scripting. (Kamal is still the strongest plain-deploy choice for Rails/Rack.)

Cheapest at volume — one VPS, unlimited previews — at the cost of owning the ops.

## Tier D — the database half (the actually hard part)

**Neon** is the standout: copy-on-write Postgres branching, O(1) regardless of database
size (sub-second), with official GitHub Actions to create a branch per PR and delete it
on merge or close. Free tier is 512 MB storage, 0.25 vCPU, ~100 compute-hours/month, no
credit card. This is what turns a preview from a mock into a real environment, and it
composes with any of the compute options above.

## Recommended shape when this comes into scope

**Fly review apps + a Neon branch per PR, driven by a GitHub Actions workflow that
lives in the target repo — not in Mill.**

Mill's entire involvement stays one field: read the deployment URL off the PR and pass
it to the browser-verify stage as `MILL_PREVIEW_URL`. If it's absent, verify degrades to
running the app locally in the worktree. That single seam is why this is safely
deferrable — nothing in Mill's design has to change to adopt it later.

Two guardrails worth writing into `.mill.yml` when the time comes:
- **Auth bypass** — a preview-only token or seeded test user the verify stage can use.
- **A cap on concurrent previews**, plus a hard preference for scale-to-zero compute.
  Agents open PRs faster than people do; Fly's auto-stop machines and Neon's
  compute-hours model both fail safe, and always-on per-second billing does not.

## Sources

- [10 best preview environment platforms in 2026 — Northflank](https://northflank.com/blog/preview-environment-platforms)
- [Preview Environments — Render Docs](https://render.com/docs/preview-environments)
- [superfly/fly-pr-review-apps](https://github.com/superfly/fly-pr-review-apps)
- [Git Branch Preview Environments on GitHub — Fly Docs](https://fly.io/docs/blueprints/review-apps-guide/)
- [Automate branching with GitHub Actions — Neon Docs](https://neon.com/docs/guides/branching-github-actions)
- [A database for every preview environment using Neon, GitHub Actions, and Vercel](https://neon.com/blog/branching-with-preview-environments)
- [Self-Hosted Deployment Tools Compared: Coolify, Dokploy, Kamal, Dokku, Haloy](https://dev.to/ameistad/self-hosted-deployment-tools-compared-coolify-dokploy-kamal-dokku-and-haloy-2npd)
