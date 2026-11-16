import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// Redis TLS 辅助：PEM 证书提取逻辑（纯函数，无需真实引擎）。
struct RedisTLSSupportTests {
    private func writeTempPEM(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "lode-tls-\(UUID().uuidString).pem"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("提取单个证书的 DER")
    func singleCert() throws {
        let path = try writeTempPEM("""
        -----BEGIN CERTIFICATE-----
        aGVsbG8=
        -----END CERTIFICATE-----
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ders = RedisTLSSupport.derCertificates(pemPath: path)
        #expect(ders == [Data("hello".utf8)])
    }

    @Test("提取证书链（多个块）")
    func chain() throws {
        let path = try writeTempPEM("""
        -----BEGIN CERTIFICATE-----
        YWJj
        -----END CERTIFICATE-----
        -----BEGIN CERTIFICATE-----
        ZGVm
        -----END CERTIFICATE-----
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ders = RedisTLSSupport.derCertificates(pemPath: path)
        #expect(ders == [Data("abc".utf8), Data("def".utf8)])
    }

    @Test("多行 base64 忽略空白")
    func multilineBase64() throws {
        let path = try writeTempPEM("""
        -----BEGIN CERTIFICATE-----
        aGVs
        bG8=
        -----END CERTIFICATE-----
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(RedisTLSSupport.derCertificates(pemPath: path) == [Data("hello".utf8)])
    }

    @Test("nil 或缺失文件返回空数组")
    func missingFile() {
        #expect(RedisTLSSupport.derCertificates(pemPath: nil).isEmpty)
        #expect(RedisTLSSupport.derCertificates(pemPath: "/nonexistent/ca.pem").isEmpty)
    }
}