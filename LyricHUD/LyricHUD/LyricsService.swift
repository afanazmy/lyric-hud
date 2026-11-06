import Foundation

struct LyricLine: Equatable, Sendable {
    let time: Double
    let text: String
}

struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double?
}

enum LyricsResult: Sendable {
    case synced([LyricLine])
    case instrumental
    case notFound
}

/// Mengambil lirik berwaktu dari LRCLIB (lrclib.net): gratis, tanpa API key.
actor LyricsService {
    static let shared = LyricsService()

    /// Toleransi selisih durasi (detik) antara lagu yang diputar dan rekaman di LRCLIB.
    private let durationTolerance: Double = 8

    private var cache: [String: LyricsResult] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "LyricHUD/0.1 (personal macOS app)"]
        return URLSession(configuration: config)
    }()

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func fetch(_ query: LyricsQuery) async -> LyricsResult {
        let key = "\(query.title)\u{0}\(query.artist)"
        if let cached = cache[key] { return cached }
        do {
            let result = try await lookup(query)
            cache[key] = result
            return result
        } catch {
            // Gagal jaringan: jangan di-cache, supaya dicoba lagi saat lagu diputar ulang.
            return .notFound
        }
    }

    // MARK: - Pencarian

    private func lookup(_ q: LyricsQuery) async throws -> LyricsResult {
        // 1. Pencocokan persis (judul + artis + album + durasi).
        if let duration = q.duration, !q.album.isEmpty {
            let items = [
                URLQueryItem(name: "track_name", value: q.title),
                URLQueryItem(name: "artist_name", value: q.artist),
                URLQueryItem(name: "album_name", value: q.album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
            ]
            if let data = try await request("get", items),
               let record = try? decoder.decode(Record.self, from: data) {
                if record.instrumental == true { return .instrumental }
                if let synced = record.syncedLyrics, !synced.isEmpty {
                    let lines = LRCParser.parse(synced)
                    if !lines.isEmpty { return .synced(lines) }
                }
            }
        }

        // 2. Pencarian longgar dengan judul yang sudah dibersihkan.
        let title = Self.cleanTitle(q.title)
        let mainArtist = Self.mainArtist(q.artist)

        var attempts: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: q.artist)]
        ]
        if mainArtist != q.artist {
            attempts.append([URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: mainArtist)])
        }
        attempts.append([URLQueryItem(name: "q", value: "\(title) \(mainArtist)")])

        for items in attempts {
            guard let data = try await request("search", items),
                  let records = try? decoder.decode([Record].self, from: data),
                  let best = pickBest(records, duration: q.duration) else { continue }
            let lines = LRCParser.parse(best)
            if !lines.isEmpty { return .synced(lines) }
        }
        return .notFound
    }

    /// Pilih rekaman yang punya lirik berwaktu dan durasinya paling dekat.
    private func pickBest(_ records: [Record], duration: Double?) -> String? {
        var pool = records.filter { ($0.syncedLyrics ?? "").isEmpty == false }
        if let duration {
            pool = pool
                .filter { abs(($0.duration ?? .infinity) - duration) <= durationTolerance }
                .sorted { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        }
        return pool.first?.syncedLyrics
    }

    /// nil = 404 (tidak ada); throw = gangguan jaringan/server.
    private func request(_ path: String, _ items: [URLQueryItem]) async throws -> Data? {
        guard var components = URLComponents(string: "https://lrclib.net/api/\(path)") else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - Normalisasi

    /// "Judul (feat. X)" → "Judul", "Judul - Remastered 2011" → "Judul".
    static func cleanTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: #"\s+-\s+.*(remaster|live|version|edit|mix|mono|stereo).*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "Artis A, Artis B" → "Artis A".
    static func mainArtist(_ artist: String) -> String {
        let first = artist.components(separatedBy: CharacterSet(charactersIn: ",&/;")).first ?? artist
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }
}

/// Parser format LRC: baris seperti `[01:23.45]teks`, boleh punya beberapa timestamp.
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = timestamp(tag) else { break }   // tag metadata seperti [ar:Nama] dilewati
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }

            guard !times.isEmpty else { continue }
            let content = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(LyricLine(time: time, text: content))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
