// UniTrackDecoder.swift
//
// Drop-in replacement for JSONDecoder that reports parse failures to
// the SDK with target type, error, and a data preview. Partners use it
// like:
//
//     let user = try UniTrackDecoder.decode(User.self, from: data)

import Foundation

public enum UniTrackDecoder {

    public static func decode<T: Decodable>(_ type: T.Type,
                                            from data: Data,
                                            decoder: JSONDecoder = JSONDecoder())
        throws -> T
    {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8)
                ?? "<binary>"
            UniTrack.track("json_parse_error", properties: [
                "type":         String(describing: T.self),
                "error":        "\(error)",
                "data_preview": preview
            ])
            throw error
        }
    }
}
