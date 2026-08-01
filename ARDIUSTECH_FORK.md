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

The app-side handler (in `ardiustech/watercooler`, NOT this repo) listens for
`RoomEvent.DataReceived` with topic `_ardiustech_republish_nudge` and calls
its own already-existing `room.localParticipant.republishAllTracks()` — the
same recovery action its client-side blind timer already used, just
triggered by a real signal instead of a fixed-delay guess. That app-side
change is tracked separately and not yet implemented as of this fork's
creation (2026-07-31).

**Files changed:** `pkg/rtc/participant.go` (+100 lines: two new pure
functions — `isTrackStillPending`, `buildRepublishNudgePacket` — plus the
scheduling/send glue), `pkg/rtc/participant_republish_nudge_test.go` (new,
covers both pure functions directly and smoke-tests the real
`ParticipantImpl` integration for the "resolved" and "still stuck, attempt
send" branches — a real `*webrtc.TrackRemote` can't be constructed in a unit
test at all, since every field is private with no exported constructor, so
the "still stuck" integration path is exercised via `sendRepublishNudge`
directly rather than through a fabricated `pendingRemoteTracks` entry).

**Verified:**
- `go build ./pkg/rtc/...` and `go vet ./pkg/rtc/...` clean.
- New tests: 4/4 pass, repeatably.
- Full `pkg/rtc` suite: passes clean on multiple runs. **Caveat:** this
  package has pre-existing flaky tests unrelated to this patch —
  `TestNegotiationFailed`, `TestFilteringCandidates`, and
  `TestFirstAnswerMissedDuringICERestart` in `transport_test.go` do real
  ICE/network-candidate work and fail intermittently (~1 in 3-4 runs)
  **on completely unmodified upstream code too** (confirmed by stashing this
  patch and re-running). Don't be alarmed if CI flakes on one of those three
  specifically; re-run before assuming a regression.

**Not yet done (tracked as follow-ups, not blocking this patch):**
- The `ardiustech/watercooler` client-side handler for the new data-channel
  signal.
- Production deploy — `infrastructure/livekit/terraform.tfvars`'s
  `livekit_image` still points at the stock `livekit/livekit-server` image.
  This fork is not live anywhere yet; deploying it is a deliberate follow-up
  decision, not a side effect of creating this fork.
- The equivalent nudge for the *other* branch that appends to
  `pendingRemoteTracks` (`ti == nil`, a related but distinct AddTrack-timing
  race) — scoped out of this first patch to stay narrowly targeted at the
  exact, confirmed, reproduced production incident.

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
