import Foundation
import Testing
@testable import Director

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    private var body: Data?

    func set(_ request: URLRequest, body: Data?) { lock.withLock { value = request; self.body = body } }
    func clear() { lock.withLock { value = nil; body = nil } }
    var request: URLRequest? { lock.withLock { value } }
    var requestBody: Data? { lock.withLock { body } }
}

private final class WorkerURLProtocol: URLProtocol {
    static let capture = CapturedRequest()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.capture.set(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func workerSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WorkerURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Test func workerTransportSendsContractAndRejectsRemoteHTTP() async throws {
    WorkerURLProtocol.capture.clear()
    let transport = WorkerTransport(endpoint: URL(string: "https://worker.example/api/")!,
                                    inviteToken: "signed-invite", session: workerSession())
    let body = Data(#"{"model":"gpt-6-luna","store":false}"#.utf8)
    let (status, responseBody) = try await transport.send(body)

    #expect(status == 200)
    #expect(String(decoding: responseBody, as: UTF8.self) == #"{"ok":true}"#)
    let request = try #require(WorkerURLProtocol.capture.request)
    #expect(request.url?.absoluteString == "https://worker.example/api/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer signed-invite")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let httpBody = try #require(WorkerURLProtocol.capture.requestBody)
    let decodedJSON = try JSONSerialization.jsonObject(with: httpBody)
    let sentJSON = try #require(decodedJSON as? [String: Any])
    #expect(sentJSON["model"] as? String == "gpt-6-luna")
    #expect(sentJSON["store"] as? Bool == false)

    let rejected = WorkerTransport(endpoint: URL(string: "http://remote.example")!, inviteToken: "signed-invite",
                                   session: workerSession())
    WorkerURLProtocol.capture.clear()
    await #expect(throws: URLError.self) { try await rejected.send(body) }
    #expect(WorkerURLProtocol.capture.request == nil)
}
