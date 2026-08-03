#!/bin/bash
# CD: trigger the on-box graceful-drain deploy via SSM and wait for it.
#
# Does NOT build or push the image (review finding, 2026-08-03) — that now
# happens in .github/workflows/buildtest.yaml's build-and-deploy job, which
# creates the GitHub Deployment that triggers this step. Moved off Buildkite
# entirely because `docker buildx build` ran `go mod download` inside the
# Dockerfile's build stage, the exact command blamed for 18/18 CI failures
# on Buildkite's network (see .buildkite/README.md) — leaving it here would
# have moved that same untested risk from blocking a CI gate to blocking an
# actual production deploy. This step's only remaining job (SSM trigger +
# poll) never touched proxy.golang.org in the first place.
#
# Credentials come from LK_AWS_* Buildkite secrets (the watercooler-livekit-ci
# IAM user — see ardiustech/watercooler's infrastructure/livekit/ci_user.tf).
# NOT the same user/creds as watercooler's own WC_AWS_* (different repo,
# different scope: this user can only SendCommand to the livekit instance;
# it no longer needs ECR push access at all now that GitHub Actions owns the
# build+push step).
set -euo pipefail

# Soft-skip until CD is activated (LK_AWS_* secrets set), so a merge before
# activation is green rather than red. See .buildkite/README.md.
if [ -z "${LK_AWS_ACCESS_KEY_ID:-}" ] || [ -z "${LK_AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "CD not activated: LK_AWS_ACCESS_KEY_ID / LK_AWS_SECRET_ACCESS_KEY not set."
  echo "Skipping deploy. See .buildkite/README.md to activate."
  exit 0
fi

REGION="${LK_AWS_REGION:-${LK_AWS_DEFAULT_REGION:-us-west-2}}"
INSTANCE_TAG="${INSTANCE_NAME_TAG:-watercooler-livekit-prod}"
# The CUSTOM SSM document (ardiustech/watercooler's infrastructure/livekit/
# ssm_document.tf), not the AWS-managed AWS-RunShellScript (review finding,
# 2026-08-02 — see that file's doc comment: this document can only ever run
# deploy.sh with a validated Tag, closing off the arbitrary-shell-command
# surface the generic document would otherwise grant this CI credential).
DEPLOY_DOCUMENT="${DEPLOY_DOCUMENT_NAME:-watercooler-livekit-deploy-prod}"
TAG="${BUILDKITE_COMMIT:-latest}"
# How long to let LiveKit finish draining active calls on the box before the
# SSM command itself gives up waiting. The on-box deploy.sh has its own,
# separate DRAIN_TIMEOUT bound (default 900s/15min) on the docker-level stop —
# this poll ceiling MUST exceed that with real margin (review finding,
# 2026-08-02: the previous ~16.5min ceiling left only ~1.5min of slack over a
# 15min on-box timeout, so a legitimately-still-draining deploy could report
# "timed out" here moments before the box itself would have reported
# success — and with automatic retry still enabled at the time, that spurious
# timeout would have fired a SECOND live SSM command at the same box while the
# first was still finishing). 300 * 5s = 25min gives a real 10min buffer;
# matches this step's own timeout_in_minutes in pipeline.yml.
POLL_ATTEMPTS="${DEPLOY_POLL_ATTEMPTS:-300}"

# Authorization guard (review finding, 2026-08-03 — must-fix): the pipeline's
# own `if: build.env("BUILDKITE_GITHUB_DEPLOYMENT_ENVIRONMENT") ==
# "production"` check gates on a label anyone with `deployments: write` could
# set via the Deployments API directly, for an ARBITRARY ref — confirmed live
# that no GitHub Environment protection or branch protection exists on this
# repo to close that gap at the GitHub-API layer. This is the actual
# class-eliminating check: refuse to touch AWS credentials at all unless
# $BUILDKITE_COMMIT is a real ancestor of origin/master, regardless of what
# label the triggering deployment claimed.
if [ -n "${BUILDKITE_COMMIT:-}" ]; then
  git fetch --quiet origin master
  if ! git merge-base --is-ancestor "$BUILDKITE_COMMIT" origin/master; then
    echo "+++ :x: refusing to deploy $BUILDKITE_COMMIT — not an ancestor of origin/master" >&2
    exit 1
  fi
fi

# Isolated AWS profile dir (never the agent's ~/.aws), cleaned up on exit.
AWS_DIR="$(mktemp -d)"
trap 'rm -rf "$AWS_DIR"' EXIT
cat >"$AWS_DIR/credentials" <<CREDS
[lk]
aws_access_key_id=$LK_AWS_ACCESS_KEY_ID
aws_secret_access_key=$LK_AWS_SECRET_ACCESS_KEY
CREDS
cat >"$AWS_DIR/config" <<CONF
[profile lk]
region=$REGION
CONF

# Run aws-cli in a container with the "lk" profile mounted, so the agent needn't
# have the CLI and its own AWS env stays untouched. Pinned (not :latest, review
# finding 2026-08-02) for the same reason golang:1.26/docker#v5.13.0 are
# pinned elsewhere in this pipeline — an unannounced upstream image change
# shouldn't be able to alter behavior on a production deploy path.
AWS_CLI_IMAGE="amazon/aws-cli:2.27.50"
awscli() {
  docker run --rm \
    -v "$AWS_DIR":/root/.aws:ro \
    -e AWS_PROFILE=lk -e AWS_DEFAULT_REGION="$REGION" \
    "$AWS_CLI_IMAGE" "$@"
}

# Refuse to send a SECOND deploy command while one is already in flight
# against this instance (review finding, 2026-08-02 — this is the guard that
# makes removing pipeline.yml's automatic retry actually sufficient: a human
# manually re-running a build after a spurious failure is the same risk as an
# automatic retry would have been). SSM's own command history is the source
# of truth, not any state this script keeps locally.
#
# Filters by DocumentName only, not by target instance (`aws ssm list-commands
# --filters` has no instance/tag key to filter on). Equivalent to scoping by
# instance today since DEPLOY_DOCUMENT/INSTANCE_TAG both default to the single
# prod box (review finding, 2026-08-02) — if this document is ever reused
# against a second target (e.g. staging), this check would need to resolve
# INSTANCE_TAG to an instance ID and cross-check
# list-command-invocations --instance-id instead, or it will block a
# legitimate deploy to instance B just because instance A has one in flight.
echo "--- :mag: checking for an in-flight deploy"
IN_FLIGHT="$(awscli ssm list-commands \
  --filters "key=DocumentName,value=$DEPLOY_DOCUMENT" \
  --query "Commands[?Status=='InProgress' || Status=='Pending'].CommandId" \
  --output text 2>/dev/null || echo "")"
if [ -n "$IN_FLIGHT" ]; then
  echo "+++ :x: a livekit-server deploy is already in flight (CommandId: $IN_FLIGHT) — refusing to send a second one" >&2
  echo "wait for it to finish, or inspect: aws ssm list-command-invocations --command-id $IN_FLIGHT" >&2
  exit 1
fi

echo "--- :rocket: trigger graceful-drain deploy via SSM"
CMD_ID="$(awscli ssm send-command \
  --document-name "$DEPLOY_DOCUMENT" \
  --targets "Key=tag:Name,Values=$INSTANCE_TAG" \
  --comment "livekit-server CD $TAG" \
  --parameters "Tag=$TAG" \
  --query 'Command.CommandId' --output text)"
echo "command id: $CMD_ID"

# Fail fast if the command matched zero instances (a stale/wrong
# INSTANCE_NAME_TAG) rather than silently polling all the way to the generic
# timeout, which reads identically to a real in-progress deploy (review
# finding, 2026-08-02). Retries a few times (review finding, 2026-08-02: a
# single fixed 10s delay could false-negative under load if SSM registration
# lags past it) before concluding zero instances actually matched.
MATCHED=0
for _ in 1 2 3; do
  sleep 5
  MATCHED="$(awscli ssm list-command-invocations --command-id "$CMD_ID" \
    --query 'length(CommandInvocations)' --output text 2>/dev/null || echo 0)"
  [ "$MATCHED" != "0" ] && break
done
if [ "$MATCHED" = "0" ]; then
  echo "+++ :x: SSM command matched zero instances for tag:Name=$INSTANCE_TAG — check INSTANCE_NAME_TAG" >&2
  exit 1
fi

for _ in $(seq 1 "$POLL_ATTEMPTS"); do
  sleep 5
  STATUS="$(awscli ssm list-command-invocations --command-id "$CMD_ID" \
    --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo Pending)"
  echo "  deploy status: $STATUS"
  case "$STATUS" in
    Success) echo "+++ :white_check_mark: deploy succeeded"; exit 0 ;;
    Failed | Cancelled | TimedOut)
      echo "+++ :x: deploy $STATUS — on-box output:" >&2
      awscli ssm list-command-invocations --command-id "$CMD_ID" --details \
        --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text >&2 || true
      exit 1
      ;;
  esac
done
echo "timed out waiting for the on-box deploy (it may still complete — the box's own DRAIN_TIMEOUT can legitimately run longer than this poll; check SSM directly: aws ssm list-command-invocations --command-id $CMD_ID). Do NOT just re-run this build — confirm via that command whether the prior deploy actually finished before trying again." >&2
exit 1
