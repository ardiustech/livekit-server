# CI/CD: GitHub Actions (CI) + Buildkite (CD only)

CI (build/vet/test) **and** the image build+push both run on **GitHub
Actions** — `.github/workflows/buildtest.yaml`. Buildkite (org `gusto`,
pipeline slug **`tax-credits-livekit-server`**) now does only the final
on-box deploy trigger (SSM), triggered by a GitHub Deployment that GitHub
Actions creates once the image is already built and pushed to ECR.

## Why split across two systems (read this first)

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
in this repo's code or pipeline config. `ardiustech/tax-credits-mcp`'s own
Buildkite Go build never hits this because its dependency graph is tiny by
comparison (a single small Lambda function, not the full pion/WebRTC + gRPC +
OpenTelemetry stack this repo pulls in).

**The fix: don't run `go mod download` on Buildkite's network at all.**
GitHub Actions runners aren't on that network. This mirrors
`ardiustech/tax-credits-mcp`'s own working pipeline — the only other Go
project in this org with in-repo evidence of an architecture that actually
works end-to-end: GitHub Actions does CI, and on success creates a **GitHub
Deployment**, which Buildkite is configured to trigger builds from (same
`BUILDKITE_GITHUB_DEPLOYMENT_*` env vars, same trigger mechanism).

**Follow-up (2026-08-03):** the first version of this split still ran
`docker buildx build` inside Buildkite's deploy step — and the Dockerfile's
build stage runs `go mod download` too, so that step was carrying the exact
same untested risk into the production deploy path (a post-merge adversarial
review flagged this as a must-fix). The image build+push moved into GitHub
Actions' `build-and-deploy` job as well; Buildkite's `deploy.sh` now only
triggers and polls the on-box SSM deploy, and never touches
`proxy.golang.org` at all.

**Why not `go mod vendor` or a cached module proxy instead?** Both would
also eliminate the network fetch, and are materially simpler (single system,
no cross-system Deployment handoff). Rejected here because they trade a
proven, already-working fix (GitHub Actions runners, which reliably don't
hit whatever limit Buildkite's network has) for an unproven one that would
need its own validation against the same failure mode before trusting it on
a production deploy path — `vendor/` also adds a large checked-in directory
(this repo's dependency graph includes pion/WebRTC + gRPC + OpenTelemetry)
that has to be kept in sync on every `go.mod` change, and a self-hosted
module proxy is new infra to build and operate. If Buildkite's network issue
ever gets fixed at the infra level (see below), either could be revisited
as a way to collapse back to one system — but there's no evidence today that
either actually avoids the limit, only that GitHub Actions does.

If this ever needs revisiting: the Buildkite network issue is a
`#build-stability` question for Gusto's infra team, not something owned by
this repo.

## What runs where

| System | Step | Does |
|---|---|---|
| GitHub Actions (`buildtest.yaml`, job `test`) | build/vet/test | `gofmt -l`, `go build ./...`, `go vet`/`go test -race` on every package except `./test/...` and `./pkg/service/...` (see below) |
| GitHub Actions (`buildtest.yaml`, job `build-and-deploy`) | build + push + trigger | On push to `master`, after `test` passes: builds + pushes the amd64 image to ECR, then creates a GitHub Deployment (`environment: production`) |
| Buildkite (`pipeline.yml`) | deploy (graceful drain) | Triggered by that deployment: on-box graceful-drain deploy via SSM only — no build, no `go mod download` |

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
natively (unlike the retired Buildkite container, which needed
Docker-outside-of-Docker to get this at all) — this exclusion may no longer be
necessary here, just kept for now to avoid re-litigating a fight already
fought on Buildkite. Worth testing removal once this workflow has a few green
runs. None of the fork's changes live here either.

## CD / auto-deploy

On a successful `test` run for a push to `master`, `buildtest.yaml`'s
`build-and-deploy` job builds the amd64 image (tagged by commit SHA +
`latest` — amd64 only, since the LiveKit box is a c6i x86_64 instance, not
arm64 like the watercooler app box), pushes it to ECR, and creates a GitHub
Deployment **with an explicit `success` deployment status**. Buildkite
(configured to trigger off GitHub Deployments — see setup below) then runs
the deploy step: it does **not** build or pull anything itself, it just
triggers `/opt/livekit/deploy.sh <sha>` on the instance via SSM and polls
for completion.

**Bug found live, 2026-08-03:** the first version of this job called
`createDeployment` but never followed up with `createDeploymentStatus`.
Buildkite's "Trigger builds on deployments" setting is literally named
`build_deployment_status_created` in its own API — it fires on the
`deployment_status` GitHub webhook event, not plain `deployment`. Without
the status call, PR #7 merged, the image built and pushed to ECR
successfully, a Deployment record existed... and Buildkite never triggered
at all (confirmed via `bk build list` / the Buildkite API — zero new
builds). No production impact resulted (the on-box SSM deploy never fired),
but this was a real gap, not a hypothetical one. `ardiustech/tax-credits-mcp`'s
own `release.yml` (the reference this architecture was modeled on) has the
exact same gap — and its Buildkite pipeline doesn't even appear in this
org's pipeline list, meaning that "precedent" was never actually confirmed
to trigger live either. Lesson: verify a referenced pipeline's actual build
history before trusting it as proof a pattern works.

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
3. Set the same key pair in **both** places — the build+push job (GitHub
   Actions) and the deploy-trigger job (Buildkite) both need it:
   - **GitHub repo secrets** (`gh secret set` or Settings → Secrets and
     variables → Actions on `ardiustech/livekit-server`):
     `LK_AWS_ACCESS_KEY_ID`, `LK_AWS_SECRET_ACCESS_KEY`. Used by
     `build-and-deploy`'s ECR login/push step.
   - **AWS Secrets Manager**, same mechanism watercooler's own pipeline uses
     (see its `.buildkite/README.md` for the exact account/region/secret-name
     convention): secret `buildkite/tax-credits-livekit-server/environment`,
     plaintext `KEY=value` lines: `LK_AWS_ACCESS_KEY_ID`,
     `LK_AWS_SECRET_ACCESS_KEY` (optional: `LK_AWS_REGION` default
     `us-west-2`, `ECR_REPO`, `INSTANCE_NAME_TAG`, `DEPLOY_ACCOUNT_ID`). Used
     by `deploy.sh`'s SSM trigger — it no longer needs ECR push, only SSM
     `SendCommand`, but reuses the same IAM user/key pair since its policy
     already grants both.
4. **Enable "Trigger builds on deployments"** in this Buildkite pipeline's
   GitHub settings (Buildkite → pipeline → Settings → GitHub) — without this,
   the GitHub Deployment `buildtest.yaml` creates has nothing listening for
   it, and the deploy step never runs.

Until steps 3-4 are done the deploy step never triggers (or soft-skips if it
does, per the `LK_AWS_*` check in `deploy.sh`), so pushes to `master` stay
green with no deploy.

**Separately, and just as important:** even once this deploys, the fork is
still a no-op in production until:
- `infrastructure/livekit/terraform.tfvars`'s `livekit_image` is switched from
  the stock `livekit/livekit-server:vX.Y.Z` image to this repo's ECR
  repository — a deliberate go-live decision, not a side effect of this
  pipeline existing (matches the project's existing philosophy — see that
  repo's `ARDIUSTECH_FORK.md`);
- `rtc.reconnect_on_publication_error: true` is set — this pipeline's
  companion change bakes it into the LiveKit config template by default, but
  it only takes effect once the box actually boots that config (a fresh
  instance, or an intentional `user_data` roll).

### Rollback

Images are tagged by commit SHA. To roll back, run the previous SHA on the box:
```bash
aws ssm send-command --document-name AWS-RunShellScript \
  --targets "Key=tag:Name,Values=watercooler-livekit-prod" \
  --parameters 'commands=["/opt/livekit/deploy.sh <previous-sha>"]' \
  --profile ardius-admin-ardius-dev --region us-west-2
```

## One-time setup (requires Buildkite admin / `write_pipelines`)

1. **Buildkite → Add pipeline.**
   - Name / slug: `tax-credits-livekit-server`
   - Repository: `git@github.com:ardiustech/livekit-server.git`
   - Cluster/queue: `default` (NOT `default_stable` — see the "Why split"
     section above; `default` is what `tax-credits-mcp` uses. The deploy
     step no longer runs `docker buildx build` at all — see "Follow-up
     (2026-08-03)" above — so this choice is now moot for Go dependency
     fetches specifically, but kept for consistency with `tax-credits-mcp`).
2. **Initial step** (the only step configured in the UI):
   ```
   buildkite-agent pipeline upload
   ```
   Everything else is read from `.buildkite/pipeline.yml` in the repo.
3. **Enable "Trigger builds on deployments"** (see Activate step 4 above).
4. GitHub Actions is already enabled for this repo (confirmed 2026-08-03 —
   the repo-level Actions permission was already `enabled: true`; the actual
   blocker on a fork is that inherited workflow files aren't *registered*
   until a `push`/`pull_request` event fires against them at least once,
   which happened automatically when this fork's first CI-split PR opened).

## Branch/deployment protection (done, 2026-08-03)

- `master` now requires the `test` GitHub Actions job as a passing status
  check, plus 1 approving review, before a PR can merge (flagged in PR #1's
  third adversarial-review round — this closes it).
- The `production` GitHub Environment now restricts deployments to protected
  branches only (i.e. `master`) — this closes the forgeable-trigger gap at
  the GitHub-API layer itself, complementing (not replacing) `deploy.sh`'s
  own `git merge-base --is-ancestor` check.
- Buildkite's "Trigger builds on deployments" is enabled on this pipeline.

This PR is itself the first real end-to-end exercise of `build-and-deploy`
(buildx → ECR push → GitHub Deployment → Buildkite SSM trigger) since #6
merged — a deliberate smoke test before pointing `infrastructure/livekit`'s
`terraform.tfvars` `livekit_image` at this fork's ECR repo for real.

## Inspecting builds (bk CLI)

```bash
bk build list -p tax-credits-livekit-server
bk build view  -p tax-credits-livekit-server <number>
bk job log <job-id> -p tax-credits-livekit-server -b <number>
```
