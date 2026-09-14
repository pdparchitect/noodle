import AppKit
import SwiftUI
import Observation
import XCTest
import NoodleCore
@testable import Noodle

@MainActor private final class SilentVoicePlayer: VoicePlaybackPlayer {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 12
    var isPlaying = false
    var allowsPlayback = true
    var plays = 0
    var pauses = 0
    func play() -> Bool { plays += 1; isPlaying = allowsPlayback; return isPlaying }
    func pause() { pauses += 1; isPlaying = false }
}

@MainActor private final class VoicePlayerFactory {
    var players: [URL: SilentVoicePlayer] = [:]
    var requested: [URL] = []
    var failures = Set<URL>()
    func make(_ url: URL) throws -> any VoicePlaybackPlayer {
        requested.append(url)
        if failures.contains(url) { throw CocoaError(.fileReadNoSuchFile) }
        let player = players[url] ?? SilentVoicePlayer(); players[url] = player; return player
    }
}

@MainActor private final class PlaybackFixture {
    let factory = VoicePlayerFactory()
    let clock = RuntimeClockFixture()
    let playback: VoicePlayback
    init() {
        let factory = factory, clock = clock
        playback = VoicePlayback(makePlayer: { try factory.make($0) }, sleep: { try await clock.sleep($0) })
    }
}

@MainActor @Observable private final class VoiceSelection {
    var url = URL(fileURLWithPath: "/fixture/first.m4a")
    var visible = true
    var mounted = true
}

@MainActor final class VoicePlaybackTests: HiddenViewTests {
    private let a = URL(fileURLWithPath: "/fixture/first.m4a")
    private let b = URL(fileURLWithPath: "/fixture/second.m4a")
    private let voice = VoiceMessage(transcript: "Fixture transcript", duration: 12, waveform: [0.1, 0.6, 0.3], localeIdentifier: "en")
    private func playbackFixture() -> PlaybackFixture {
        let f = PlaybackFixture()
        addTeardownBlock { @MainActor in f.playback.stop(reset: true); f.clock.releaseAll() }
        return f
    }

    func testPauseAndResumeKeepPositionAndReuseTheSameRecording() async throws {
        let f = playbackFixture(); f.playback.toggle(url: a)
        let player = try XCTUnwrap(f.factory.players[a]); XCTAssertTrue(f.playback.playing)
        player.currentTime = 3
        let tick = try await f.clock.next(.milliseconds(100)); tick.resolve(.success(()))
        try await wait { f.playback.position == 3 }
        f.playback.toggle(url: a)
        XCTAssertFalse(f.playback.playing); XCTAssertFalse(player.isPlaying); XCTAssertEqual(f.playback.position, 3)
        f.playback.toggle(url: a)
        XCTAssertTrue(f.playback.playing); XCTAssertEqual(player.currentTime, 3)
        XCTAssertEqual(f.factory.requested, [a]); XCTAssertEqual(player.plays, 2)
    }

    func testNaturalCompletionResetsPositionAndAllowsReplay() async throws {
        let f = playbackFixture(); f.playback.toggle(url: a)
        let player = try XCTUnwrap(f.factory.players[a])
        player.currentTime = player.duration; player.isPlaying = false
        let tick = try await f.clock.next(.milliseconds(100)); tick.resolve(.success(()))
        try await wait { !f.playback.playing }
        XCTAssertEqual(f.playback.position, 0); XCTAssertEqual(player.currentTime, 0)
        f.playback.toggle(url: a)
        XCTAssertTrue(f.playback.playing); XCTAssertEqual(player.plays, 2)
    }

    func testSeekingClampsToRecordingBoundsAndReplayUpdatesPositionImmediately() throws {
        let f = playbackFixture(); f.playback.seek(0.5); XCTAssertEqual(f.playback.position, 0)
        f.playback.toggle(url: a); f.playback.stop()
        let player = try XCTUnwrap(f.factory.players[a])
        f.playback.seek(-1); XCTAssertEqual(player.currentTime, 0)
        f.playback.seek(0.5); XCTAssertEqual(player.currentTime, 6); XCTAssertEqual(f.playback.position, 6)
        f.playback.seek(2); XCTAssertEqual(player.currentTime, 12)
        f.playback.toggle(url: a)
        XCTAssertEqual(player.currentTime, 0); XCTAssertEqual(f.playback.position, 0)
    }

    func testChangingRecordingAfterPauseCreatesANewPlayerAtTheBeginning() throws {
        let f = playbackFixture(); f.playback.toggle(url: a); f.playback.seek(0.5); f.playback.stop()
        f.playback.toggle(url: b)
        XCTAssertEqual(f.factory.requested, [a, b]); XCTAssertEqual(f.playback.position, 0)
        XCTAssertEqual(f.factory.players[b]?.isPlaying, true)
        XCTAssertEqual(f.factory.players[a]?.isPlaying, false)
    }

    func testChangingRecordingWhilePlayingStopsOldAudioAndStartsTheReplacement() throws {
        let f = playbackFixture(); f.playback.toggle(url: a)
        f.playback.toggle(url: b)
        XCTAssertEqual(f.factory.requested, [a, b])
        XCTAssertTrue(f.playback.playing); XCTAssertEqual(f.factory.players[b]?.isPlaying, true)
        XCTAssertEqual(f.factory.players[a]?.isPlaying, false)
    }

    func testStartingAnotherMessageStopsTheCurrentlyActivePlayer() {
        let first = playbackFixture(), second = playbackFixture()
        first.playback.toggle(url: a); second.playback.toggle(url: b)
        XCTAssertFalse(first.playback.playing); XCTAssertTrue(second.playback.playing)
        XCTAssertEqual(first.factory.players[a]?.isPlaying, false)
        XCTAssertEqual(second.factory.players[b]?.isPlaying, true)
    }

    func testMissingRecordingAndPlaybackFailuresCanBeRetried() throws {
        let f = playbackFixture(); f.factory.failures.insert(a)
        f.playback.toggle(url: a)
        XCTAssertNotNil(f.playback.error); XCTAssertFalse(f.playback.playing)
        f.factory.failures.remove(a)
        let player = SilentVoicePlayer(); player.allowsPlayback = false; f.factory.players[a] = player
        f.playback.toggle(url: a)
        XCTAssertEqual(f.playback.error, "The recording couldn’t be played."); XCTAssertFalse(f.playback.playing)
        player.allowsPlayback = true; f.playback.toggle(url: a)
        XCTAssertNil(f.playback.error); XCTAssertTrue(f.playback.playing)
    }

    func testCancelledTimerCannotOverwriteStateAfterStopOrRestart() async throws {
        let f = playbackFixture(); f.playback.toggle(url: a)
        let retired = try await f.clock.next(.milliseconds(100))
        f.playback.stop(reset: true); f.playback.toggle(url: a); f.playback.seek(0.5)
        retired.resolve(.success(()))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(f.playback.playing); XCTAssertEqual(f.playback.position, 6)
        f.playback.stop(reset: true)
        XCTAssertFalse(f.playback.playing); XCTAssertEqual(f.playback.position, 0)
    }

    func testNativePlaybackButtonsAndAccessibleSeekingUseThePlayer() async throws {
        let f = playbackFixture()
        let view = host(VoiceMessagePlayer(url: a, voice: voice, playback: f.playback))
        press(try await control("Play voice message", in: view))
        try await wait { f.playback.playing }
        let position = try await control("Playback position", in: view)
        _ = adjust(position, increasing: true)
        try await wait { f.playback.position == 5 }
        _ = adjust(position, increasing: false)
        try await wait { f.playback.position == 0 }
        press(try await control("Pause voice message", in: view))
        try await wait { !f.playback.playing }
    }

    func testLeavingAConversationAndRemovingTheViewStopPlayback() async throws {
        let f = playbackFixture(), selection = VoiceSelection()
        let view = host(VoiceFixtureView(selection: selection, voice: voice, playback: f.playback))
        press(try await control("Play voice message", in: view))
        try await wait { f.playback.playing }
        selection.visible = false
        try await wait { !f.playback.playing }
        selection.visible = true
        press(try await control("Play voice message", in: view))
        try await wait { f.playback.playing }
        selection.mounted = false
        try await wait { !f.playback.playing }
        XCTAssertEqual(f.factory.players[a]?.isPlaying, false)
    }

    func testReusedViewStopsPlaybackWhenItsRecordingChanges() async throws {
        let f = playbackFixture(), selection = VoiceSelection()
        let view = host(VoiceFixtureView(selection: selection, voice: voice, playback: f.playback))
        press(try await control("Play voice message", in: view))
        try await wait { f.playback.playing }
        selection.url = b
        try await wait { !f.playback.playing }
        press(try await control("Play voice message", in: view))
        try await wait { f.factory.players[self.b]?.isPlaying == true }
        XCTAssertEqual(f.factory.players[a]?.isPlaying, false)
    }

    func testPlaybackFailureIsVisibleAndTranscriptsShowTheirSavedText() async throws {
        let f = playbackFixture(); f.factory.failures.insert(a)
        let view = host(VoiceMessagePlayer(url: a, voice: voice, playback: f.playback))
        press(try await control("Play voice message", in: view))
        let error = try XCTUnwrap(f.playback.error)
        _ = try await control(error, in: view)
        let transcript = host(VoiceTranscriptSheet(voice: voice))
        _ = try await control("Fixture transcript", in: transcript)
        press(try await control("Done", in: transcript))
        let absent = host(VoiceTranscriptSheet(voice: VoiceMessage(transcript: nil, duration: 0, waveform: [], localeIdentifier: nil)))
        _ = try await control("No transcript available.", in: absent)
    }
}

@MainActor private struct VoiceFixtureView: View {
    let selection: VoiceSelection
    let voice: VoiceMessage
    let playback: VoicePlayback
    var body: some View {
        if selection.mounted {
            VoiceMessagePlayer(url: selection.url, voice: voice, shouldPlay: selection.visible, playback: playback)
        }
    }
}
