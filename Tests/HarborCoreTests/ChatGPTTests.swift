import XCTest
import CryptoKit
import Security
@testable import HarborCore

final class ChatGPTTests: XCTestCase {
    let callback = URL(string: "http://127.0.0.1:12345/auth/callback")!
    func testPKCEAndNewRegistration() throws {
        let attempt = try ChatGPTAttempt(redirect: callback)
        let url = attempt.authorize(hostID: "urn:uuid:fictional")
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(fields["client_id"], "dynamic_agent_client")
        XCTAssertEqual(fields["agent_name_hint"], "HarborReply")
        XCTAssertEqual(fields["code_challenge"], ChatGPTOAuth.base64url(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))))
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertNotEqual(attempt.state, try ChatGPTAttempt(redirect: callback).state)
        let result = try attempt.exchangeFields(callback: URL(string: callback.absoluteString + "?state=\(attempt.state)&code=fake&client_id=oaiapp_fictional")!)
        XCTAssertEqual(result["client_id"], "oaiapp_fictional"); XCTAssertEqual(result["redirect_uri"], callback.absoluteString)
        XCTAssertEqual(String(decoding: ChatGPTOAuth.form(["test": "a+b &c"]), as: UTF8.self), "test=a%2Bb%20%26c")
    }
    func testCallbackBindingAndReauthorization() throws {
        let attempt = try ChatGPTAttempt(redirect: callback, clientID: "oaiapp_saved", subject: "fictional")
        let base = callback.absoluteString + "?state=\(attempt.state)&code=fake"
        XCTAssertEqual(try attempt.exchangeFields(callback: URL(string: base)!) ["client_id"], "oaiapp_saved")
        for invalid in [base + "&client_id=oaiapp_other", base + "&state=duplicate", base.replacingOccurrences(of: attempt.state, with: "wrong"), base.replacingOccurrences(of: "12345", with: "54321"), base.replacingOccurrences(of: "/auth/callback", with: "/callback")] {
            XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: invalid)!))
        }
        XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: base)!, now: Date().addingTimeInterval(601)))
        XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: base + "&error=access_denied")!))
        XCTAssertFalse(attempt.authorize(hostID: "urn:uuid:fictional").absoluteString.contains("agent_name_hint"))
        XCTAssertTrue(attempt.authorize(hostID: "urn:uuid:fictional", requestConsent: true).absoluteString.contains("prompt=consent"))
    }
    func testSignatureAndAllIdentityClaims() throws {
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func read() -> Data {
            cursor += 1; var length = Int(der[cursor]); cursor += 1
            if length >= 128 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(der[cursor]); cursor += 1 } }
            let data = der.subdata(in: cursor..<(cursor + length)); cursor += length; return data
        }
        // The external RSA representation is a sequence containing modulus and exponent.
        cursor = 1; let lengthCount = Int(der[cursor]) & 127; cursor += Int(der[cursor]) >= 128 ? 1 + lengthCount : 1
        let n = read(), e = read()
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "fictional", "kty": "RSA", "alg": "RS256", "n": ChatGPTOAuth.base64url(n), "e": ChatGPTOAuth.base64url(e)]]])
        let base: [String: Any] = ["iss": ChatGPTOAuth.issuer, "aud": "oaiapp_test", "sub": "fictional-user", "email": "reader@example.invalid", "nonce": "nonce", "iat": Date().timeIntervalSince1970, "exp": Date().timeIntervalSince1970 + 600]
        func token(_ claims: [String: Any], alg: String = "RS256") throws -> String {
            let header = ChatGPTOAuth.base64url(try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "fictional"]))
            let payload = header + "." + ChatGPTOAuth.base64url(try JSONSerialization.data(withJSONObject: claims))
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(payload.utf8) as CFData, nil)) as Data
            return payload + "." + ChatGPTOAuth.base64url(signature)
        }
        let good = try token(base)
        XCTAssertEqual(try ChatGPTIdentityVerifier.verify(good, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce").subject, "fictional-user")
        for (key, value) in [("iss", "https://example.invalid" as Any), ("aud", "oaiapp_other"), ("nonce", "bad"), ("exp", 1), ("sub", "")] {
            var changed = base; changed[key] = value
            XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(token(changed), jwks: jwks, clientID: "oaiapp_test", nonce: "nonce"))
        }
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(token(base, alg: "none"), jwks: jwks, clientID: "oaiapp_test", nonce: "nonce"))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(good, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce", expectedSubject: "different-user"))
        let badSignature = good.split(separator: ".").prefix(2).joined(separator: ".") + "." + ChatGPTOAuth.base64url(Data(repeating: 0, count: 256))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(badSignature, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce"))
    }
    func testScopeAndRotatedTokenHandling() throws {
        func response(_ extra: [String: Any]) throws -> Data {
            var base: [String: Any] = ["access_token": "fictional", "id_token": "fictional", "token_type": "Bearer", "expires_in": 3600]
            base.merge(extra) { _, new in new }; return try JSONSerialization.data(withJSONObject: base)
        }
        let denied = try ChatGPTCredential.parse(response(["scope": "openid email"]))
        XCTAssertFalse(denied.permitsPlan)
        let original = try ChatGPTCredential.parse(response(["scope": ChatGPTOAuth.scopes, "refresh_token": "fake-old"]))
        XCTAssertTrue(original.permitsPlan)
        let rotated = try ChatGPTCredential.parse(response(["refresh_token": "fake-new"]), previous: original)
        XCTAssertEqual(rotated.refreshToken, "fake-new"); XCTAssertTrue(rotated.permitsPlan)
        XCTAssertFalse(try ChatGPTCredential.parse(response(["scope": "openid"]), previous: original).permitsPlan)
    }
    func testPlanRequestHasNoUnsupportedFieldsOrTools() throws {
        let data = try ChatGPTProvider.requestBody(context: Data("{}".utf8), schema: Data("{}".utf8), instructions: "fictional", model: "fictional-model")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "store", "stream", "instructions", "input", "text"])
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["input"] as? [[String: Any]])
    }
    func testSSECompletionRefusalAndPrematureEnd() throws {
        let response: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [["content": [["type": "output_text", "text": "{\"reply_body\":\"架空\"}"]]]]]]
        var parser = ChatGPTStream()
        let event = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self) + "\r\n\r\n"
        for byte in event.utf8 { try parser.feed(byte) }
        XCTAssertNoThrow(try ResponsesProvider.parseResponse(parser.finish()))
        XCTAssertThrowsError(try ChatGPTStream().finish())
        for type in ["response.refusal.delta", "response.failed", "response.incomplete", "error"] {
            var failed = ChatGPTStream()
            XCTAssertThrowsError(try Data("data: {\"type\":\"\(type)\"}\n\n".utf8).forEach { try failed.feed($0) })
        }
    }
    func testModelVisibilityAndUsageFailures() throws {
        let data = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"},{"slug":"a","display_name":"Duplicate","visibility":"list"}]}"#.utf8)
        XCTAssertEqual(try ChatGPTHTTP.models(data).map(\.id), ["a"])
        XCTAssertEqual(ChatGPTHTTP.failure(status: 429, data: Data()), .usageLimit)
        XCTAssertEqual(ChatGPTHTTP.failure(status: 403, data: Data()), .ineligible)
        XCTAssertEqual(ChatGPTHTTP.failure(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8)), .signInRequired)
    }
    func testLoopbackCallbackAndCancellation() async throws {
        let listener = ChatGPTLoopback(); let address = try await listener.start(timeout: 5)
        XCTAssertEqual(address.host, "127.0.0.1")
        let task = Task { try await listener.wait() }
        let (_, response) = try await URLSession.shared.data(from: URL(string: address.absoluteString + "?state=fictional&code=fictional")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await task.value; XCTAssertEqual(callback.query, "state=fictional&code=fictional")
        do { _ = try await listener.wait(); XCTFail("Expected one-shot callback") } catch { XCTAssertEqual(error as? ChatGPTError, .callback) }
        let cancelled = ChatGPTLoopback(); _ = try await cancelled.start(); cancelled.cancel()
        do { _ = try await cancelled.wait(); XCTFail("Expected cancelled") } catch { XCTAssertEqual(error as? ChatGPTError, .cancelled) }
    }
}

final class ChatGPTStreamFailureTests: XCTestCase {
    func testCompletedStreamUsesFinalOutputItemsWhenCompletionOmitsThem() throws {
        var parser = ChatGPTStream()
        let events = [
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"description\":\"簡潔な文体。\"}"}]}}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#
        ]
        for event in events { for byte in ("data: " + event + "\n\n").utf8 { try parser.feed(byte) } }
        let result = try ResponsesProvider.parseResponse(parser.finish())
        let value = try JSONSerialization.jsonObject(with: result) as? [String: String]
        XCTAssertEqual(value?["description"], "簡潔な文体。")
    }
    func testFinishedItemWithoutCompletedResponseIsNotUsable() throws {
        var parser = ChatGPTStream()
        let event = #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","status":"completed","content":[{"type":"output_text","text":"{}"}]}}"#
        for byte in ("data: " + event + "\n\n").utf8 { try parser.feed(byte) }
        XCTAssertThrowsError(try parser.finish())
    }
    func testFailedStreamIsDistinguishedFromMalformedFrameAndMissingCompletion() throws {
        let cases = [("data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}\n\n", "CHATGPT_STREAM_FAILED"),
                     ("data: {\"unexpected\":true}\n\n", "CHATGPT_STREAM_INVALID_EVENT"),
                     ("data: [DONE]\n\n", "CHATGPT_STREAM_NOT_COMPLETED")]
        for (payload, expected) in cases {
            do {
                var parser = ChatGPTStream()
                for byte in payload.utf8 { try parser.feed(byte) }
                _ = try parser.finish()
                XCTFail("invalid stream accepted")
            } catch { XCTAssertEqual(error.localizedDescription, expected) }
        }
    }
}
