import Foundation
import Testing

@testable import DatabaseManagerPlugin

@Suite("LogRedactor")
struct LogRedactorTests {
    @Test func emptyMessageIsUnchanged() {
        #expect(LogRedactor.redact("") == "")
    }

    @Test func plainTextIsPreserved() {
        #expect(LogRedactor.redact("SELECT 1") == "SELECT 1")
        #expect(LogRedactor.redact("connected to localhost:3306") == "connected to localhost:3306")
        #expect(LogRedactor.redact("查询成功，返回 3 行") == "查询成功，返回 3 行")
    }

    @Test func proseMentioningPasswordWithoutValueIsPreserved() {
        #expect(LogRedactor.redact("the password is required") == "the password is required")
        #expect(LogRedactor.redact("passwords are hashed") == "passwords are hashed")
        #expect(LogRedactor.redact("author=alice") == "author=alice")
    }

    @Test func keyValuePasswordIsRedacted() {
        #expect(LogRedactor.redact("password=hunter2") == "password=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("password: hunter2") == "password: \(LogRedactor.marker)")
        #expect(LogRedactor.redact("pwd=short") == "pwd=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("passwd=abc") == "passwd=\(LogRedactor.marker)")
    }

    @Test func keyValueIsCaseInsensitiveAndPreservesKeyCase() {
        #expect(LogRedactor.redact("PASSWORD=hunter2") == "PASSWORD=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("Password: hunter2") == "Password: \(LogRedactor.marker)")
    }

    @Test func sensitiveKeyVariantsAreRedacted() {
        #expect(LogRedactor.redact("api_key=abc123") == "api_key=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("apikey=abc123") == "apikey=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("token: xyz") == "token: \(LogRedactor.marker)")
        #expect(LogRedactor.redact("access_token=t") == "access_token=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("secret=s") == "secret=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("ssh_password=p@ss") == "ssh_password=\(LogRedactor.marker)")
        #expect(LogRedactor.redact("authorization=Basic xyz") == "authorization=\(LogRedactor.marker)")
    }

    @Test func valueStopsAtStructuralDelimiters() {
        #expect(LogRedactor.redact("user=root password=hunter2 host=localhost")
                == "user=root password=\(LogRedactor.marker) host=localhost")
        #expect(LogRedactor.redact("password=hunter2;next=1")
                == "password=\(LogRedactor.marker);next=1")
        #expect(LogRedactor.redact("password=hunter2,next=1")
                == "password=\(LogRedactor.marker),next=1")
    }

    @Test func urlUserInfoPasswordIsRedacted() {
        #expect(LogRedactor.redact("mysql://root:hunter2@localhost:3306/db")
                == "mysql://root:\(LogRedactor.marker)@localhost:3306/db")
        #expect(LogRedactor.redact("postgres://user:pass@host/db")
                == "postgres://user:\(LogRedactor.marker)@host/db")
        #expect(LogRedactor.redact("redis://:secret@127.0.0.1:6379")
                == "redis://:\(LogRedactor.marker)@127.0.0.1:6379")
    }

    @Test func urlWithoutPasswordIsPreserved() {
        #expect(LogRedactor.redact("mysql://root@localhost/db") == "mysql://root@localhost/db")
        #expect(LogRedactor.redact("https://example.com/path") == "https://example.com/path")
    }

    @Test func jsonPasswordFieldIsRedacted() {
        #expect(LogRedactor.redact(#"{"password":"hunter2"}"#)
                == #"{"password":"\#(LogRedactor.marker)"}"#)
        #expect(LogRedactor.redact(#"{"password": "hunter2"}"#)
                == #"{"password": "\#(LogRedactor.marker)"}"#)
        #expect(LogRedactor.redact(#"{"user":"root","password":"hunter2"}"#)
                == #"{"user":"root","password":"\#(LogRedactor.marker)"}"#)
    }

    @Test func jsonValueWithEscapedQuoteIsRedacted() {
        #expect(LogRedactor.redact(#"{"password":"a\"b"}"#)
                == #"{"password":"\#(LogRedactor.marker)"}"#)
    }

    @Test func bearerTokenIsRedacted() {
        #expect(LogRedactor.redact("Bearer abc.def.ghi") == "Bearer \(LogRedactor.marker)")
        #expect(LogRedactor.redact("bearer abc123==") == "bearer \(LogRedactor.marker)")
    }

    @Test func authorizationHeaderIsRedacted() {
        #expect(LogRedactor.redact("Authorization: Basic dXNlcjpwYXNz")
                == "Authorization: \(LogRedactor.marker)")
    }

    @Test func sqlIdentifiedByIsRedacted() {
        #expect(LogRedactor.redact("CREATE USER x IDENTIFIED BY 'hunter2'")
                == "CREATE USER x IDENTIFIED BY '\(LogRedactor.marker)'")
        #expect(LogRedactor.redact("identified by 'p@ss'")
                == "identified by '\(LogRedactor.marker)'")
    }

    @Test func multipleSecretsInOneMessageAreAllRedacted() {
        let input = "connect mysql://root:hunter2@db password=hunter2 token=abc"
        let output = LogRedactor.redact(input)
        #expect(!output.contains("hunter2"))
        #expect(!output.contains("abc"))
        #expect(output.contains("mysql://root:\(LogRedactor.marker)@db"))
    }

    @Test func redactionIsIdempotent() {
        let once = LogRedactor.redact("password=hunter2")
        #expect(LogRedactor.redact(once) == once)
    }
}