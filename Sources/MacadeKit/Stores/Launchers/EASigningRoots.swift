import CryptoKit
import Foundation

/// Two VeriSign roots that EA's game installers are signed under, added to the EA environment's trusted roots.
///
/// Before the last install step the EA app checks the signature on the game's `__Installer\Touchup.exe` and refuses
/// to run it on an "incomplete code-signing certificate chain" ("The final stages of installation didn't go as
/// planned"). Wine trusts the roots macOS trusts, and Apple removed every VeriSign and Symantec root; Windows still
/// trusts these two for code signing. Seen 2026-10-30 with STAR WARS Jedi: Fallen Order, signed by Electronic Arts
/// through Symantec Class 3 SHA256 Code Signing CA (root: G5) and timestamped through Symantec SHA256 TimeStamping
/// CA (root: Universal).
///
/// The certificates are Microsoft's copies (`ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/<SHA-1>.crt`),
/// checked by fingerprint and by verifying that each signs the CA certificate in that signature. Only the EA
/// environment gets them, never the Mac's keychain, and each is limited to code signing and timestamping (the
/// Windows `CERT_ENHKEY_USAGE_PROP_ID` property), so they can't vouch for a website either.
public enum EASigningRoots {
    struct Root {
        let name: String
        let sha1: String      // the registry key name: Windows files roots by SHA-1
        let sha256: String
        let base64: String
        var der: Data { Data(base64Encoded: base64)! }
    }

    static let roots = [
        Root(name: "VeriSign Class 3 Public Primary Certification Authority - G5",
             sha1: "4EB6D578499B1CCF5F581EAD56BE3D9B6744A5E5",
             sha256: "9acfab7e43c8d880d06b262a94deeee4b4659989c3d0caf19baf6405e41ab7df",
             base64: """
             MIIE0zCCA7ugAwIBAgIQGNrRniZ96LtKIVjNzGs7SjANBgkqhkiG9w0BAQUFADCByjELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJ\
             bmMuMR8wHQYDVQQLExZWZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTowOAYDVQQLEzEoYykgMjAwNiBWZXJpU2lnbiwgSW5jLiAtIEZvciBhdXRob3Jp\
             emVkIHVzZSBvbmx5MUUwQwYDVQQDEzxWZXJpU2lnbiBDbGFzcyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IC0gRzUw\
             HhcNMDYxMTA4MDAwMDAwWhcNMzYwNzE2MjM1OTU5WjCByjELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJbmMuMR8wHQYDVQQLExZW\
             ZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTowOAYDVQQLEzEoYykgMjAwNiBWZXJpU2lnbiwgSW5jLiAtIEZvciBhdXRob3JpemVkIHVzZSBvbmx5MUUw\
             QwYDVQQDEzxWZXJpU2lnbiBDbGFzcyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IC0gRzUwggEiMA0GCSqGSIb3DQEB\
             AQUAA4IBDwAwggEKAoIBAQCvJAgIKXo1nmAMqudLO07cfLw8RRy7K+D+KQL5VwijZIUVJ/XxrcgxiV0i6CqqpkKzj/i5Vbext0uz/o9+B1fs70Pb\
             ZmIVYc9gDaTY3vjgw2IIPVQT60nKWVSFJuUrjxuf6/WhkcIzSdhDY2pSS9KP6HBRTdGJaXvHcPaz3BJ023tdS1bTlr8Vd6Gw9KIl8q8ckmcY5fQG\
             BO+QueQA5N06tRn/Arr0PO7gi+s3i+z016zy9vA9r911kTMZHRxAy3QkGSGT2RT+rCpSx4/VBEnkjWNHiDxpg8v+R70rfk/Fla4OndTRQ8Bnc+MU\
             CH7lP59zuDMKz10/NIeWiu5T6CUVAgMBAAGjgbIwga8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwbQYIKwYBBQUHAQwEYTBfoV2g\
             WzBZMFcwVRYJaW1hZ2UvZ2lmMCEwHzAHBgUrDgMCGgQUj+XTGoasjY5rw8+AatRIGCx7GS4wJRYjaHR0cDovL2xvZ28udmVyaXNpZ24uY29tL3Zz\
             bG9nby5naWYwHQYDVR0OBBYEFH/TZafC3ey78DAJ80M5+gKvMzEzMA0GCSqGSIb3DQEBBQUAA4IBAQCTJEowX2LP2BqYLz3q3JktvXf2pXkiOOzE\
             p6B4Eq1iDkVwZMXnl2YtmAl+X6/WzChl8gGqCBpH3vn5fJJaCGkgDdk+bW48DW7Y5gaRQBi5+MHt39tBquCWIMnNZBU4gcmU7qKEKQsTb47bDN0l\
             AtukixlE0kF6BWlKWE9gyn6CagsCqiUXObXbf+eEZSqVir2G3l6BFoMtEMze/aiCKm0oHw0LxOXnGiYZ4fQRbxC1lfznQgUy286dUV4otp6F01vv\
             pX1FQHKOtw5rDgb7MzVIcbidJ4vEZV8NhnacRHr2lVz2XTIIM6RUthg/aFzyQkqFOFSDX9HoLPKsEdao7WNq
             """),
        Root(name: "VeriSign Universal Root Certification Authority",
             sha1: "3679CA35668772304D30A5FB873B0FA77BB70D54",
             sha256: "2399561127a57125de8cefea610ddf2fa078b5c8067f4e828290bfb860e84b3c",
             base64: """
             MIIEuTCCA6GgAwIBAgIQQBrEZCGzEyEDDrvkEhrFHTANBgkqhkiG9w0BAQsFADCBvTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJ\
             bmMuMR8wHQYDVQQLExZWZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTowOAYDVQQLEzEoYykgMjAwOCBWZXJpU2lnbiwgSW5jLiAtIEZvciBhdXRob3Jp\
             emVkIHVzZSBvbmx5MTgwNgYDVQQDEy9WZXJpU2lnbiBVbml2ZXJzYWwgUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTAeFw0wODA0MDIwMDAw\
             MDBaFw0zNzEyMDEyMzU5NTlaMIG9MQswCQYDVQQGEwJVUzEXMBUGA1UEChMOVmVyaVNpZ24sIEluYy4xHzAdBgNVBAsTFlZlcmlTaWduIFRydXN0\
             IE5ldHdvcmsxOjA4BgNVBAsTMShjKSAyMDA4IFZlcmlTaWduLCBJbmMuIC0gRm9yIGF1dGhvcml6ZWQgdXNlIG9ubHkxODA2BgNVBAMTL1ZlcmlT\
             aWduIFVuaXZlcnNhbCBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAx2E3XrEBNNti\
             1xWb/1hajCMj1mCOkdeQmIN65lgZOIzF9uVkhbSicfvtvbnazU0AtMgtc6XHaXGVHzk8skQHnOgO+k1KxCHfKWGPMiJhgsWHH26MfF8WIFFE0XBP\
             V+rjHOPMee5Y2A7Cs0WTwCznmhcrewA3ekEzeOEz4vMQGn+HLL729fdC4uW/h2KJXwBL38Xd5HVEMkE6HnFuacsLdUYI0crSK5XQz/u5QGtkjFdN\
             /BMReYTtXlT2NJ8IAfMQJQYXStrxHXpma5hgZqTZ79IugvHw7wnqRMkVauIDbjPTrJ9VAMf2CGqUuV/c4DPxhGD5WycRtPwW8rtWaoAljQIDAQAB\
             o4GyMIGvMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMG0GCCsGAQUFBwEMBGEwX6FdoFswWTBXMFUWCWltYWdlL2dpZjAhMB8wBwYF\
             Kw4DAhoEFI/l0xqGrI2Oa8PPgGrUSBgsexkuMCUWI2h0dHA6Ly9sb2dvLnZlcmlzaWduLmNvbS92c2xvZ28uZ2lmMB0GA1UdDgQWBBS2d/ppSEef\
             UxLVwuoHMnYH0ZcHGTANBgkqhkiG9w0BAQsFAAOCAQEASvj4sAPmLGd75JR3Y8xuTPl9Dg3cyLk1uXBPY/ok+myDjEedO2Pzmvl2MpWRsXe8rJq+\
             seQxIcaBlVZaDrHC1LGmWazxY8u4TB1ZkErvkBYoH1quEPuBUDgMbMzxPcP1Y+Oz4yHJJDnp/RVmRvQbEdBNc6N9Rvk97ahfYtTxP/jgdFcrGJ2B\
             tMQo2pSXpXDrrB2+BxHw1dvd5Yzw1TKwg+ZX4o+/vqGqvz0dtdQ46tewXDpPaj+PwGZsY6rp2aQW9IHRlRQOfc2VNNnSj3BzgXucfr2YYdhFh5iQ\
             xeuGMMY1v/D/w1WIg0vvBZIGcfK4mJO37M2CYfE45k+XmCpajQ==
             """),
    ]

    static func registryKey(_ root: Root) -> String {
        #"HKLM\Software\Microsoft\SystemCertificates\Root\Certificates\"# + root.sha1
    }

    /// The registry `Blob`: serialized certificate-store properties, each `{id, 1, length}` then the data. SHA-1
    /// (3), enhanced key usage (9: code signing, timestamping) and the certificate itself (32).
    static func blob(_ root: Root) -> Data {
        func property(_ id: UInt32, _ value: Data) -> Data {
            var header = Data()
            for v in [id, 1, UInt32(value.count)] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
            return header + value
        }
        let der = root.der
        let usage = Data([0x30, 0x14,
                          0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03,    // 1.3.6.1.5.5.7.3.3 code signing
                          0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x08])   // 1.3.6.1.5.5.7.3.8 timestamping
        return property(3, Data(Insecure.SHA1.hash(data: der))) + property(9, usage) + property(32, der)
    }

    /// The roots `system.reg` doesn't hold yet. A running wineserver may not have saved one it already has; adding
    /// it again changes nothing.
    static func missing(systemReg: String) -> [Root] {
        let text = systemReg.uppercased()
        return roots.filter { !text.contains(#"ROOT\\CERTIFICATES\\"# + $0.sha1 + "]") }
    }

    /// Adds the roots the EA environment doesn't have. Wine leaves roots it didn't import from macOS alone
    /// (`HKLM\Software\Wine\HostImportedCertificates` lists its own), so they stay. Programs started afterwards
    /// see them.
    public static func ensure(in bottle: Bottle, engine: Engine) async {
        let systemReg = (try? String(contentsOf: bottle.url.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        for root in missing(systemReg: systemReg) {
            let der = root.der
            guard SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == root.sha256 else { continue }
            _ = try? await ProcessRunner.run(engine.wine, ["reg", "add", registryKey(root), "/v", "Blob", "/t", "REG_BINARY",
                                                           "/d", blob(root).map { String(format: "%02x", $0) }.joined(), "/f"],
                                             environment: env)
        }
    }
}
