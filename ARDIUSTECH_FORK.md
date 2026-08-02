# Ardius Tech fork of `livekit/livekit`

Forked so we can patch SFU-side issues we hit in production without waiting on
upstream review/release cadence. Kept as a **separate file, not an edit to
README.md**, deliberately — editing the upstream README would conflict on
every future `git merge upstream/master`; this file never will.

- `origin` = this fork (`ardiustech/livekit-server`)
- `upstream` = `https://github.com/livekit/livekit.git`
- Base: `upstream/master` @ `v1.13.5` (the latest tag as of 2026-07-31).
  **Currently deployed production** (watercooler's LiveKit box) is one patch
  behind, at `v1.13.4` — see the patch list below for what changes when this
  fork is actually adopted.

## Patches on top of upstream

### 1. Proactive republish nudge for stuck publisher tracks (`feat/publish-mid-stuck-nudge`)

**Problem:** `pkg/rtc/participant.go`'s `mediaTrackReceived` can receive RTP
for a just-published track before the SDP negotiation assigning it a `mid`
has resolved (logged as `WARN "could not get mid for track"`). Upstream
queues the track (`pendingRemoteTracks`) and waits for the SAME participant
to renegotiate again for some UNRELATED reason
(`handlePendingRemoteTracks`'s three call sites are all client-initiated: a
fresh offer, an AddTrack request, or an unpublish) — there's no code path
where the server proactively asks the stuck publisher to renegotiate. An app
whose usage pattern doesn't naturally trigger another renegotiation (publish
once, then nothing) can have this track sit broken indefinitely — invisible
to every OTHER peer in the room, with the publisher's own client reporting
itself as perfectly healthy.

Full incident writeup + evidence from watercooler's production LiveKit box:
`docs/sfu-multiparty-triage-2026-07-31.md` in the `ardiustech/watercooler`
repo (a 2-minute-long stuck-track incident during a live meeting, 215 failed
mid-resolution attempts on one participant, only cleared when that
participant's client happened to reconnect on its own).

**Fix:** `pkg/rtc/participant.go` — when a track lands in
`pendingRemoteTracks` because `mid == ""`, schedule a check 750ms later
(`scheduleStuckPublishNudge`). If the SAME track is still stuck, proactively
push a small marker payload down that SAME participant's own data channel
(`sendRepublishNudge`, via the existing, unmodified `DataPacket_User` wire
type — `p.TransportManager.SendDataMessage`). No new protobuf message type,
no `livekit-protocol` changes, no `client-sdk-js` changes: `RoomEvent.DataReceived`
already exists in the stock JS SDK and already surfaces this payload
unmodified to app code. **This fork touches exactly one repo.**

The app-side handler (`ardiustech/watercooler`, `feat/sfu-republish-signal-handler`,
PR #162) listens for `RoomEvent.DataReceived` with topic
`_ardiustech_republish_nudge` and republishes ONLY the one named stuck track
(`republishOneTrack`, unpublish+publish of that single track) — NOT
`republishAllTracks()`. That app's OWN client-side blind timer (which DID
call `republishAllTracks()` on a fixed schedule) has since been deleted
entirely: live A/B/C instrumentation (`ardiustech/livekit-server`
INVESTIGATION_LOG.md facts #20-22, run against a diagnostic build of THIS
fork) proved that blind timer was the DOMINANT source of the exact
"could not get mid for track" collateral damage this whole effort exists to
fix, not a mitigation for it. This reactive, server-signaled nudge is now
the ONLY republish-nudge mechanism on the client — which is why the
dedup/cap/escalation fix below matters: there's no other backstop left if
this one runs away.

**Fixed since first opened (review round, 2026-08-01 — see PR #1 comments):**
- **No de-dup/cap on the nudge timer (was a must-fix).** Every retry of a
  still-stuck track (215, in the production incident) called
  `scheduleStuckPublishNudge` again, arming an independent duplicate
  `time.AfterFunc` with no coordination — under sustained failure this could
  compound into a self-sustaining nudge/renegotiate loop with the app-side
  handler. Added `stuckPublishNudgeState` (per-trackID, guarded by the
  existing `pendingTracksLock`): a duplicate call while a timer is already
  in flight is now a no-op, actual send attempts are capped at
  `stuckPublishNudgeMaxAttempts` (3) per stuck episode, and exhausting that
  cap escalates to `p.IssueFullReconnect(...)` — self-contained recovery
  that doesn't depend on the same (possibly impaired) client renegotiating
  correctly again — instead of nudging indefinitely.
- **No Close()-time cleanup.** Unlike this file's existing
  `migrationTimer`/`disconnectTimer` pattern, a participant disconnecting
  within the 750ms grace period could leave a nudge timer firing after
  teardown. `clearAllStuckPublishNudges()` is now called from `Close()`;
  `onStuckPublishNudgeFired` also checks `IsClosed()`/`IsDisconnected()` as
  a second guard.
- **Reserved topic wasn't blocked on the inbound relay path.** Any
  participant could send a `DataPacket_User` naming the
  `_ardiustech_republish_nudge` topic to another participant, and
  `handleReceivedDataMessage` would relay it like any other user payload.
  The app-side client already rejects this (a relayed message always
  resolves to a real, non-`undefined` `RemoteParticipant`, which its
  `handleDataReceived` guard ignores), so this was never end-to-end
  exploitable — but defense shouldn't depend on only one side of a
  two-repo boundary staying correct forever. Now hard-dropped at the source.
- **Hand-built JSON payload could be invalid for a control-byte trackID.**
  `fmt.Sprintf("%q", trackID)` escapes some control bytes as `\xNN`, not
  valid JSON's `\u00NN` — and `trackID` originates from client-controlled
  SDP/`MediaStreamTrack` id. Switched to `encoding/json.Marshal` on a typed
  `republishNudgePayload` struct.

**Files changed:** `pkg/rtc/participant.go` (~200 lines net — the pure
functions `isTrackStillPending`/`buildRepublishNudgePacket`, the
scheduling/send/dedup/cap/escalate glue, and the relay-path hard-drop),
`pkg/rtc/participant_republish_nudge_test.go` (covers the pure functions
directly, `onStuckPublishNudgeFired`'s resolved-without-sending case,
dedup/re-arm/clear/clear-all behavior via direct state manipulation — no
real timer waits — and a JSON-validity regression test for the control-byte
fix; a real `*webrtc.TrackRemote` still can't be constructed in a unit test
at all, since every field is private with no exported constructor, so the
"still stuck, N attempts, then escalates" full integration path remains
covered only by the pure `isTrackStillPending` decision plus manual/live
verification, same limitation as before this round).

**Verified:**
- `go build ./pkg/rtc/...`, `go vet ./pkg/rtc/...`, `gofmt -l` all clean.
- New/updated tests: 9/9 pass, repeatably, no `time.Sleep`-based waits.
- Full `pkg/rtc` suite: passes clean on multiple runs. **Caveat:** this
  package has pre-existing flaky tests unrelated to this patch —
  `TestNegotiationFailed`, `TestFilteringCandidates`, and
  `TestFirstAnswerMissedDuringICERestart` in `transport_test.go` do real
  ICE/network-candidate work and fail intermittently (~1 in 3-4 runs)
  **on completely unmodified upstream code too** (confirmed by stashing this
  patch and re-running). Don't be alarmed if CI flakes on one of those three
  specifically; re-run before assuming a regression.

**Not yet done (tracked as follow-ups, not blocking this patch):**
- Production deploy — `infrastructure/livekit/terraform.tfvars`'s
  `livekit_image` still points at the stock `livekit/livekit-server` image.
  This fork is not live anywhere yet; deploying it is a deliberate follow-up
  decision, not a side effect of creating this fork. **This now matters
  more than it did at first open**: the app-side blind timer that used to
  provide SOME (confirmed net-negative, but non-zero) recovery coverage on
  its own has been deleted, so until this fork deploys, the original
  incident class has NO republish-nudge coverage at all.
- The equivalent nudge for the *other* branch that appends to
  `pendingRemoteTracks` (`ti == nil`, a related but distinct AddTrack-timing
  race) — scoped out of this first patch to stay narrowly targeted at the
  exact, confirmed, reproduced production incident.
- Whether renegotiation-based recovery is even the right general mechanism
  is a real open question the review round raised: the incident's own 215
  failed attempts happened WHILE ordinary renegotiations were occurring, and
  the incident only actually cleared via a full client reconnect. The
  escalate-to-`IssueFullReconnect` behavior above is the concrete answer for
  the bounded-attempts case; whether to skip straight to it sooner is a
  tuning question for after this has real production data, not decided
  here.
- A delivery-confirmation/retry pattern for the nudge itself (it's currently
  fire-and-forget over `SendDataMessage(RELIABLE, ...)` — "reliable" bounds
  in-order delivery if the channel is up, not that it arrives at all) —
  `PerformRpc`'s ack/timeout pattern elsewhere in this file could be adapted
  if this needs to be more than best-effort.

## Upstream sync process

No automation yet. Manual process until this needs more rigor:

```bash
git fetch upstream
git checkout master
git merge upstream/master   # resolve conflicts (ARDIUSTECH_FORK.md never will)
git checkout feat/publish-mid-stuck-nudge
git rebase master
go test ./pkg/rtc/...
```

Re-run `go test ./pkg/rtc/... -count=1` a couple of times after any sync
given the flaky-test caveat above — don't rebase-and-ship on a single red run
without checking whether it's one of the three known-flaky tests.
