import Foundation
import Testing

@testable import NocturneServer

@Suite struct JellyfinDtoTests {
    @Test func decodesProviderIdsAndDateLastSaved() throws {
        let json = """
        {
          "Id": "abc123",
          "Name": "Heat",
          "ProductionYear": 1995,
          "ProviderIds": { "Imdb": "tt0113277", "Tmdb": "949" },
          "DateLastSaved": "2026-05-01T10:00:00.0000000Z"
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(BaseItemDto.self, from: json)
        #expect(dto.providerIds?["Imdb"] == "tt0113277")
        #expect(dto.providerIds?["Tmdb"] == "949")
        #expect(dto.dateLastSaved == "2026-05-01T10:00:00.0000000Z")
    }

    @Test func missingFieldsDecodeAsNil() throws {
        let json = #"{ "Id": "abc123", "Name": "Heat" }"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(BaseItemDto.self, from: json)
        #expect(dto.providerIds == nil)
        #expect(dto.dateLastSaved == nil)
    }
}
