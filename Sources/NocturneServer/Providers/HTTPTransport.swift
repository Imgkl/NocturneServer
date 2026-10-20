import AsyncHTTPClient
import Foundation
import NIOCore

/// A fully buffered HTTP response. Header names are lowercased.
struct OutboundResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

/// The one seam between the server and the network. Production uses AsyncHTTPClient;
/// tests use a scripted fake.
protocol HTTPTransport: Sendable {
    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> OutboundResponse
}

struct AsyncHTTPClientTransport: HTTPTransport {
    let client: HTTPClient
    var maxBodyBytes: Int = 16 * 1024 * 1024

    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> OutboundResponse {
        let response = try await client.execute(request, timeout: timeout)
        var buffer = try await response.body.collect(upTo: maxBodyBytes)
        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
        var headers: [String: String] = [:]
        for (name, value) in response.headers {
            headers[name.lowercased()] = value
        }
        return OutboundResponse(status: Int(response.status.code), headers: headers, body: data)
    }
}
