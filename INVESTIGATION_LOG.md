# Investigation log: "could not get mid for track" root cause

Living document. Update in place as facts/hypotheses change — don't leave
superseded conclusions standing without a note. Started 2026-08-01 after
John pushed back on whether PR #1's fix (client-triggered renegotiation) was
solving root cause or papering over it.

## Verified facts (confirmed by direct code reading or direct observation — cite the source)

1. **Symptom:** `WARN "could not get mid for track"` in
   `pkg/rtc/participant.go`'s `mediaTrackReceived` — fires when RTP arrives
   for a track before the SFU has resolved that track's SDP `mid`.
2. **2026-07-30 production incident** (43 sessions, 26 reconnect cycles for
   one user) had a DIFFERENT root cause — unguarded `publishLocal()` inside
   `connect()` rejecting the whole connect on a cancelled publish. Fixed by
   `ardiustech/watercooler` PR #158. Not this bug.
3. **2026-07-31 production incident:** PR #158 confirmed working (0
   `Cancelled publication` events, churn down 65%). Separate, residual bug
   found: one participant (anonymized identity `f8d24b3a`) stuck for a full
   2 minutes, 215 `could not get mid for track` events, confirmed via direct
   LiveKit server log analysis over SSM (ground truth, not inferred).
4. **`GetPublisherMid`/`GetMid` reads pion's own transceiver state directly**
   (`rtpReceiver.RTPTransceiver().Mid()`, `pkg/rtc/transport.go:1186`) — NOT
   a separate LiveKit-application bookkeeping map that could lag due to
   LiveKit's own code.
5. Pion's own doc comment on `RTPTransceiver.SetMid`
   (`~/go/pkg/mod/.../pion/webrtc/v4@v4.2.17/rtptransceiver.go:230`): mid
   "will be set in `CreateOffer` or `CreateAnswer`."
6. **Traced pion's `SetRemoteDescription`** (`peerconnection.go` ~line
   1180-1400): for an incoming OFFER (the publisher-connection direction,
   client offers), mid assignment (`SetMid`, ~line 1296) happens BEFORE
   `startRTP`/`startRTPReceivers()` (~line 1381) is even called — sequential,
   same goroutine, within ONE function call. **This undermines the naive
   "two racing goroutines within a single negotiation" theory** — that
   specific mechanism doesn't show up in pion's own code structure the way
   early analysis assumed.
7. **Traced `livekit-client`'s `publishTrack()`** (`publishOrRepublishTrack`
   → `publish()` → `negotiate()`): only confirms the CLIENT's own
   offer/answer round-trip completed. There is no protocol mechanism for the
   server to report back "and my internal receiver wiring has also settled."
   `publishTrack()` isn't lying — it structurally cannot know about
   server-internal state.
8. **`handlePendingRemoteTracks()`** (the only retry mechanism for a stuck
   track) is called from exactly 3 places in `participant.go`, ALL
   client-initiated: a fresh offer, an `AddTrack` request, or an unpublish.
   No server-proactive trigger exists in unmodified LiveKit.
9. **Diagnostic experiment #1** (`experiment/mid-resolution-timing`, this
   branch — polls `GetPublisherMid` every 5ms for 15s per stuck track,
   purely observational, no intervention; also logs every
   `handlePendingRemoteTracks` flush): 5-peer local e2e repro
   (`WC_SFU_TEST_PEERS=5 npm run test:e2e:sfu` in `ardiustech/watercooler`,
   ALL peers joining simultaneously). Result: **16 independently-stuck
   tracks, 1219 total poll attempts, ZERO resolved on their own.**
   `handlePendingRemoteTracks` flushed queues multiple times per affected
   participant DURING the run (the passive "wait for unrelated
   renegotiation" path DID fire) — still zero resolutions. Only a full
   unpublish+republish (fresh transceiver) has a chance.
10. **Control experiment:** identical test against the completely STOCK,
    unpatched `livekit/livekit-server:v1.13.4` image showed the SAME
    severity — 1082 `could not get mid` events, 9 `publish time out`
    supervisor errors, "5/5 peers never saw flowing video." **This exonerates
    the diagnostic patch** (it didn't cause/worsen anything) but complicates
    interpreting #9: this severity (nearly every track affected) does NOT
    match the real production incident's severity (exactly one participant
    affected out of ~6).
11. Machine load checked post-hoc (`uptime`/`top`/`docker stats`): 80% CPU
    idle, load avg 4.24 at check time. Inconclusive for the actual test
    window (checked after, not during) — John disputed the "heavy load"
    explanation and he's right that it wasn't verified before being asserted.
12. **The e2e harness launches all N peers' Chromium processes and joins
    them essentially simultaneously** (`e2e/sfu-multi-peer.spec.ts`) — a
    burst-concurrency pattern that does NOT match production (people
    trickling into a meeting over seconds), and IS a plausible explanation
    for why local severity (nearly universal failure) vastly exceeds
    production severity (one incident).
13. Stock server logs during the control run also showed: `WARN "UDP receive
    buffer is too small for a production set-up" {"current": 425984,
    "suggested": 5000000}`. Flagged in the original 2026-07-30 triage doc as
    "not a contributor at 5 people... will bite at 40" — worth re-examining
    given today's much higher failure rate at exactly 5 peers.

## Hypotheses (unconfirmed — state confidence + what would confirm/refute)

- **H1 (testing now):** Local e2e severity is amplified by CONCURRENT BURST
  JOIN LOAD (all 5 peers negotiating at the exact same instant), not
  representative of production's actual occurrence rate. **Test:** stagger
  peer joins by 1-2s each instead of launching simultaneously; expect
  failure rate to drop sharply if true.
- **H2 (weakened, not disproven, just unlocated):** A cross-goroutine race
  between mid-assignment and RTP-dispatch. Fact #6 shows this does NOT
  happen the naive way (within one offer's SEQUENTIAL processing). The real
  mechanism, if this class of theory is still right, must be somewhere else
  — not yet located.
- **H3 (untested):** Watercooler publishes mic and camera as two SEPARATE
  `AddTrackRequest`+`negotiate()` cycles (confirmed in client SDK trace,
  fact #7's investigation). Two overlapping negotiations for the SAME
  participant, close together, could interact in a way invisible from
  reading either negotiation's processing in isolation.
- **H4 (untested):** Local Docker/colima resource allocation (CPU/mem given
  to the Docker VM) is materially tighter than the production
  c6i.2xlarge EC2 box, so the SFU falls behind processing signaling
  specifically under concurrent-join load in the LOCAL environment in a way
  it wouldn't in production. Relates to fact #13 (UDP buffer warning).

## Things attempted (chronological)

1. Read/traced LiveKit Go source (`participant.go`, `transportmanager.go`,
   `transport.go`) for the mid-resolution mechanism → facts #4, #6, #8.
2. Traced `livekit-client` JS SDK's `publishTrack`/`publish`/`negotiate` →
   fact #7.
3. Traced pion webrtc v4.2.17 source (`rtptransceiver.go`, `rtpreceiver.go`,
   `peerconnection.go`) for `SetMid`/`startRTP`/`startRTPReceivers` ordering
   → fact #6.
4. Built diagnostic-only patch on this branch: polls `GetPublisherMid` every
   5ms for 15s per stuck track (no intervention), logs every
   `handlePendingRemoteTracks` flush.
5. Ran `WC_SFU_TEST_PEERS=5 npm run test:e2e:sfu` against the patched
   diagnostic build → fact #9 (0/16 self-resolved).
6. Ran the SAME test against stock `v1.13.4` as a control → fact #10 (same
   severity — patch exonerated, but severity mismatch vs. production noted).
7. Checked machine load post-hoc → fact #11 (inconclusive, load looked fine
   in hindsight).

## Current strategy / next steps

1. **[NEXT]** Run a staggered-peer-join variant of the e2e test (peers
   joining ~1-2s apart instead of simultaneously) to test H1.
2. If H1 confirms (staggered join → much lower failure rate): re-run the
   diagnostic self-resolution poller (experiment #1's design) under
   STAGGERED conditions — the "0% self-resolution" data point in fact #9 was
   gathered under an extreme burst with 16 SIMULTANEOUSLY stuck tracks, not
   the realistic "one isolated stuck track" production scenario. Need to
   confirm the conclusion still holds before fully trusting it as the
   justification for PR #1's design.
3. Consider a fewer-peers variant (2-3 simultaneous) as an alternative lower
   -burst-intensity test.
4. If H4 looks plausible after #1-3, try raising `net.core.rmem_max` (or the
   Docker VM's resource allocation) locally and re-testing, to separate
   "genuine protocol race" from "local resource-starvation artifact."
5. Once a clean, realistic reproduction of the ORIGINAL narrow bug (≈1 stuck
   track, not 16) is achieved, re-run the diagnostic poller against THAT
   specifically before treating the "renegotiation is required" conclusion
   as settled for the real production scenario.

## Open questions

- Why does pion's `SetRemoteDescription` sequence mid-assignment before
  RTP-receiver-activation (fact #6), yet a race is still observed in
  practice? The actual mechanism is still not located (see H2, H3).
- Does production ever see MULTIPLE tracks stuck simultaneously (like the
  local burst test), or is it always exactly one, as in both the 07-30 and
  07-31 incidents? If always exactly one in production, that itself supports
  H1 (burst-amplification is a local-test artifact, not how this manifests
  for real).
- Is the local Docker test environment under-provisioned relative to
  production in a way that materially changes these results (H4)?
