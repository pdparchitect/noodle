import Foundation
import XCTest
@testable import LocalMacCore

final class ServiceUpdateTests: XCTestCase {
    let current = Data("current".utf8), previous = Data("previous".utf8)
    func testVersionAndImageIdentityMustMatch() throws {
        let encoded = try JSONEncoder().encode(LocalMacServiceInfo(fingerprint: current))
        let info = try JSONDecoder().decode(LocalMacServiceInfo.self, from: encoded)
        XCTAssertTrue(try info.isReady(expected: current))
        XCTAssertThrowsError(try info.isReady(expected: previous))
        var incompatible = info; incompatible.protocolVersion += 1
        XCTAssertThrowsError(try incompatible.isReady(expected: current))
    }
    func testRestartReconnectsThroughTemporaryUnavailability() async throws {
        var calls = 0
        try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
            calls += 1
            switch calls {
            case 1: return LocalMacServiceInfo(fingerprint: self.previous, restarting: true)
            case 2: throw LocalMacServiceUnavailable()
            default: return LocalMacServiceInfo(fingerprint: self.current)
            }
        }, pause: {})
        XCTAssertEqual(calls, 3)
    }
    func testBusyOldServiceAndLegacyServiceFailWithoutRetryingMutations() async {
        for legacy in [true, false] {
            var calls = 0
            do {
                try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
                    calls += 1
                    if legacy { throw LocalMacError(LocalMacServiceInfo.restartMessage) }
                    return LocalMacServiceInfo(fingerprint: self.previous)
                }, pause: {})
                XCTFail("Must reject an old service")
            } catch { XCTAssertEqual(calls, 1) }
        }
    }
    func testRestartHasABoundedWait() async {
        var calls = 0
        do {
            try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
                calls += 1
                return LocalMacServiceInfo(fingerprint: self.previous, restarting: true)
            }, pause: {})
            XCTFail("Must time out")
        } catch { XCTAssertEqual(calls, 12) }
    }
    func testReplacementCanRecoverWhenTheOldRestartReplyFailsAuthentication() async throws {
        var calls = 0
        try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
            calls += 1
            // A signed request reaches the old helper, which exits, but macOS
            // rejects its reply because its old executable has been removed.
            if calls < 3 { throw LocalMacServiceUnavailable() }
            return LocalMacServiceInfo(fingerprint: self.current)
        }, pause: {})
        XCTAssertEqual(calls, 3)
    }
    func testUnavailableServiceIsBoundedAndNeverTreatedAsReady() async {
        var calls = 0
        do {
            try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
                calls += 1
                throw LocalMacServiceUnavailable()
            }, pause: {})
            XCTFail("No verified reply must never mean ready")
        } catch {
            XCTAssertTrue(error is LocalMacServiceUnavailable)
            XCTAssertEqual(calls, 12)
        }
    }
    func testTransportRecoveryStillRefusesTheWrongVerifiedImage() async {
        var calls = 0
        do {
            try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
                calls += 1
                if calls == 1 { throw LocalMacServiceUnavailable() }
                return LocalMacServiceInfo(fingerprint: self.previous)
            }, pause: {})
            XCTFail("The verified image must also match the installed build")
        } catch {
            XCTAssertFalse(error is LocalMacServiceUnavailable)
            XCTAssertEqual(calls, 2)
        }
    }
    func testCancellationIsNotRetried() async {
        var calls = 0
        do {
            try await LocalMacServiceUpdate.waitUntilReady(expected: current, read: {
                calls += 1
                throw CancellationError()
            }, pause: {})
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(calls, 1)
        }
    }
}
