# CI/CD history (Buildkite retired 2026-08-03 — see `.github/workflows/buildtest.yaml`)

This directory is kept for history only. CI and CD both live entirely in
**GitHub Actions** now (`.github/workflows/buildtest.yaml`): `test` runs
build/vet/test, and `build-and-deploy` builds+pushes the image to ECR and
runs the on-box SSM deploy directly. There is no Buildkite pipeline for this
repo anymore.

## Why CI moved off Buildkite in the first place

This repo originally had **no CI/CD at all** (manual SSM deploy runbook), then
briefly had a Buildkite pipeline doing both CI and CD. That Buildkite CI step
never worked reliably: **18 straight build attempts** (2026-08-02/03) failed
`go mod download`'s ~120+ fresh fetches from `proxy.golang.org` — different
agent, different queue, every environmental lever tried:

| Attempt | Result |
|---|---|
| `GOFLAGS=-buildvcs=false` | Fixed a real, separate git-ownership error, but not this |
| `git config safe.directory` | Fixed the gofmt script's own git calls, but not this |
| Removed `git fetch` (SSH host-key hang) | Fixed a real, separate hang, but not this |
| `GOSUMDB=off` | No change |
| `GOMAXPROCS=2` (suspected connection-rate limit) | No change |
| Scoped `go vet`/`go test` off `./pkg/service` (traced one specific hang to `httpsnoop`'s dependency chain) | Fixed *that specific* hang; a *different* package hung on the next run |
| Switched `default_stable` → `default` queue | No change (same failure, different queue) |
| Disabled IPv6 (well-known Docker/Go Happy-Eyeballs hang pattern) | Ruled out — IPv6 was already disabled at the kernel level |
| Gusto `cache-buildkite-plugin` internal cache | Correct long-term idea, but doesn't fix the *first* (seeding) build, which faces the same volume |

Every one of these was a real, verified fix for *something* — several were
genuine bugs in this pipeline — but none touched the actual root cause. The
final, consistent signature across all 18 attempts: **the same identical
`go mod download` finishes in 12 seconds from an unrelated network**, and on
Buildkite it always dies at a *different* point (different package, different
agent, different queue) after successfully fetching ~100+ dependencies. That
shape — large fresh-fetch volume, not a specific host/queue/package — points
to a **connection-count or rate limit in Buildkite's own network egress path**
(a NAT gateway or security-group connection-tracking cap), not anything fixable
in this repo's code or pipeline config.

**The fix at the time: don't run `go mod download` on Buildkite's network at
all.** GitHub Actions runners aren't on that network. CI moved there; the
Buildkite pipeline was kept around for CD (build+push+deploy) only, triggered
by a GitHub Deployment — modeled on what looked like
`ardiustech/tax-credits-mcp`'s own working pipeline.

**Why not `go mod vendor` or a cached module proxy instead, at the time?**
Both would also have eliminated the network fetch. Passed over in favor of
GitHub Actions runners because that was a proven fix with no further
validation needed, whereas `vendor/` adds a large checked-in directory (this
repo's dependency graph includes pion/WebRTC + gRPC + OpenTelemetry) that has
to stay in sync on every `go.mod` change, and a self-hosted module proxy is
new infra to build and operate. If Buildkite's network issue is ever fixed at
the infra level, this is a `#build-stability` question for Gusto's infra
team, not something owned by this repo.

## Why CD (build+push) also moved off Buildkite, 2026-08-03

The first version of the CI/CD split still ran `docker buildx build` inside
Buildkite's deploy step — and the Dockerfile's build stage runs
`go mod download` too, so that step carried the exact same untested risk into
the production deploy path (a post-merge adversarial review flagged this as
a must-fix). The image build+push moved into GitHub Actions'
`build-and-deploy` job.

## Why Buildkite was retired entirely, 2026-08-03

At that point Buildkite's only remaining job was triggering the on-box SSM
deploy off a GitHub Deployment. Two things killed that:

1. **The trigger was silently broken the whole time.** Buildkite's "Trigger
   builds on deployments" setting is literally named
   `build_deployment_status_created` in its own provider-settings API — it
   fires on the `deployment_status` webhook event, not plain `deployment`
   creation. `createDeployment` alone never emits a status. The workflow
   called `createDeployment` and nothing else, so a real merge (PR #7) built
   and pushed the image successfully, created a Deployment record... and
   Buildkite never triggered a build at all. No production impact resulted
   (the on-box deploy never fired), but the whole CD chain had been a silent
   no-op since it was introduced.

2. **The reason Buildkite exists for CD elsewhere in this org doesn't apply
   here.** Buildkite's agents are self-hosted EC2 instances inside Gusto's
   own AWS account, with a cluster (`higher-envs`) purpose-built for
   "connectivity to higher environments (production, staging, demo)" — a
   real, deliberate trust boundary for touching Gusto's core production
   account. This pipeline's target AWS account
   (`ardius-admin-ardius-dev`) is a separate, lower-stakes account that
   boundary doesn't protect, and this pipeline was never even assigned to
   that cluster (ran unclustered, same generic pool as everything else).
   `ardiustech/tax-credits-mcp`'s own workflow — the reference this
   architecture was modeled on — has the identical missing-status gap, and
   its Buildkite pipeline doesn't even appear in this org's pipeline list,
   meaning that "known-working precedent" was never actually confirmed to
   trigger live either.

With neither the trigger mechanism nor the trust-boundary rationale holding
up, `build-and-deploy` now runs the on-box SSM deploy directly (the same
authorization/idempotency logic that lived in Buildkite's `deploy.sh` moved
into a workflow step almost as-is — see `.github/workflows/buildtest.yaml`).
This eliminates the entire cross-system Deployment/webhook coordination
layer, and the class of bug in (1) with it.

**Leftover infra from the retired Buildkite path** (not yet cleaned up, safe
to remove whenever convenient): the `tax-credits-livekit-server` Buildkite
pipeline itself (dormant — its GitHub trigger is now disabled), and the
`buildkite/tax-credits-livekit-server/environment` AWS Secrets Manager
secret (a duplicate of the `LK_AWS_*` GitHub repo secrets, no longer read by
anything).

## What runs where

| Job | Does |
|---|---|
| `test` | `gofmt -l`, `go build ./...`, `go vet`/`go test -race` on every package except `./test/...` and `./pkg/service/...` (see below) |
| `build-and-deploy` | On push to `master`, after `test` passes: builds + pushes the amd64 image to ECR, checks for an in-flight deploy, triggers the on-box SSM deploy, and polls it to completion |

**Why `./test/...` is excluded:** `TestMultinodeDataPublishing`,
`TestDataPublishSlowSubscriber`, and `TestTurnRelay` do real end-to-end WebRTC
UDP ICE/STUN/TURN work that a sandboxed CI container's networking can't always
reliably support regardless of whether the code is correct — same category of
pre-existing flakiness already documented for `pkg/rtc/transport_test.go`'s
ICE tests in `ARDIUSTECH_FORK.md` (confirmed flaky on unmodified upstream code
too). None of this fork's own changes live in `./test/...`; they're all under
`./pkg/rtc/`. **Run `./test/...` manually against a real network before
shipping anything that actually touches ICE/TURN/multi-node behavior** — CI
going green isn't a substitute for that.

**Why `./pkg/service/...` is also excluded:** its `docker_test.go` has a
package-wide `TestMain` that calls `dockertest.NewPool`, needing a real Docker
daemon. `ubuntu-latest` GitHub Actions runners *do* have Docker available
natively — this exclusion may no longer be necessary here, just kept for now
to avoid re-litigating a fight already fought on the old Buildkite CI step.
Worth testing removal once this workflow has a few more green runs. None of
the fork's changes live here either.

## CD / auto-deploy

On a successful `test` run for a push to `master`, `build-and-deploy` builds
the amd64 image (tagged by commit SHA + `latest` — amd64 only, since the
LiveKit box is a c6i x86_64 instance, not arm64 like the watercooler app
box), pushes it to ECR, then triggers `/opt/livekit/deploy.sh <sha>` on the
instance via SSM (the custom `watercooler-livekit-deploy-prod` document, not
the generic `AWS-RunShellScript` — it can only ever run deploy.sh with a
validated Tag) and polls for completion.

**This is NOT a blue/green swap like watercooler's own app deploy.** LiveKit
runs `network_mode: host` bound to fixed ports (7880 signaling, 7881/7882
media) — two copies can't bind those simultaneously on one box, so there's no
second color to flip to. Instead, the on-box script leans on **LiveKit's own
built-in graceful shutdown**: `cmd/server/main.go`'s SIGTERM handler calls
`router.Drain()` (stop accepting new joins) then waits for every active
participant to leave before actually exiting — this is not something this
pipeline invented, it's already how the upstream binary behaves. A deploy
therefore:
- does **not** forcibly drop any call already in progress (the old process
  waits for it to end naturally, up to a generous bound — see `DRAIN_TIMEOUT`
  in the on-box `deploy.sh`);
- **does** pause new joins for the drain window, since there's nowhere else
  for them to go on a single-node SFU.

True zero-downtime (new joins routed to an already-warm second node while the
old one drains) needs a second EC2 node + Redis-backed multi-node LiveKit + a
router in front — a separate, materially bigger infra project, not something
this pipeline does. See `ardiustech/watercooler`'s
`infrastructure/livekit/README.md` for the full tradeoff writeup.

### Activate (one-time)

1. `cd infrastructure/livekit && terraform apply` (in `ardiustech/watercooler`)
   — creates the `watercooler-livekit-ci-<env>` IAM user (ECR push to the
   `livekit-server` repo + SSM `SendCommand` to the livekit instance only; no
   EC2/Terraform access) and the `livekit-server` ECR repository itself.
2. Read its key:
   ```bash
   terraform -chdir=infrastructure/livekit output -raw livekit_ci_access_key_id
   terraform -chdir=infrastructure/livekit output -raw livekit_ci_secret_access_key
   ```
3. Set as **GitHub repo secrets** (`gh secret set` or Settings → Secrets and
   variables → Actions on `ardiustech/livekit-server`):
   `LK_AWS_ACCESS_KEY_ID`, `LK_AWS_SECRET_ACCESS_KEY`. Used by
   `build-and-deploy` for both the ECR login/push and the SSM deploy trigger.

Until step 3 is done, `build-and-deploy` soft-skips (per the `LK_AWS_*` check
at the top of the job), so pushes to `master` stay green with no deploy.

**Separately, and just as important:** even once this deploys, the fork is
still a no-op in production until:
- `infrastructure/livekit/terraform.tfvars`'s `livekit_image` is switched from
  the stock `livekit/livekit-server:vX.Y.Z` image to this repo's ECR
  repository — a deliberate go-live decision, not a side effect of this
  pipeline existing (matches the project's existing philosophy — see that
  repo's `ARDIUSTECH_FORK.md`). Note: this only affects what a *fresh*
  instance boots with — any successful CD deploy already overwrites the
  running container's image regardless of what this variable says, since
  `deploy.sh` always points at the fork's ECR repo;
- `rtc.reconnect_on_publication_error: true` is set — this pipeline's
  companion change bakes it into the LiveKit config template by default, but
  it only takes effect once the box actually boots that config (a fresh
  instance, or an intentional `user_data` roll).

### Rollback

Images are tagged by commit SHA. To roll back, run the previous SHA on the box:
```bash
aws ssm send-command --document-name watercooler-livekit-deploy-prod \
  --targets "Key=tag:Name,Values=watercooler-livekit-prod" \
  --parameters 'Tag=<previous-sha>' \
  --profile ardius-admin-ardius-dev --region us-west-2
```

## Branch/deployment protection (done, 2026-08-03)

- `master` requires the `test` GitHub Actions job as a passing status check,
  plus 1 approving review, before a PR can merge (flagged in PR #1's third
  adversarial-review round — this closes it).
- `build-and-deploy` runs directly off a real `push` event to `master`
  (gated by the branch protection above), not a separately-forgeable
  trigger — `github.sha` is guaranteed by GitHub itself to be what actually
  landed on `master`.

## Inspecting runs

```bash
gh run list --repo ardiustech/livekit-server --workflow buildtest.yaml
gh run view <run-id> --repo ardiustech/livekit-server
```
