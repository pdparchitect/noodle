import Foundation

/// Fields a bot should neither read nor fill: card details, secrets, codes and identity numbers.
/// Pages give Accessibility no autofill hints and only passwords are marked as secure, so this goes by
/// what the person would read: the label, the field's ID, and a value that is a card number.
public enum ContextFieldSensitivity {
    /// Matched within the label or ID with spaces and punctuation removed.
    static let phrases = ["cardnumber", "ccnumber", "ccnum", "creditcard", "debitcard", "cardno", "ccexp", "cardexp", "expiry",
                          "expirationdate", "securitycode", "cardverification", "cardcode", "onetimecode", "onetimepassword",
                          "verificationcode", "authcode", "password", "passcode", "passwd", "accountnumber", "routingnumber",
                          "sortcode", "socialsecurity", "nationalinsurance", "nationalid", "taxid", "passport"]
    /// Matched as whole words only: "pin" is sensitive, "shipping" and "Pinterest" are not.
    static let words: Set<String> = ["cvv", "cvv2", "cvc", "cvc2", "csc", "cvn", "pin", "otp", "totp", "2fa", "mfa", "ssn", "iban"]

    public static func isSensitive(label: String?, identifier: String?, value: String?) -> Bool {
        let tokens = [label, identifier].compactMap { $0 }.flatMap(Self.tokens)
        let compact = tokens.joined()
        return tokens.contains(where: words.contains) || phrases.contains(where: compact.contains) || isCardNumber(value)
    }

    /// Words of a label or of an ID such as `cardNumber` or `cc-csc`, in lower case.
    static func tokens(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for character in text {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty { words.append(current); current = "" }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// 13 to 19 digits, spaced or dashed as cards are written, that pass the Luhn check every card number does.
    static func isCardNumber(_ value: String?) -> Bool {
        guard let value else { return false }
        let stripped = value.filter { $0 != " " && $0 != "-" }
        guard (13...19).contains(stripped.count), stripped.allSatisfy(\.isASCII), stripped.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (index, digit) in stripped.reversed().compactMap(\.wholeNumberValue).enumerated() {
            let doubled = index.isMultiple(of: 2) ? digit : digit * 2
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum.isMultiple(of: 10)
    }
}
