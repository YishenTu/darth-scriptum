import Foundation

enum RecoveryJSONEncoding {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try TextFileCodec.validateSupportedSize(data)
        return data
    }
}
