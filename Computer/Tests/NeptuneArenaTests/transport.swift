import Foundation

@main enum TransportTests {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            if !value() { fputs("FAIL: \(description)\n", stderr); exit(1) }
        }
        let message = NeptuneMessage(-22, [UInt64.max, 7], fences: [NeptuneFence(context: 3, ring: nil, value: 9), NeptuneFence(context: 4, ring: 2, value: UInt64.max)])
        let payload = Data([0, 255, 10, 0])
        let encoded = try NeptuneWire.encode(message, payload: payload)
        let decoded = try NeptuneWire.decode(encoded)
        check(decoded.0 == message && decoded.1 == payload, "The process boundary must preserve commands, errors, payloads and fence identities")
        for malformed in [Data(), Data(encoded.dropLast()), encoded + Data([0]), Data(repeating: 255, count: 8)] {
            do { _ = try NeptuneWire.decode(malformed); check(false, "Reject truncated, oversized and trailing data") } catch {}
        }
        print("Neptune transport checks passed")
    }
}
