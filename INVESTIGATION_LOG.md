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
12. **CORRECTED (was wrong in the first pass of this log):** the e2e harness
    does NOT join peers simultaneously — `e2e/sfu-multi-peer.spec.ts`'s join
    loop already staggers each peer by 4 seconds (`"Trickle join (~4s
    apart), not simultaneous. People walk into a room over time"`, its own
    comment). H1 as originally stated (simultaneous-burst-join causes the
    amplification) is **ruled out** — there is no burst in this harness.
    Caught before wasting a test run on it (checked the spec file first,
    per John's explicit ask to analyze before testing).
13. Stock server logs during the control run also showed: `WARN "UDP receive
    buffer is too small for a production set-up" {"current": 425984,
    "suggested": 5000000}`. Flagged in the original 2026-07-30 triage doc as
    "not a contributor at 5 people... will bite at 40" — worth re-examining
    given today's much higher failure rate at exactly 5 peers.

14. **N=2 control (minimum possible peer count, same stock image, same
    staggered-join code path):** still failed — `1/2 peers never saw flowing
    video`, both peers hit `"publication of local track timed out, no
    response from server"`. Server-side: **187 `could not get mid` events**
    and 3 `publish time out` supervisor errors in a ~1-minute run with only
    2 people. 23 tracks published successfully in the same window (a mix of
    success and failure, not total breakdown like N=5). No panics/fatal
    errors; no UDP-buffer warning this time (possibly only logged once per
    container lifetime, not per-run).

15. **CONFIRMED — the actual asynchronous gap, located precisely.** Traced
    `SetLocalDescription`/`SetRemoteDescription` in
    `~/go/pkg/mod/.../pion/webrtc/v4@v4.2.17/peerconnection.go` for our
    server's exact role (answerer, processing the client's offer for the
    publish connection — the client always offers for publish, confirmed
    earlier). Key facts:
    - In `SetRemoteDescription` (processing the client's OFFER), the calls to
      `configureRTPReceivers`/`startRTP` are gated by `if weOffer` (lines
      ~1330-1370) — since our server never offers for publish, **neither
      function is called from here at all.** Only the mid-assignment loop
      (fact #6) runs for us in this function.
    - In `SetLocalDescription` (applying our OWN answer), the `weAnswer`
      branch (line ~1140) DOES run `configureRTPReceivers(...)`
      SYNCHRONOUSLY, but wraps the actual receiver-activation in
      **`pc.ops.Enqueue(func() { pc.startRTP(...) })`** — an ASYNCHRONOUS,
      QUEUED operation on pion's internal ops goroutine, NOT a direct call.
    - **This means `SetLocalDescription(answer)` returns to LiveKit's Go
      code BEFORE `startRTP` (the code that actually activates the receiver
      to process incoming RTP) has necessarily run.** If LiveKit sends the
      answer back to the client immediately after `SetLocalDescription`
      returns (the natural, expected implementation — no reason to believe
      otherwise), the client can receive it, complete its own negotiation,
      and start sending RTP — all before the SERVER's own queued `startRTP`
      has executed on its internal goroutine.
    - This is a **real, structural, confirmed asynchronous boundary inside
      pion itself** — not a hypothesis about goroutine scheduling, an actual
      `pc.ops.Enqueue()` call in the SDK's own source.
16. **NOT YET CONFIRMED — the exact downstream link from #15 to "mid empty."**
    `SetMid()` already ran synchronously in `SetRemoteDescription`, well
    before `SetLocalDescription` — so the negotiated transceiver's mid
    SHOULD already be set by the time `startRTP` (whenever it actually runs)
    would cause `OnTrack`/`mediaTrackReceived` to fire normally. Checked one
    candidate explanation — pion's `handleUndeclaredSSRC` fallback (for RTP
    that arrives matching no known transceiver, creates a **brand-new**
    transceiver that never went through `SetMid()` at all) — but that
    function explicitly **declines** to handle media sections with a `rid`
    attribute (`if hasRidAttribute { return false, nil }`), and watercooler's
    simulcast publishes almost certainly declare `rid` — so this SPECIFIC
    fallback is likely NOT the mechanism here. **The precise link between
    "RTP arrives before the queued `startRTP` runs" and "`mediaTrackReceived`
    observes an empty mid" is still open** — haven't found the exact code
    path yet, only proven the timing gap that would allow it.

17. **BREAKTHROUGH — live instrumentation, actual root cause located.** Added
    real logging (not static reading): patched a local copy of pion
    (`vendor-fork/pion-webrtc/`, wired via a `go.mod` `replace` directive) to
    print a timestamped line whenever `SetLocalDescription` returns and
    whenever the queued `startRTP` closure actually executes (with measured
    queue delay); added a matching line in `mediaTrackReceived` for both the
    success and empty-mid cases, including whether `rtpReceiver.RTPTransceiver()`
    is nil or non-nil. Ran N=2 against a Docker image built with this
    instrumentation. Confirmed queue delays of **9–72ms** between
    `SetLocalDescription` returning and `startRTP` actually running — a real,
    measured async gap, not a guess (this alone answers fact #15/H5 with hard
    numbers).

    **But the actual failure sequence, read directly off the timeline, is
    NOT a first-publish race at all:**
    ```
    18:53:00.282125Z  mediaTrackReceived: mid OK   trackID=937580dc… ssrc=1741651686 mid=9
    18:53:00.282233Z  mediaTrackReceived: mid OK   trackID=937580dc… ssrc=1409012324 mid=9
    18:53:00.283131Z  SetLocalDescription(answer): configureRTPReceivers done, ENQUEUEING startRTP
    18:53:00.283145Z  SetLocalDescription RETURNING TO CALLER
    18:53:00.283430Z  startRTP EXECUTING NOW (queued for 285µs)
    18:53:00.283450Z  startRTP RETURNED
    18:53:00.318578Z  mediaTrackReceived: EMPTY MID trackID=937580dc… ssrc=1741651686 transceiver=nil
    18:53:00.318617Z  mediaTrackReceived: EMPTY MID trackID=937580dc… ssrc=1409012324 transceiver=nil
    ```
    **The SAME trackID and SAME SSRCs that already successfully resolved
    (`mid=9`) get processed through `mediaTrackReceived` a SECOND time, ~36ms
    later, right after a fast renegotiation cycle — and on this second pass,
    `rtpReceiver.RTPTransceiver()` is nil.** This is not "RTP arrives before
    the receiver is ready" (that would be a FIRST occurrence, not a repeat of
    an already-successful track). This is: **a track that already works gets
    handed to `mediaTrackReceived` again through some OTHER receiver object
    that was never wired to a transceiver at all**, immediately following a
    renegotiation.
18. This directly implicates `configureRTPReceivers`'s renegotiation branch
    (fact from earlier tracing: `if isRenegotiation { ... receiver.Stop();
    newReceiver := pc.api.NewRTPReceiver(...); transceiver.setReceiver(newReceiver)
    } }`) and/or its SSRC de-duplication logic (`filteredTracks` — "if we
    already have a TrackRemote for a given SSRC don't handle it again",
    which reads `receiver.Tracks()` on the CURRENT receiver) — if the OLD
    receiver gets `.Stop()`'d before this de-dup check runs, its SSRC record
    may no longer show up as "already claimed," causing the SAME SSRC to be
    treated as a genuinely NEW incoming track and routed to a fresh,
    not-yet-wired receiver via a DIFFERENT path than the properly-wired
    `transceiver.setReceiver(newReceiver)` call. **Not yet proven — this is
    the next thing to instrument specifically** (log inside
    `configureRTPReceivers` itself: which branch fires, old vs. new receiver
    pointer identity, and the SSRC de-dup filter's actual input/output for
    this exact trackID).

19. **Mechanism fully traced to a specific code path — deepened
    instrumentation inside `configureRTPReceivers` itself confirms it.**
    Exact captured sequence for one failure (mid=9, a simulcast video
    transceiver):
    ```
    configureRTPReceivers: transceiver mid=9 oldReceiver=0x50ed692608c0 tracks=2
      receiverNeedsStopped=true reason="mid=9 rid=\"h\" ssrc=525456842 ...
      found_no_match_in_incoming"
    configureRTPReceivers: REPLACED receiver for mid=9 oldReceiver=0x50ed695f7440
      newReceiver=0x50ed6aa8b2c0 (transceiver.setReceiver about to run)
    configureRTPReceivers: SURVIVING (treated as NEW) tracks after filter: []
    [...SetLocalDescription returns, startRTP runs 99µs later, all fast...]
    [39ms later] mediaTrackReceived: EMPTY MID ssrc=525456842 transceiver=nil
    ```
    Three video transceivers (mid=7, 8, **and** 9) all got their receivers
    replaced in the SAME renegotiation, all for the identical reason: their
    simulcast `rid` ("h") "found no match in incoming" — i.e. **the SDP being
    processed for THIS renegotiation genuinely does not declare these
    tracks' simulcast rids at all.**
    - **Key structural fact:** for RID-based simulcast (confirmed via the
      `trackDetails` dumps — simulcast entries always show `ssrcs=[]
      rids=[q h]`), the SDP has **no explicit SSRC** for these tracks at
      all — the actual SSRC-to-rid binding only happens at the RTP layer
      (via the `sdes:rtp-stream-id` header extension) as packets arrive, not
      statically in the SDP text. This is why the SSRC-based de-dup filter
      (`filterTrackWithSSRC`) can never protect a simulcast track — it only
      ever sees non-simulcast (empty-rid) entries.
    - **`runIfNewReceiver`** (the function backing BOTH `configureReceiver`
      and `startReceiver` dispatch) matches purely by **mid** + kind +
      direction + `!receiver.haveReceived()` — it does NOT check ssrc/rid at
      all. Confirms the newly-replaced receiver (0x50ed6aa8b2c0) SHOULD be
      the one correctly selected and started, IF the current renegotiation's
      SDP had re-declared this mid's tracks. It didn't (see above), so
      neither `configureReceiver` nor `startReceiver` ever ran for it via
      the normal path — `SURVIVING...: []` (empty) directly confirms this.
    - **The browser's underlying media pipeline never actually stopped
      sending on the old SSRC** (its own local encoder for that simulcast
      layer keeps running independent of what the SDP declares at any given
      renegotiation instant) — so RTP for `ssrc=525456842` keeps arriving at
      the server for a track the current SDP no longer mentions at all. That
      orphaned RTP is what surfaces at `mediaTrackReceived` with
      `transceiver=nil` 30-40ms later — some pion-internal fallback dispatch
      path handles it (not `handleUndeclaredSSRC`, which explicitly declines
      for `rid`-attributed media — traced but not the one firing here; the
      exact fallback code path is still unidentified).
    - **Checked whether LiveKit's own code drops the rid declarations
      itself** (the "mungedOffer" log field name in `participant.go:1198`
      looked suspicious) — it's just a log field name at an error site, not
      evidence of active SDP transformation. No LiveKit-side rid-stripping
      code found. **Not yet determined whether the browser itself
      temporarily omits a simulcast layer's rid from a renegotiation offer
      (e.g. bandwidth-estimation-driven layer suspension) or something else
      entirely** — would need to capture and diff the raw SDP text of a
      working vs. failing renegotiation to settle this definitively.

**Bottom line: this is a simulcast-layer renegotiation churn bug, not a
generic "first publish" race.** A layer's rid briefly disappears from a
renegotiation's SDP while the browser's encoder for that layer is still
transmitting trailing packets, and pion's receiver-replacement + fallback
dispatch for the resulting orphaned RTP produces a transceiver-less receiver
that LiveKit's `mediaTrackReceived` correctly (if unhelpfully) reports as
"could not get mid for track."

## Hypotheses (unconfirmed — state confidence + what would confirm/refute)

- **H5 (new, strongly supported by fact #15):** The real root cause is that
  `SetLocalDescription(answer)` returns — and LiveKit sends the answer to
  the client — before pion's own asynchronously-queued `startRTP` has
  necessarily activated the receiver. This directly answers John's question
  "should the client ever send RTP before verifying negotiation is done":
  the deeper issue isn't client eagerness at all — **the SERVER'S OWN
  answer tells the client "we're done" before the SERVER has confirmed
  itself ready to receive.** Not yet confirmed exactly how this connects to
  the specific "mid empty" symptom (see fact #16), but this is the
  strongest, most concrete lead so far — a real code-level asynchronous gap,
  not a scheduling guess.

- **H1 — RULED OUT (fact #12):** "simultaneous burst join" was wrong; the
  harness already staggers joins 4s apart. Not the explanation.
- **H1b (testing now, replaces H1):** Local e2e severity is driven by
  CUMULATIVE STEADY-STATE LOAD, not a join burst — 5 REAL Chromium processes
  each doing continuous real-time WebRTC encode/decode on ONE laptop is a
  substantial, ever-growing total load even with staggered starts (by the
  time peer 5 joins at ~16s, peers 0-3 are ALL still actively
  encoding/decoding/publishing/subscribing). Production's SFU runs on a
  dedicated c6i.2xlarge EC2 box with no competing browser processes at all.
  **Test:** re-run with far fewer peers (N=2) — much lower cumulative load,
  same staggered-join code path — and see if the failure rate drops sharply.
  **Result (fact #14): partially confirmed.** End-to-end failure rate DID
  drop a lot (5/5 peers failing → 1/2), consistent with cumulative load
  making things WORSE. But it did NOT go away, and the underlying race
  itself is still extremely frequent even at N=2 (187 `could not get mid`
  events for 2 people in ~1 minute — orders of magnitude more than
  production's 215 events across an entire real incident). **Revised
  reading:** two separate things are true at once — (a) this specific LOCAL
  Docker/colima test environment has a much higher BASELINE rate of the
  underlying race than real production, for reasons not yet identified
  (H4 — networking virtualization, resource limits, or something else
  entirely), independent of peer count; AND (b) higher peer count/load makes
  it MORE LIKELY that a given occurrence exhausts all retries and becomes a
  user-visible failure, rather than getting fixed by one of the incidental
  retry paths in time. Both matter, neither alone explains everything.
- **H4 (upgraded — now the leading candidate for why LOCAL baseline severity
  is so much higher than production):** something about this specific local
  Docker/colima setup (NATed/virtualized networking adding latency to
  signaling or media, resource limits, or a different code path entirely)
  causes the underlying mid-race to fire far more often than on production's
  dedicated EC2 box, regardless of peer count. **Not yet tested directly** —
  would need e.g. comparing signaling RTT/timing between local and prod, or
  testing against a non-Docker (bare-metal Go binary) local LiveKit instance
  to isolate whether Docker/colima itself is a factor.
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

1. ~~Run a staggered-peer-join variant~~ — DONE, moot: harness already
   staggers 4s (fact #12, corrected). H1 ruled out.
2. ~~Re-run with fewer peers (N=2)~~ — DONE, see fact #14. Confirms load
   affects END-TO-END failure rate, but the underlying race has a high
   baseline in THIS environment independent of peer count.
3. **[NEXT, not yet done]** Isolate whether Docker/colima itself is the
   baseline-severity factor (H4): either (a) compare local vs. production
   signaling round-trip timing directly, or (b) run the SAME e2e harness
   against a bare-metal `go run ./cmd/server` LiveKit instance (no Docker at
   all) and see if the baseline `could not get mid` rate at N=2 drops from
   ~187/minute to something closer to production's rate.
4. Once (3) either confirms or rules out the local-environment explanation,
   THEN re-run the original diagnostic self-resolution poller (experiment
   #1, fact #9) under whatever configuration produces a realistic ~1-track
   -stuck scenario (matching production), not the current every-track-affected
   scenario, before fully trusting "0% self-resolution" as the final word for
   the real production case. The mechanism-level finding (a full
   unpublish+republish is what actually flushes a stuck transceiver, per the
   handlePendingRemoteTracks correlation in fact #9) is likely still valid
   regardless — that's a property of pion's transceiver state, not of how
   often the environment gets INTO that state — but hasn't been separately
   re-confirmed under a low-baseline-rate condition.
5. **Paused here for a checkpoint with John** (2026-08-01) — this has been a
   long back-and-forth; before spending more experiment time, confirm
   whether isolating the Docker/colima variable (step 3) is worth doing now,
   or whether the existing evidence (mechanism confirmed real via fact #9's
   correlation with handlePendingRemoteTracks flushes; environment-severity
   question still open) is enough to proceed with PR #1 as designed.

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
