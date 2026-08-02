#!/bin/bash
# CD: build + push the amd64 image (tagged by commit SHA + latest), then trigger
# the on-box graceful-drain deploy via SSM and wait for it. Runs on the agent's
# Docker (needs buildx). Mirrors ardiustech/watercooler's own
# .buildkite/steps/deploy.sh structure closely — see that file's comments for
# the AWS-profile-isolation rationale, which is identical here.
#
# Credentials come from LK_AWS_* Buildkite secrets (the watercooler-livekit-ci
# IAM user — see ardiustech/watercooler's infrastructure/livekit/ci_user.tf).
# NOT the same user/creds as watercooler's own WC_AWS_* (different repo,
# different scope: this user can only push to the livekit-server ECR repo and
# SendCommand to the livekit instance, nothing else).
set -euo pipefail

# Soft-skip until CD is activated (LK_AWS_* secrets set), so a merge before
# activation is green rather than red. See .buildkite/README.md.
if [ -z "${LK_AWS_ACCESS_KEY_ID:-}" ] || [ -z "${LK_AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "CD not activated: LK_AWS_ACCESS_KEY_ID / LK_AWS_SECRET_ACCESS_KEY not set."
  echo "Skipping deploy. See .buildkite/README.md to activate."
  exit 0
fi

ACCOUNT="${DEPLOY_ACCOUNT_ID:-396735084811}"
REGION="${LK_AWS_REGION:-${LK_AWS_DEFAULT_REGION:-us-west-2}}"
REPO="${ECR_REPO:-livekit-server}"
INSTANCE_TAG="${INSTANCE_NAME_TAG:-watercooler-livekit-prod}"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/$REPO"
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

echo "--- :docker: buildx builder"
# create-or-use in one step (review finding, 2026-08-02: the previous
# inspect-then-create-then-use had a TOCTOU window between concurrent
# invocations on the same agent; --use folds the "make this the active
# builder" step into create itself, and the fallback only runs if create
# fails because the builder already exists).
docker buildx create --name lkbuilder --driver docker-container --use \
  || docker buildx use lkbuilder

echo "--- :ecr: login (lk profile)"
awscli ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

echo "--- :hammer: build + push ($TAG)"
# amd64 only — the LiveKit box is a c6i (Intel) instance, not arm64 like the
# app's t4g box (see ardiustech/watercooler's infrastructure/livekit/README.md
# "Notes / decisions": LiveKit is CPU-bound on media forwarding, x86_64 is the
# well-trodden path). No emulation/binfmt needed since the agent is already
# amd64.
docker buildx build --platform linux/amd64 \
  -t "$IMAGE:$TAG" -t "$IMAGE:latest" --push .

# Refuse to send a SECOND deploy command while one is already in flight
# against this instance (review finding, 2026-08-02 — this is the guard that
# makes removing pipeline.yml's automatic retry actually sufficient: a human
# manually re-running a build after a spurious failure is the same risk as an
# automatic retry would have been). SSM's own command history is the source
# of truth, not any state this script keeps locally.
echo "--- :mag: checking for an in-flight deploy"
IN_FLIGHT="$(awscli ssm list-commands \
  --filters "key=DocumentName,value=AWS-RunShellScript" \
  --query "Commands[?Status=='InProgress' || Status=='Pending'] | [?contains(Comment, 'livekit-server CD')].CommandId" \
  --output text 2>/dev/null || echo "")"
if [ -n "$IN_FLIGHT" ]; then
  echo "+++ :x: a livekit-server deploy is already in flight (CommandId: $IN_FLIGHT) — refusing to send a second one" >&2
  echo "wait for it to finish, or inspect: aws ssm list-command-invocations --command-id $IN_FLIGHT" >&2
  exit 1
fi

echo "--- :rocket: trigger graceful-drain deploy via SSM"
CMD_ID="$(awscli ssm send-command \
  --document-name AWS-RunShellScript \
  --targets "Key=tag:Name,Values=$INSTANCE_TAG" \
  --comment "livekit-server CD $TAG" \
  --parameters "commands=[\"/opt/livekit/deploy.sh $TAG\"]" \
  --query 'Command.CommandId' --output text)"
echo "command id: $CMD_ID"

# Fail fast if the command matched zero instances (a stale/wrong
# INSTANCE_NAME_TAG) rather than silently polling all the way to the generic
# timeout, which reads identically to a real in-progress deploy (review
# finding, 2026-08-02). SSM registers invocations against matched instances
# within a few seconds of send-command, well inside this first short wait.
sleep 10
MATCHED="$(awscli ssm list-command-invocations --command-id "$CMD_ID" \
  --query 'length(CommandInvocations)' --output text 2>/dev/null || echo 0)"
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
