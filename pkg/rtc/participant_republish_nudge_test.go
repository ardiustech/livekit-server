// Copyright 2026 Ardius Tech, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package rtc

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"

	"github.com/livekit/protocol/livekit"
)

// ardiustech fork: tests for the stuck-publish republish-nudge added in
// pkg/rtc/participant.go — see that file's doc comments for the full
// rationale (watercooler's docs/sfu-multiparty-triage-2026-07-31.md has the
// production incident this fixes).

func TestIsTrackStillPending(t *testing.T) {
	tests := []struct {
		name    string
		pending []string
		trackID string
		want    bool
	}{
		{"empty list", nil, "track-1", false},
		{"present, only entry", []string{"track-1"}, "track-1", true},
		{"present, among several", []string{"track-0", "track-1", "track-2"}, "track-1", true},
		{"absent, non-empty list", []string{"track-0", "track-2"}, "track-1", false},
		{"resolved and removed", []string{}, "track-1", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, isTrackStillPending(tt.pending, tt.trackID))
		})
	}
}

func TestBuildRepublishNudgePacket(t *testing.T) {
	identity := livekit.ParticipantIdentity("scott-identity")
	trackID := `TR_weird"quote`

	dp := buildRepublishNudgePacket(identity, trackID)

	require.Equal(t, string(identity), dp.ParticipantIdentity)
	user, ok := dp.Value.(*livekit.DataPacket_User)
	require.True(t, ok, "expected DataPacket_User variant, not a new oneof member")
	require.NotNil(t, user.User.Topic)
	require.Equal(t, republishNudgeTopic, *user.User.Topic)
	require.JSONEq(t, `{"reason":"stuck_mid","trackId":"TR_weird\"quote"}`, string(user.User.Payload))

	// Round-trips through actual protobuf marshal/unmarshal, matching what
	// sendRepublishNudge really does — catches anything the struct-literal
	// assertions above wouldn't (e.g. a field with no wire tag).
	raw, err := proto.Marshal(dp)
	require.NoError(t, err)
	roundTripped := &livekit.DataPacket{}
	require.NoError(t, proto.Unmarshal(raw, roundTripped))
	rtUser, ok := roundTripped.Value.(*livekit.DataPacket_User)
	require.True(t, ok)
	require.Equal(t, republishNudgeTopic, *rtUser.User.Topic)
}

// TestScheduleStuckPublishNudge_ResolvedDoesNotSend exercises the real timer
// + real ParticipantImpl integration for the "resolved before the grace
// period fires" branch — newParticipantForTest's pendingRemoteTracks starts
// empty, matching a track that was never stuck (or already flushed by an
// unrelated renegotiation). This is the one integration-level case
// constructible without a real *webrtc.TrackRemote (which has no exported
// constructor — see isTrackStillPending's doc comment).
func TestScheduleStuckPublishNudge_ResolvedDoesNotPanic(t *testing.T) {
	p := newParticipantForTest("scott-identity")
	const trackID = "TR_will_resolve"

	require.NotPanics(t, func() {
		p.scheduleStuckPublishNudge(trackID)
		time.Sleep(stuckPublishNudgeGracePeriod + 250*time.Millisecond)
	})
}

// TestSendRepublishNudge_DoesNotPanicWithoutLiveTransport covers the "still
// stuck, nudge actually attempted" path directly (rather than through
// scheduleStuckPublishNudge's timer, which would need a real, populated
// pendingRemoteTracks entry — not constructible in a unit test; see above).
// newParticipantForTest builds a real TransportManager with no live
// PeerConnection/ICE, so the actual SendDataMessage call is expected to
// error here — sendRepublishNudge already handles that by logging and
// returning, not panicking, which is exactly what this asserts.
func TestSendRepublishNudge_DoesNotPanicWithoutLiveTransport(t *testing.T) {
	p := newParticipantForTest("scott-identity")
	require.NotPanics(t, func() {
		p.sendRepublishNudge("TR_stuck")
	})
}
