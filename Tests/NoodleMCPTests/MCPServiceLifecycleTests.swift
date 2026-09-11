import XCTest
import NoodleCore
@testable import NoodleMCP

final class MCPServiceLifecycleTests: XCTestCase {
    func testHeldResponseSucceedsOnlyAfterFixtureRelease() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        XCTAssertNil(call.result)
        held.release()
        await assertCompleted(call)
        assertSuccess(call)
        XCTAssertEqual(fixture.count("tools/call"), 1)
    }

    func testDisconnectLeavesAnotherConnectionsActiveRequestAlone() async throws {
        let fixture = try MCPLifecycleFixture()
        let other = try MCPConnectionRecord(name: "Second synthetic account", endpoint: fixture.endpoint)
        fixture.vault.save(try XCTUnwrap(fixture.vault.load(fixture.record.id)), id: other.id)
        let firstHeld = fixture.hold("tools/call")
        let first = fixture.call()
        await fulfillment(of: [firstHeld.entered], timeout: 2)
        let otherHeld = fixture.hold("tools/call")
        let request = MCPBridgeRequest(session: "fixture", connectionID: other.id, action: .call, tool: "echo", arguments: nil)
        let second = LifecycleOperation { try await fixture.service.perform(request, connection: other) }
        await fulfillment(of: [otherHeld.entered], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        await assertCompleted(first)
        assertFailure(first, .revoked)
        XCTAssertNil(second.result, "The other connection must remain paused, not cancelled")
        XCTAssertNotNil(fixture.vault.load(other.id))
        firstHeld.release()
        otherHeld.release()
        await assertCompleted(second)
        assertSuccess(second)
        XCTAssertEqual(fixture.count("tools/call"), 2)
    }

    func testExpiredRequestFailsBeforeStartingTransport() async throws {
        let fixture = try MCPLifecycleFixture()
        let call = fixture.call(expiresIn: -1)
        await assertCompleted(call)
        assertFailure(call, .timedOut)
        XCTAssertEqual(fixture.count("initialize"), 0)
        XCTAssertEqual(fixture.count("tools/call"), 0)
    }

    func testAlreadyCancelledCallerCannotEnqueueWork() async throws {
        let fixture = try MCPLifecycleFixture()
        let starting = LifecycleGate()
        let call = LifecycleOperation {
            await starting.wait()
            return try await fixture.service.perform(fixture.request(), connection: fixture.record)
        }
        await fulfillment(of: [starting.entered], timeout: 2)
        call.task.cancel()
        await starting.release()
        await assertCompleted(call)
        assertCancelled(call)
        XCTAssertEqual(fixture.count("initialize"), 0)
    }

    func testDisconnectDuringBrowserCallbackDoesNotExchangeOrRestoreCredentials() async throws {
        let fixture = try MCPLifecycleFixture()
        let browser = LifecycleGate()
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect) { url in
                await browser.wait()
                return try MCPLifecycleFixture.callback(url)
            }
        }
        await fulfillment(of: [browser.entered], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        await browser.release()
        await assertCompleted(signIn)
        assertFailure(signIn, .revoked)
        XCTAssertNil(fixture.vault.load(fixture.record.id))
        XCTAssertEqual(fixture.count("authorization_code"), 0, "A late callback must not exchange a code after disconnect")
    }

    func testCancelledSignInCannotPersistLateBrowserSuccessAndCanBeRetried() async throws {
        let fixture = try MCPLifecycleFixture()
        let browser = LifecycleGate()
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect) { url in
                await browser.wait()
                return try MCPLifecycleFixture.callback(url)
            }
        }
        await fulfillment(of: [browser.entered], timeout: 2)
        signIn.task.cancel()
        await browser.release()
        await assertCompleted(signIn)
        assertCancelled(signIn)
        XCTAssertEqual(fixture.vault.load(fixture.record.id)?.accessToken, "synthetic-access")
        XCTAssertEqual(fixture.count("authorization_code"), 0)
        try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect) { try MCPLifecycleFixture.callback($0) }
        XCTAssertEqual(fixture.vault.load(fixture.record.id)?.accessToken, "synthetic-new-access")
    }

    func testSignInCancellationDuringTokenExchangeIsReportedAsCancellation() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("authorization_code")
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect) { try MCPLifecycleFixture.callback($0) }
        }
        await fulfillment(of: [held.entered], timeout: 2)
        signIn.task.cancel()
        let finished = await signIn.wait()
        let stopped = await XCTWaiter.fulfillment(of: [held.stopped], timeout: 1) == .completed
        held.release()
        XCTAssertTrue(finished)
        XCTAssertTrue(stopped)
        assertCancelled(signIn)
        XCTAssertEqual(fixture.vault.load(fixture.record.id)?.accessToken, "synthetic-access")
    }

    func testDisconnectDuringRefreshDoesNotRestoreTokens() async throws {
        let fixture = try MCPLifecycleFixture(expired: true)
        let held = fixture.hold("refresh_token")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        let finished = await call.wait()
        held.release()
        XCTAssertTrue(finished)
        assertFailure(call, .revoked)
        XCTAssertNil(fixture.vault.load(fixture.record.id))
        XCTAssertEqual(fixture.count("tools/call"), 0)
    }

    func testDisconnectWhileSignInWaitsForOldRefreshCannotStartNewAuthorization() async throws {
        let fixture = try MCPLifecycleFixture(expired: true)
        let held = fixture.hold("refresh_token")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        let waiting = expectation(description: "sign-in waiting for existing work")
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect, progress: { message in
                if message == "Waiting for existing requests…" { waiting.fulfill() }
            }) { url in
                XCTFail("Disconnected sign-in must not open a browser")
                return try MCPLifecycleFixture.callback(url)
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        held.release()
        await assertCompleted(signIn)
        await assertCompleted(call)
        assertFailure(signIn, .revoked)
        XCTAssertNil(fixture.vault.load(fixture.record.id))
        XCTAssertEqual(fixture.count("/register"), 0)
        XCTAssertEqual(fixture.count("authorization_code"), 0)
    }

    func testCancellingSignInWaitingForAnActiveCallLeavesThatCallRunning() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        let waiting = expectation(description: "sign-in waiting for the active call")
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect, progress: { message in
                if message == "Waiting for existing requests…" { waiting.fulfill() }
            }) { url in
                XCTFail("Cancelled sign-in must not open a browser")
                return try MCPLifecycleFixture.callback(url)
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        signIn.task.cancel()
        let cancelled = await signIn.wait()
        XCTAssertNil(call.result, "Cancelling sign-in must leave the other caller's request paused")
        held.release()
        XCTAssertTrue(cancelled, "Sign-in cancellation must not wait for the active call")
        assertCancelled(signIn)
        await assertCompleted(call)
        assertSuccess(call)
        XCTAssertEqual(fixture.count("authorization_code"), 0)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
    }

    func testLateRegistrationAfterDisconnectIsDiscarded() async throws {
        let fixture = try MCPLifecycleFixture()
        fixture.vault.remove(fixture.record.id)
        let held = fixture.hold("/register")
        let signIn = LifecycleOperation {
            try await fixture.service.signIn(fixture.record, redirectURI: fixture.redirect) { url in
                XCTFail("Revoked registration must not start browser authorization")
                return try MCPLifecycleFixture.callback(url)
            }
        }
        await fulfillment(of: [held.entered], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        held.release()
        await assertCompleted(signIn)
        assertFailure(signIn, .revoked)
        XCTAssertNil(fixture.vault.load(fixture.record.id))
        XCTAssertEqual(fixture.count("authorization_code"), 0)
    }

    func testCancellationDuringInitializationClosesTransport() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("initialize")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        call.task.cancel()
        let finished = await call.wait()
        let stopped = await XCTWaiter.fulfillment(of: [held.stopped], timeout: 1) == .completed
        held.release()
        XCTAssertTrue(finished)
        XCTAssertTrue(stopped)
        assertCancelled(call)
        XCTAssertEqual(fixture.count("tools/call"), 0)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
    }

    func testTimeoutDuringPermissionCheckRejectsItsLateAnswer() async throws {
        let fixture = try MCPLifecycleFixture()
        let permission = LifecycleGate()
        let call = fixture.call(expiresIn: 0.4) { await permission.wait(); return true }
        await fulfillment(of: [permission.entered], timeout: 2)
        let finished = await call.wait()
        await permission.release()
        XCTAssertTrue(finished)
        assertFailure(call, .timedOut)
        XCTAssertEqual(fixture.count("tools/call"), 0)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
        XCTAssertEqual(fixture.count("tools/call"), 1)
    }

    func testCallerCancellationStopsAnActiveToolRequestAndAllowsNextCall() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let call = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        call.task.cancel()
        let finished = await call.wait()
        let stopped = await XCTWaiter.fulfillment(of: [held.stopped], timeout: 0.5) == .completed
        held.release()
        XCTAssertTrue(finished, "Cancelling the caller must finish promptly")
        XCTAssertTrue(stopped, "Cancellation must also stop the HTTP request")
        assertCancelled(call)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
        XCTAssertEqual(fixture.count("tools/call"), 2)
    }

    func testCancelledQueuedCallFinishesWithoutSendingAndPreservesSerialization() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let first = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        let second = fixture.call()
        second.task.cancel()
        let cancelled = await second.wait()
        let third = fixture.call()
        XCTAssertEqual(fixture.count("tools/call"), 1)
        held.release()
        XCTAssertTrue(cancelled, "A cancelled queued caller must not wait for the active request")
        await assertCompleted(first)
        await assertCompleted(third)
        assertCancelled(second)
        assertSuccess(first)
        assertSuccess(third)
        XCTAssertEqual(fixture.count("tools/call"), 2, "Only the first and third requests may reach the server")
    }

    func testDisconnectStopsActiveAndQueuedCallsAndRejectsLateSuccess() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let first = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        let queued = fixture.call()
        try await fixture.service.disconnect(fixture.record.id)
        let firstFinished = await first.wait()
        let queuedFinished = await queued.wait()
        held.release()
        XCTAssertTrue(firstFinished)
        XCTAssertTrue(queuedFinished)
        assertFailure(first, .revoked)
        XCTAssertNotNil(queued.result)
        if case .success? = queued.result { XCTFail("A queued call succeeded after disconnect") }
        XCTAssertEqual(fixture.count("tools/call"), 1)
        XCTAssertNil(fixture.vault.load(fixture.record.id))
        fixture.seed()
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
    }

    func testRequestDeadlineIncludesWaitingInQueue() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let first = fixture.call()
        await fulfillment(of: [held.entered], timeout: 2)
        let queued = fixture.call(expiresIn: 0.4)
        let finished = await queued.wait()
        held.release()
        XCTAssertTrue(finished, "A queued request must respect its own deadline")
        assertFailure(queued, .timedOut)
        await assertCompleted(first)
        assertSuccess(first)
        XCTAssertEqual(fixture.count("tools/call"), 1)
    }

    func testRequestDeadlineIncludesTokenRefresh() async throws {
        let fixture = try MCPLifecycleFixture(expired: true)
        let held = fixture.hold("refresh_token")
        let call = fixture.call(expiresIn: 0.4)
        await fulfillment(of: [held.entered], timeout: 2)
        let finished = await call.wait()
        held.release()
        XCTAssertTrue(finished)
        assertFailure(call, .timedOut)
        XCTAssertEqual(fixture.count("tools/call"), 0)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
    }

    func testToolTimeoutStopsTransportAndDoesNotBlockNextRequest() async throws {
        let fixture = try MCPLifecycleFixture()
        let held = fixture.hold("tools/call")
        let call = fixture.call(expiresIn: 0.4)
        await fulfillment(of: [held.entered], timeout: 2)
        let finished = await call.wait()
        let stopped = await XCTWaiter.fulfillment(of: [held.stopped], timeout: 0.5) == .completed
        held.release()
        XCTAssertTrue(finished)
        XCTAssertTrue(stopped)
        assertFailure(call, .timedOut)
        let next = fixture.call()
        await assertCompleted(next)
        assertSuccess(next)
    }

    func testRevocationWhileAuthorizationCheckIsSuspendedPreventsNetworkRequest() async throws {
        let fixture = try MCPLifecycleFixture()
        let permission = LifecycleGate()
        let call = fixture.call { await permission.wait(); return true }
        await fulfillment(of: [permission.entered], timeout: 2)
        try await fixture.service.disconnect(fixture.record.id)
        await permission.release()
        await assertCompleted(call)
        assertFailure(call, .revoked)
        XCTAssertEqual(fixture.count("initialize"), 0)
        XCTAssertEqual(fixture.count("tools/call"), 0)
    }

    private func assertCompleted<T>(_ operation: LifecycleOperation<T>, file: StaticString = #filePath, line: UInt = #line) async {
        let finished = await operation.wait()
        XCTAssertTrue(finished, "Operation did not finish promptly", file: file, line: line)
    }
    private func assertSuccess(_ operation: LifecycleOperation<Data>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let data)? = operation.result else { return XCTFail("Expected successful fixture response: \(String(describing: operation.result))", file: file, line: line) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return XCTFail("Expected a JSON tool result", file: file, line: line)
        }
        XCTAssertEqual(object["content"] as? [[String: String]], [["type": "text", "text": "fixture-result"]], file: file, line: line)
        XCTAssertEqual(object["isError"] as? Bool, false, file: file, line: line)
    }
    private func assertCancelled<T>(_ operation: LifecycleOperation<T>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error)? = operation.result else { return XCTFail("Expected cancellation", file: file, line: line) }
        XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)", file: file, line: line)
    }
    private func assertFailure<T>(_ operation: LifecycleOperation<T>, _ expected: MCPServiceError,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error as MCPServiceError)? = operation.result else { return XCTFail("Expected \(expected), got \(String(describing: operation.result))", file: file, line: line) }
        switch (error, expected) {
        case (.revoked, .revoked), (.timedOut, .timedOut): break
        default: XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
