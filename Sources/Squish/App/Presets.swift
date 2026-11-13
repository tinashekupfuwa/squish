import Foundation

/// A named set of compression settings. Built-in presets ship with the app; your own are saved in user defaults.
struct EncodePreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var detail: String
    var settings: EncodeSettings
    var quality: Int
    var builtIn = false

    static func make(_ id: String, _ name: String, _ detail: String, quality: Int, configure: (inout EncodeSettings) -> Void = { _ in }) -> EncodePreset {
        var settings = EncodeSettings()
        for codec in Codec.allCases { settings.crf[codec] = CompressModel.crf(for: codec, quality: quality) }
        configure(&settings)
        return EncodePreset(id: UUID(uuidString: id)!, name: name, detail: detail, settings: settings, quality: quality, builtIn: true)
    }

    static let builtIns: [EncodePreset] = [
        make("5A0F2E9C-0000-4000-8000-000000000001", "Balanced", "Much smaller, no visible loss", quality: 50),
        make("5A0F2E9C-0000-4000-8000-000000000002", "Best quality", "Light compression, bigger files", quality: 80),
        make("5A0F2E9C-0000-4000-8000-000000000003", "Smallest files", "Strong compression", quality: 20),
        make("5A0F2E9C-0000-4000-8000-000000000004", "Website hero", "1920 px max, no audio, 30 fps", quality: 50) { s in
            s.maxWidth = 1920
            s.audio = .remove
            s.frameRate = .cap
        },
    ]
}

enum Persistence {
    private static let defaults = UserDefaults.standard

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
