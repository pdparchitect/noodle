@testable import MailEngine
import NIOCore // reached through SwiftMail; the test target does not declare it
import SwiftMail
import XCTest

/// Stand-ins for errors no mapping knows: one that words itself, one that does not.
private struct Friendly: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private struct Plain: Error {
    let detail: String
}

final class MailEngineErrorTests: XCTestCase {
    /// A refused sign-in reads as a sign-in problem on that server, for IMAP and SMTP alike.
    func testSignInFailuresMap() {
        XCTAssertEqual(MailEngineError.from(IMAPError.loginFailed("[AUTHENTICATIONFAILED] Invalid"), host: "imap.x", password: "p"),
                       .authenticationFailed(host: "imap.x"))
        XCTAssertEqual(MailEngineError.from(SMTPError.authenticationFailed("PLAIN: 535"), host: "smtp.x", password: "p"),
                       .authenticationFailed(host: "smtp.x"))
    }

    /// Timeouts, failed encryption and missing folders each get their own plain meaning.
    func testOtherFailuresMap() {
        XCTAssertEqual(MailEngineError.from(IMAPError.timeout, host: "h", password: "p"), .timedOut(host: "h"))
        XCTAssertEqual(MailEngineError.from(SMTPError.tlsFailed("handshake"), host: "h", password: "p"), .secureConnectionFailed(host: "h"))
        XCTAssertEqual(MailEngineError.from(IMAPError.connectionFailed("closed"), host: "h", password: "p"), .cannotConnect(host: "h"))
        XCTAssertEqual(MailEngineError.from(UndefinedFolderError.drafts, host: "h", password: "p"), .folderNotFound(role: "Drafts"))
    }

    /// An engine error passes through unchanged.
    func testEngineErrorsPassThrough() {
        XCTAssertEqual(MailEngineError.from(MailEngineError.noRecipients, host: "h", password: "p"), .noRecipients)
    }

    /// Even if a server echoes the password back, it never reaches the message a bot or log sees.
    func testPasswordNeverAppears() {
        let error = MailEngineError.from(IMAPError.commandFailed("bad input hunter2 here"), host: "h", password: "hunter2")
        XCTAssertEqual(error, .serverRejected("bad input ••• here"))
        XCTAssertFalse((error.errorDescription ?? "").contains("hunter2"))
    }

    /// A server that echoes the LOGIN arguments back gives the password as an IMAP quoted string, with `"` and `\` escaped; that form never reaches a bot either.
    func testTheQuotedPasswordNeverAppears() {
        let password = #"pa"ss\word"#
        let error = MailEngineError.from(IMAPError.commandFailed(#"BAD LOGIN "borek" "pa\"ss\\word" rejected"#), host: "h", password: password)
        XCTAssertEqual(error, .serverRejected(#"BAD LOGIN "borek" "•••" rejected"#))
        XCTAssertFalse((error.errorDescription ?? "").contains("ss"))
    }

    /// Only the errors that say "that thing is not there" leave a session usable; every connection, sign-in, TLS, timeout, server and send error does not.
    func testOnlyNotFoundErrorsLeaveTheSessionUsable() {
        let usable: [MailEngineError] = [.folderNotFound(role: "Sent"), .messageNotFound(uid: 9), .partNotFound(uid: 9, part: "1.2")]
        let unusable: [MailEngineError] = [
            .insecureServer(host: "h"), .invalidAddress("x"), .noRecipients, .authenticationFailed(host: "h"), .cannotConnect(host: "h"),
            .secureConnectionFailed(host: "h"), .timedOut(host: "h"), .serverRejected("no"), .sendOutcomeUnknown(host: "h"), .recipientRejected("ada@example.com"),
        ]
        for error in usable { XCTAssertTrue(error.leavesSessionUsable, "\(error)") }
        for error in unusable { XCTAssertFalse(error.leavesSessionUsable, "\(error)") }
    }

    /// Every case explains itself in a sentence.
    func testDescriptionsAreSentences() {
        XCTAssertEqual(MailEngineError.authenticationFailed(host: "imap.seznam.cz").errorDescription,
                       "imap.seznam.cz refused the sign-in. Check the username and password (an app password if two-factor login is on).")
        XCTAssertEqual(MailEngineError.folderNotFound(role: "Sent").errorDescription,
                       "This mailbox has no folder marked as Sent. Set the Sent folder in the mailbox settings.")
    }

    /// SwiftMail checks addresses more strictly at send time than we do when composing, so its refusal reads as an address problem, not a server refusal.
    func testSendTimeAddressRefusalsMapToInvalidAddress() {
        XCTAssertEqual(MailEngineError.from(SMTPError.invalidEmailAddress("Invalid recipient address: ada@localhost"), host: "smtp.x", password: "hunter2"),
                       .invalidAddress("ada@localhost"))
        XCTAssertEqual(MailEngineError.from(SMTPError.invalidEmailAddress("Invalid recipient address: hunter2@localhost"), host: "smtp.x", password: "hunter2"),
                       .invalidAddress("•••@localhost"))
    }

    /// Only the address is carried out of SwiftMail's sentence, trimmed; any other shape is kept whole, and the password is blanked before anything is cut.
    func testAddressRefusalsCarryOnlyTheAddress() {
        func mapped(_ reason: String, password: String = "hunter2") -> MailEngineError {
            MailEngineError.from(SMTPError.invalidEmailAddress(reason), host: "smtp.x", password: password)
        }
        XCTAssertEqual(mapped("Invalid sender address: borek@mail.example.org"), .invalidAddress("borek@mail.example.org"))
        XCTAssertEqual(mapped("Invalid recipient address:   ada@localhost \n"), .invalidAddress("ada@localhost"))
        XCTAssertEqual(mapped("ada@localhost"), .invalidAddress("ada@localhost"))
        XCTAssertEqual(mapped("Invalid recipient address: "), .invalidAddress("Invalid recipient address: "))
        XCTAssertEqual(mapped("Invalid recipient address: a: b@localhost", password: "a: b"), .invalidAddress("•••@localhost"))
    }

    /// When SwiftMail cannot tell whether the server took the mail, the message says it may have been sent, never that the server refused, and it drops the server's text.
    func testUnknownSendOutcomeSaysTheMailMayHaveBeenSent() {
        let outcomes: [SMTPSendError] = [
            SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .connectionLost),
            SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .timedOut, timeoutStage: .contentResponse),
            SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .transport("broken pipe, password hunter2")),
            // SwiftMail never names a recipient on an unknown outcome, but if it did, the warning about a second send would still come first.
            SMTPSendError(phase: .rcptTo, acceptance: .ambiguous, reason: .connectionLost, rejectedRecipient: EmailAddress(address: "ada@example.com")),
        ]
        for outcome in outcomes {
            XCTAssertEqual(MailEngineError.from(outcome, host: "smtp.x", password: "hunter2"), .sendOutcomeUnknown(host: "smtp.x"), "\(outcome.reason)")
        }
    }

    /// A refused recipient is named by its address so the person knows which one to fix, and that address never carries the password.
    func testRefusedRecipientIsNamed() {
        let reply = SMTPResponse(code: 550, message: "5.1.1 User unknown")
        let refused = SMTPSendError(phase: .rcptTo, acceptance: .notAccepted, reason: .reply(reply), rejectedRecipient: EmailAddress(address: "ada@example.com"))
        let odd = SMTPSendError(phase: .rcptTo, acceptance: .notAccepted, reason: .reply(reply), rejectedRecipient: EmailAddress(address: "hunter2@example.com"))
        XCTAssertEqual(MailEngineError.from(refused, host: "smtp.x", password: "hunter2"), .recipientRejected("ada@example.com"))
        XCTAssertEqual(MailEngineError.from(odd, host: "smtp.x", password: "hunter2"), .recipientRejected("•••@example.com"))
    }

    /// Any other failure once sending has started stays a server refusal carrying SwiftMail's own account of it, with the password blanked out.
    func testOtherSendFailuresStayServerRefusals() {
        let senderRefused = SMTPSendError(phase: .mailFrom, acceptance: .notAccepted, reason: .reply(SMTPResponse(code: 550, message: "5.7.1 Sender rejected")))
        let tooBig = SMTPSendError(phase: .content, acceptance: .rejectedPermanently, reason: .reply(SMTPResponse(code: 552, message: "5.3.4 Message too large")))
        let recipientNotNamed = SMTPSendError(phase: .rcptTo, acceptance: .notAccepted, reason: .reply(SMTPResponse(code: 550, message: "5.1.1 User unknown")))
        for failure in [senderRefused, tooBig, recipientNotNamed] {
            XCTAssertEqual(MailEngineError.from(failure, host: "smtp.x", password: "hunter2"), .serverRejected(failure.description))
        }
        let greylisted = SMTPSendError(phase: .content, acceptance: .rejectedTransiently, reason: .reply(SMTPResponse(code: 451, message: "4.7.1 Try again, hunter2")))
        guard case .serverRejected(let text) = MailEngineError.from(greylisted, host: "smtp.x", password: "hunter2") else { return XCTFail("not a server refusal") }
        XCTAssertTrue(text.contains("451 4.7.1 Try again, •••"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    /// The two send-failure messages say what to check or fix next.
    func testSendFailureDescriptionsTellThePersonWhatToDo() {
        XCTAssertEqual(MailEngineError.sendOutcomeUnknown(host: "smtp.seznam.cz").errorDescription,
                       "smtp.seznam.cz stopped answering after the mail was handed over, so it may have been sent. Do not send it again until the recipient or the person in charge confirms it did not arrive.")
        XCTAssertEqual(MailEngineError.recipientRejected("ada@example.com").errorDescription,
                       "The server refused the recipient ada@example.com.")
    }

    /// Every mapping that passes server or library text on blanks the password out of it, including send failures, which SwiftMail throws as SMTPSendError.
    func testPasswordIsBlankedOnEveryPathThatCarriesText() {
        let errors: [Error] = [
            IMAPError.commandFailed("hunter2"),
            IMAPError.fetchFailed("hunter2"),
            IMAPError.selectFailed("hunter2"),
            IMAPError.storeFailed("hunter2"),
            IMAPError.invalidArgument("hunter2"),
            SMTPError.sendFailed("hunter2"),
            SMTPError.commandFailed("hunter2"),
            SMTPError.invalidEmailAddress("hunter2"),
            SMTPError.unexpectedResponse(SMTPResponse(code: 500, message: "hunter2")),
            SMTPSendError(phase: .rcptTo, acceptance: .notAccepted, reason: .reply(SMTPResponse(code: 550, message: "no such user hunter2"))),
            SMTPSendError(phase: .content, acceptance: .notAccepted, reason: .transport("hunter2")),
            Friendly(text: "friendly hunter2"),
            Plain(detail: "hunter2"),
        ]
        for error in errors {
            let mapped = MailEngineError.from(error, host: "h", password: "hunter2")
            XCTAssertFalse(String(describing: mapped).contains("hunter2"), "password in the error value for \(error)")
            XCTAssertFalse((mapped.errorDescription ?? "").contains("hunter2"), "password in the description for \(error)")
            XCTAssertTrue((mapped.errorDescription ?? "").contains("•••"), "the text was dropped instead of blanked for \(error)")
        }
    }

    /// An error nobody mapped keeps its own wording: a LocalizedError's description, or else the error written out.
    func testUnrecognisedErrorsKeepTheirOwnWording() {
        XCTAssertEqual(MailEngineError.from(Friendly(text: "No mailbox of that name"), host: "h", password: "hunter2"),
                       .serverRejected("No mailbox of that name"))
        XCTAssertEqual(MailEngineError.from(Plain(detail: "no such box"), host: "h", password: "hunter2"),
                       .serverRejected("Plain(detail: \"no such box\")"))
    }

    /// The other sign-in, greeting and timeout failures SwiftMail reports land on the same plain meanings, using the texts SwiftMail really sends.
    func testRemainingLibraryFailuresMap() {
        XCTAssertEqual(MailEngineError.from(IMAPError.authFailed("NO"), host: "h", password: "p"), .authenticationFailed(host: "h"))
        XCTAssertEqual(MailEngineError.from(IMAPError.greetingFailed("BYE"), host: "h", password: "p"), .cannotConnect(host: "h"))
        XCTAssertEqual(MailEngineError.from(SMTPError.connectionFailed("Response timeout"), host: "h", password: "p"), .timedOut(host: "h"))
        XCTAssertEqual(MailEngineError.from(SMTPError.connectionFailed("Not connected to SMTP server"), host: "h", password: "p"), .cannotConnect(host: "h"))
    }

    /// A sign-in refusal never carries the server's text, so an echoed password cannot ride along.
    func testSignInRefusalsDropTheServersText() {
        XCTAssertEqual(MailEngineError.from(IMAPError.loginFailed("NO login hunter2 rejected"), host: "h", password: "hunter2"),
                       .authenticationFailed(host: "h"))
        XCTAssertEqual(MailEngineError.from(SMTPError.authenticationFailed("535 hunter2 rejected"), host: "h", password: "hunter2"),
                       .authenticationFailed(host: "h"))
    }

    /// Each missing special folder is named by its role in the sentence the person reads.
    func testEveryMissingFolderNamesItsRole() {
        let roles: [(UndefinedFolderError, String)] = [
            (.inbox, "Inbox"), (.trash, "Trash"), (.archive, "Archive"), (.sent, "Sent"), (.drafts, "Drafts"), (.junk, "Junk"),
        ]
        for (folder, role) in roles {
            XCTAssertEqual(MailEngineError.from(folder, host: "h", password: "p"), .folderNotFound(role: role))
        }
    }

    /// Errors from the network stack are told apart by type name because the engine does not link NIO, so these stand-ins carry NIO's own type names.
    func testNetworkStackErrorsAreRecognisedByTypeName() {
        struct NIOSSLError: Error {}
        struct NIOConnectionError: Error {}
        struct IOError: Error {}
        XCTAssertEqual(MailEngineError.from(NIOSSLError(), host: "h", password: "p"), .secureConnectionFailed(host: "h"))
        XCTAssertEqual(MailEngineError.from(NIOConnectionError(), host: "h", password: "p"), .cannotConnect(host: "h"))
        XCTAssertEqual(MailEngineError.from(IOError(), host: "h", password: "p"), .cannotConnect(host: "h"))
    }

    /// A connect that got no answer within NIO's limit reads as a timeout, checked on NIO's real error value, whose own text is "Connect timeout (10 s)".
    func testConnectTimeoutIsATimeout() {
        XCTAssertEqual(MailEngineError.from(ChannelError.connectTimeout(.seconds(10)), host: "h", password: "p"), .timedOut(host: "h"))
    }

    /// Only NIO's channel errors that mean the connection dropped read as a failed connection, while its other channel errors keep their own words, checked on NIO's real error values.
    func testOnlyDroppedConnectionsAreFailedConnections() {
        let dropped: [ChannelError] = [.eof, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed]
        for error in dropped {
            XCTAssertEqual(MailEngineError.from(error, host: "h", password: "hunter2"), .cannotConnect(host: "h"), "\(error)")
        }
        let others: [ChannelError] = [.connectPending, .operationUnsupported, .writeMessageTooLarge, .writeHostUnreachable, .unknownLocalAddress,
                                      .badMulticastGroupAddressFamily, .badInterfaceAddressFamily, .inappropriateOperationForState, .unremovableHandler]
        for error in others {
            XCTAssertEqual(MailEngineError.from(error, host: "h", password: "hunter2"), .serverRejected(error.description), "\(error)")
        }
    }
}
