import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

// Minimal helpers actually used by the server:
// - Optional.unwrap for throwing-style DB lookups
// - Encodable.toJSON / toJSONString for LLM prompt interpolation + response bodies
// - jsonResponse / textResponse for route handlers

extension Optional {
    func unwrap(orError error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}

extension Encodable {
    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(self)
    }

    func toJSONString() throws -> String {
        let data = try toJSON()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Response helpers

func responseBody(from data: Data) -> ResponseBody {
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return ResponseBody(byteBuffer: buffer)
}

func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try value.toJSON()
    let body = responseBody(from: data)
    let headers = HTTPFields([
        HTTPField(name: .contentType, value: "application/json; charset=utf-8")
    ])
    return Response(status: status, headers: headers, body: body)
}

func textResponse(_ text: String, contentType: String = "text/plain; charset=utf-8", status: HTTPResponse.Status = .ok) -> Response {
    let data = Data(text.utf8)
    let body = responseBody(from: data)
    let headers = HTTPFields([
        HTTPField(name: .contentType, value: contentType)
    ])
    return Response(status: status, headers: headers, body: body)
}
