import Foundation
import JavaScriptCore
@testable import HubLink
import XCTest

/// Runs the shipped call page, with microphone requests resolved explicitly in each test.
/// These reproduce control-flow defects; they do not simulate iOS routing or audible quality.
final class LinkCallMediaTests: XCTestCase {
    func testMuteWhileMicrophonePermissionIsPendingSurvivesSetup() throws {
        let page = try Page()
        try page.run("offer(false); mute(true);")
        try page.run("resolveMicrophone(0, 'initial');")
        XCTAssertTrue(try page.bool("peer !== undefined"), "The offer must finish before checking mute")
        XCTAssertEqual(try page.number("gain.gain.value"), 0, "Mute pressed during setup must apply to the acquired microphone")
    }

    func testOverlappingMicrophoneSwapsKeepOnlyTheLatestSource() throws {
        let page = try Page()
        try page.offer()
        // Both native route tasks have stopped the old mic before either replacement arrives.
        try page.run("stopMicrophone(); startMicrophone(true); stopMicrophone(); startMicrophone(false);")
        try page.run("resolveMicrophone(2, 'latest');")
        try page.run("resolveMicrophone(1, 'stale');")
        XCTAssertEqual(try page.number("liveSources().length"), 1, "Two live sources mix into the outgoing call")
        XCTAssertEqual(try page.string("microphone.id"), "latest", "An older permission result must not replace the latest route")
    }

    func testHangUpStopsAllMicrophonesAfterOverlappingSwaps() throws {
        let page = try Page()
        try page.offer()
        try page.run("stopMicrophone(); startMicrophone(true); stopMicrophone(); startMicrophone(false);")
        try page.run("resolveMicrophone(2, 'latest');")
        try page.run("resolveMicrophone(1, 'stale'); hangUp();")
        XCTAssertEqual(try page.number("captured.filter(s => !s.track.stopped).length"), 0,
                       "Hangup must release every acquired microphone, including superseded swaps")
    }

    func testMicrophoneArrivingAfterHangUpCannotRestartTheCall() throws {
        let page = try Page()
        try page.run("offer(false); hangUp();")
        try page.run("resolveMicrophone(0, 'late');")
        XCTAssertEqual(try page.number("captured.filter(s => !s.track.stopped).length"), 0,
                       "A late permission result must be stopped after hangup")
        XCTAssertEqual(try page.number("peers.filter(p => !p.closed).length"), 0,
                       "A cancelled offer must not create a new peer connection")
    }

    func testHangUpBetweenPermissionCompletionAndAttachmentReleasesTheMicrophone() throws {
        let page = try Page()
        try page.run("offer(false);")
        // The capture helper resolves first, then hangup runs before offer's continuation.
        try page.run("resolveMicrophone(0, 'late'); Promise.resolve().then(() => hangUp());")
        XCTAssertEqual(try page.number("captured.filter(s => !s.track.stopped).length"), 0)
        XCTAssertEqual(try page.number("peers.filter(p => !p.closed).length"), 0)
    }

    func testRejectedRemotePlaybackIsReportedToTheDevice() throws {
        let page = try Page()
        try page.offer()
        try page.run("voice.play = () => { playAttempts++; return Promise.reject(new Error('playback denied')); }; peer.ontrack({streams: [{}]});")
        XCTAssertTrue(try page.bool("voice.srcObject !== null"), "The remote track must reach the player")
        XCTAssertEqual(try page.number("playAttempts"), 1)
        XCTAssertTrue(try page.bool("messages.some(m => m.failed)"),
                      "A connected call with rejected playback must not silently appear healthy")
    }

    func testMuteAfterSetupMutesTheMicrophoneAndCanBeUndone() throws {
        let page = try Page()
        try page.offer()
        try page.run("mute(true);")
        XCTAssertEqual(try page.number("gain.gain.value"), 0)
        try page.run("mute(false);")
        XCTAssertEqual(try page.number("gain.gain.value"), 1)
    }

    func testSequentialMicrophoneSwapsLeaveOneSource() throws {
        let page = try Page()
        try page.offer()
        try page.run("stopMicrophone(); startMicrophone(true);")
        try page.run("resolveMicrophone(1, 'speaker');")
        try page.run("stopMicrophone(); startMicrophone(false);")
        try page.run("resolveMicrophone(2, 'earpiece');")
        XCTAssertEqual(try page.number("liveSources().length"), 1)
        XCTAssertEqual(try page.string("microphone.id"), "earpiece")
        XCTAssertTrue(try page.bool("captured.slice(0, 2).every(s => s.track.stopped)"))
    }

    func testNormalHangUpReleasesTheMicrophoneAndClosesTransport() throws {
        let page = try Page()
        try page.offer()
        try page.run("hangUp();")
        XCTAssertEqual(try page.number("captured.filter(s => !s.track.stopped).length"), 0)
        XCTAssertTrue(try page.bool("peer.closed && context.state === 'closed'"))
    }

    func testFailedTransportIsReportedToTheDevice() throws {
        let page = try Page()
        try page.offer()
        try page.run("peer.connectionState = 'failed'; peer.onconnectionstatechange();")
        XCTAssertTrue(try page.bool("messages.some(m => m.failed)"))
    }

    func testRemoteTrackWithSuccessfulPlaybackDoesNotReportFailure() throws {
        let page = try Page()
        try page.offer()
        try page.run("peer.ontrack({streams: [{id: 'voice'}]});")
        XCTAssertEqual(try page.number("playAttempts"), 1)
        XCTAssertEqual(try page.string("voice.srcObject.id"), "voice")
        XCTAssertEqual(try page.number("messages.length"), 0)
    }

    func testMediaReadinessRequiresTransportAndSuccessfulPlaybackAndIsReportedOnce() throws {
        let page = try Page()
        try page.offer()
        try page.run("peer.connectionState = 'connected'; peer.onconnectionstatechange();")
        XCTAssertEqual(try page.number("messages.length"), 0)
        try page.run("peer.ontrack({streams: [{id: 'voice'}]});")
        XCTAssertEqual(try page.number("messages.filter(m => m.connected).length"), 1)
        try page.run("peer.onconnectionstatechange();")
        XCTAssertEqual(try page.number("messages.filter(m => m.connected).length"), 1)
    }

    func testMediaReadinessWaitsForPlaybackToFinishStarting() throws {
        let page = try Page()
        try page.offer()
        try page.run("var finishPlayback; voice.play = () => new Promise(resolve => { finishPlayback = resolve; }); peer.connectionState = 'connected'; peer.onconnectionstatechange(); peer.ontrack({streams: [{}]});")
        XCTAssertEqual(try page.number("messages.length"), 0)
        try page.run("finishPlayback();")
        XCTAssertEqual(try page.number("messages.filter(m => m.connected).length"), 1)
    }

    private final class Page {
        private let js: JSContext

        init() throws {
            js = try XCTUnwrap(JSContext())
            try run(Self.devices)
            let html = LinkCallMedia.page
            let start = try XCTUnwrap(html.range(of: "<script>"))
            let end = try XCTUnwrap(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
            try run(String(html[start.upperBound..<end.lowerBound]))
        }

        func run(_ script: String) throws {
            js.exception = nil
            js.evaluateScript(script)
            if let error = js.exception { throw NSError(domain: "CallPageTest", code: 1,
                                                        userInfo: [NSLocalizedDescriptionKey: error.toString() ?? script]) }
        }

        func offer() throws {
            try run("offer(false);")
            try run("resolveMicrophone(0, 'initial');")
            XCTAssertTrue(try bool("peer !== undefined && peer.localDescription.sdp === 'offer'"))
        }

        func number(_ expression: String) throws -> Double { try value(expression).toDouble() }
        func bool(_ expression: String) throws -> Bool { try value(expression).toBool() }
        func string(_ expression: String) throws -> String { try XCTUnwrap(value(expression).toString()) }
        private func value(_ expression: String) throws -> JSValue {
            js.exception = nil
            let result = js.evaluateScript(expression)
            if let error = js.exception { throw NSError(domain: "CallPageTest", code: 2,
                                                        userInfo: [NSLocalizedDescriptionKey: error.toString() ?? expression]) }
            return try XCTUnwrap(result)
        }

        // JavaScriptCore drains promise jobs at each evaluation boundary. No sleeps, network,
        // capture devices, or user permissions are involved; tests select the completion order.
        private static let devices = """
        var requests = [], captured = [], sources = [], peers = [], messages = [], playAttempts = 0;
        var navigator = {mediaDevices: {getUserMedia: constraints => new Promise(resolve => requests.push({resolve, constraints}))}};
        function resolveMicrophone(index, id) {
          const track = {stopped: false, stop() { this.stopped = true; }};
          const stream = {id, track, getTracks: () => [track], getAudioTracks: () => [track]};
          captured.push(stream); requests[index].resolve(stream);
        }
        function liveSources() { return sources.filter(s => s.connected && !s.stream.track.stopped); }
        var voice = {srcObject: null, play: () => { playAttempts++; return Promise.resolve(); }};
        var document = {getElementById: () => voice};
        var window = {webkit: {messageHandlers: {call: {postMessage: body => messages.push(body)}}}};
        function AudioContext() {
          this.state = 'running'; this.sampleRate = 48000;
          this.resume = () => Promise.resolve();
          this.close = () => { this.state = 'closed'; return Promise.resolve(); };
          this.createMediaStreamSource = stream => {
            const source = {stream, connected: false, connect(other) {this.connected = true; return other;}, disconnect() {this.connected = false;}};
            sources.push(source); return source;
          };
          this.createMediaStreamDestination = () => ({stream: {getAudioTracks: () => [{}]}});
          this.createGain = () => ({gain: {value: 1}, connect: other => other});
          this.createBuffer = (channels, length) => ({getChannelData: () => new Float32Array(length)});
          this.createBufferSource = () => ({connect: () => {}, start: () => {}});
        }
        function RTCPeerConnection() {
          peers.push(this); this.closed = false; this.iceGatheringState = 'complete';
          this.localDescription = {sdp: 'offer'};
          this.addTrack = () => {}; this.createDataChannel = () => {};
          this.createOffer = () => Promise.resolve({type: 'offer', sdp: 'offer'});
          this.setLocalDescription = () => Promise.resolve();
          this.close = () => {this.closed = true;};
        }
        """
    }
}
