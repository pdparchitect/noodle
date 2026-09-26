import Foundation
@testable import NoodleMobile
import Testing
import UIKit
import UniformTypeIdentifiers

/// An invitation copied as a link, as Safari and Messages copy one, pastes as well as one copied as text.
@MainActor struct PasteLinkTests {
    @Test func linksAndTextBothPaste() async throws {
        let link = "noodle://join-hub?invitation=abc"
        for provider in [NSItemProvider(object: URL(string: link)! as NSURL), NSItemProvider(object: link as NSString)] {
            var pasted: String?
            let receiver = PasteLinkButton.Receiver { pasted = $0 }
            let accepted = try #require(receiver.pasteConfiguration?.acceptableTypeIdentifiers)
            #expect(provider.registeredTypeIdentifiers.contains { type in accepted.contains { UTType(type)?.conforms(to: UTType($0)!) == true } },
                    "the paste button would stay off for \(provider.registeredTypeIdentifiers)")
            receiver.paste(itemProviders: [provider])
            for _ in 0..<50 where pasted == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(pasted == link)
        }
    }
}
