import XCTest
@testable import NoodleContextFieldsTools

final class ContextFieldSensitivityTests: XCTestCase {
    /// Pages give Accessibility no autofill hints, so a field's label, ID and value are all there is to judge by.
    func testCardSecretAndIdentityFieldsAreRecognisedByLabelOrID() {
        let sensitive: [(label: String?, id: String?)] = [
            ("Card number", nil), (nil, "cardNumber"), (nil, "cc-number"), ("Credit card", nil), (nil, "ccnum"),
            ("CVV", nil), ("CVC", nil), (nil, "cc-csc"), ("Security code", nil), ("Expiry date", nil), (nil, "cc-exp"),
            ("PIN", nil), ("One-time code", nil), (nil, "otp"), ("Verification code", nil), ("2FA code", nil),
            ("Password", nil), ("IBAN", nil), ("Account number", nil), ("Sort code", nil), ("Routing number", nil),
            ("Social security number", nil), ("SSN", nil), ("National Insurance number", nil), ("Passport number", nil),
        ]
        for (label, id) in sensitive {
            XCTAssertTrue(ContextFieldSensitivity.isSensitive(label: label, identifier: id, value: ""), "\(label ?? id ?? "")")
        }
        let ordinary: [(label: String?, id: String?)] = [
            ("Full name", "name"), ("Email", "email"), ("Shipping address", "shipping"), ("Your opinion", nil),
            ("Pinterest profile", nil), ("Company", "company"), ("Delivery notes", "notes"), ("Phone number", "phone"),
            ("Order number", nil), ("Caribbean island", nil), (nil, nil),
        ]
        for (label, id) in ordinary {
            XCTAssertFalse(ContextFieldSensitivity.isSensitive(label: label, identifier: id, value: "x"), "\(label ?? id ?? "nil")")
        }
    }

    /// A card number is caught by its checksum on a form that labels nothing.
    func testACardNumberIsRecognisedByItsValue() {
        for card in ["4111111111111111", "4111 1111 1111 1111", "5555-5555-5555-4444", "378282246310005"] {
            XCTAssertTrue(ContextFieldSensitivity.isSensitive(label: nil, identifier: nil, value: card), card)
        }
        for other in ["4111111111111112", "+44 20 7946 0000", "12345", "Leave at door.", "2026-12-24"] {
            XCTAssertFalse(ContextFieldSensitivity.isSensitive(label: nil, identifier: nil, value: other), other)
        }
    }
}
