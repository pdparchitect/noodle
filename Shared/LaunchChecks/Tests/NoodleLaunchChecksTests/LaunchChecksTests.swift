import Testing
@testable import NoodleLaunchChecks

@Suite struct LaunchChecksTests {
    @Test func digestMatchesShasum() {
        // printf %s 'abc' | shasum -a 256
        #expect(LaunchChecks.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func recognisesAnArgumentByDigest() {
        let checks = LaunchChecks(arguments: ["/path/App", "--example-check"])
        #expect(checks.contains(LaunchChecks.digest("--example-check")))
        #expect(!checks.contains(LaunchChecks.digest("--other-check")))
    }

    @Test func ignoresAnArgumentThatOnlySharesAPrefix() {
        let checks = LaunchChecks(arguments: ["/path/App", "--example-check-extra"])
        #expect(!checks.contains(LaunchChecks.digest("--example-check")))
    }

    @Test func returnsTheValueThatFollows() {
        let port = LaunchChecks.digest("--port"), name = LaunchChecks.digest("--name")
        let checks = LaunchChecks(arguments: ["/path/App", "--port", "8080", "--name"])
        #expect(checks.value(after: port) == "8080")
        #expect(checks.value(after: name) == nil)
        #expect(checks.value(after: LaunchChecks.digest("--absent")) == nil)
    }
}
