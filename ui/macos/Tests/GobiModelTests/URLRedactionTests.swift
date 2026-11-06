import Testing
@testable import GobiModel

struct URLRedactionTests {
    @Test func aTokenInTheUserInfoIsRemoved() {
        #expect(URLRedaction.redact("https://user:token@host.example/x.git") == "https://user@host.example/x.git")
        #expect(URLRedaction.redact("https://token@host.example/x.git") == "https://token@host.example/x.git")
    }

    @Test func scpStyleAndPlainAddressesAreUnchanged() {
        for text in ["git@host.example:team/x.git", "https://host.example/x.git", "/local/path", "", "ssh://git@host.example/x"] {
            #expect(URLRedaction.redact(text) == text)
        }
    }

    @Test func everyUrlInAMessageIsRedacted() {
        let message = "fatal: unable to access 'https://bob:s3cret@host.example/r.git/': 403; also http://a:b@h2.example:8080/p"
        #expect(URLRedaction.redact(message) == "fatal: unable to access 'https://bob@host.example/r.git/': 403; also http://a@h2.example:8080/p")
    }

    @Test func anAtSignInThePathIsNotUserInfo() {
        #expect(URLRedaction.redact("https://host.example/a:b@c") == "https://host.example/a:b@c")
    }
}
