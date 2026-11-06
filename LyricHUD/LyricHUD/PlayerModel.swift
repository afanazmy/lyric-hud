import Combine
import Foundation

enum PlayerCommand: String {
    case togglePlay
    case next
    case previous
}

struct VisibleLine: Identifiable {
    let id: Int
    let text: String
    let isCurrent: Bool
}

/// Snapshot yang dikirim extension (lihat content.js).
struct BridgeState {
    var title: String
    var artist: String
    var album: String
    var duration: Double?
    var position: Double
    var playing: Bool
}

enum LyricsStatus: Equatable {
    case idle
    case loading
    case found
    case notFound
    case instrumental
}

/// State yang dirender oleh HUD.
@MainActor
final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    /// true selama ada lagu dari browser; HUD disembunyikan kalau false.
    @Published var isActive = false
    @Published var isExpanded = false
    @Published private(set) var lyricsStatus: LyricsStatus = .idle
    @Published private(set) var lyricLines: [LyricLine] = []
    /// -1 = belum masuk baris pertama (intro).
    @Published private(set) var currentIndex = -1

    /// Diisi oleh AppDelegate: meneruskan perintah ke extension lewat bridge.
    var onCommand: ((PlayerCommand) -> Void)?

    /// Offset dasar untuk SEMUA lagu, dalam detik. Positif = lirik tampil lebih awal.
    /// Berguna kalau hampir semua lagu terasa telat/cepat (mis. posisi Spotify Web hanya akurat per detik).
    var globalOffset: Double = 0.0

    /// Offset khusus lagu yang sedang diputar. Diatur dari HUD dan disimpan per lagu.
    /// Positif = lirik tampil lebih awal (pakai kalau lirik terasa telat).
    @Published private(set) var trackOffset: Double = 0

    private static let offsetStoreKey = "lyricOffsets"
    private static let offsetStep: Double = 0.25
    private static let offsetLimit: Double = 10

    private var basePosition: Double = 0
    private var baseDate = Date()
    private var duration: Double?
    private var trackKey = ""
    private var offsetKey = ""
    private var lyricsTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateIndex() }
            .store(in: &cancellables)
    }

    // MARK: - Teks untuk tampilan

    /// Teks untuk pill 1 baris.
    var currentLine: String {
        switch lyricsStatus {
        case .found:
            guard lyricLines.indices.contains(currentIndex), !lyricLines[currentIndex].text.isEmpty else { return "♪" }
            return lyricLines[currentIndex].text
        case .loading:
            return "Mencari lirik…"
        case .instrumental:
            return "♪ Instrumental"
        case .notFound, .idle:
            return artist.isEmpty ? title : "\(title) • \(artist)"
        }
    }

    /// Satu baris sebelum, baris aktif, dan dua baris sesudahnya.
    var visibleLines: [VisibleLine] {
        switch lyricsStatus {
        case .found:
            return ((currentIndex - 1)...(currentIndex + 2)).map { i in
                let isCurrent = i == currentIndex
                var text = lyricLines.indices.contains(i) ? lyricLines[i].text : ""
                if text.isEmpty && isCurrent { text = "♪" }
                return VisibleLine(id: i, text: text, isCurrent: isCurrent)
            }
        case .loading:
            return [VisibleLine(id: 0, text: "Mencari lirik…", isCurrent: true)]
        case .instrumental:
            return [VisibleLine(id: 0, text: "♪ Instrumental", isCurrent: true)]
        case .notFound, .idle:
            return [VisibleLine(id: 0, text: "Lirik tidak ditemukan", isCurrent: true)]
        }
    }

    // MARK: - Dari bridge

    func apply(_ s: BridgeState) {
        guard !s.title.isEmpty else { return }

        if title != s.title { title = s.title }
        if artist != s.artist { artist = s.artist }
        if album != s.album { album = s.album }
        if isPlaying != s.playing { isPlaying = s.playing }
        if !isActive { isActive = true }

        duration = s.duration
        basePosition = s.position
        baseDate = Date()

        let key = "\(s.title)\u{0}\(s.artist)"
        if key != trackKey {
            trackKey = key
            offsetKey = "\(s.title) • \(s.artist)"
            trackOffset = storedOffsets[offsetKey] ?? 0
            loadLyrics(for: s)
        }
        updateIndex()
    }

    func setIdle() {
        guard isActive else { return }
        isActive = false
        isExpanded = false
        isPlaying = false
        trackKey = ""
        offsetKey = ""
        trackOffset = 0
        lyricsTask?.cancel()
        lyricLines = []
        currentIndex = -1
        lyricsStatus = .idle
    }

    // MARK: - Dari HUD

    func send(_ command: PlayerCommand) {
        onCommand?(command)
        if command == .togglePlay {
            // Optimistis: UI langsung berubah, nanti dikoreksi oleh state dari browser.
            basePosition = currentPosition()
            baseDate = Date()
            isPlaying.toggle()
        }
    }

    // MARK: - Offset sinkronisasi (per lagu)

    /// Teks untuk tampilan, mis. "+0.50s" atau "0s".
    var offsetLabel: String {
        abs(trackOffset) < 0.001 ? "0s" : String(format: "%+.2fs", trackOffset)
    }

    /// delta positif = lirik tampil lebih awal; negatif = lebih lambat.
    func nudgeOffset(by delta: Double) {
        setOffset(trackOffset + delta)
    }

    func setOffset(_ value: Double) {
        guard !offsetKey.isEmpty else { return }
        let step = Self.offsetStep
        let snapped = (value / step).rounded() * step
        let clamped = min(Self.offsetLimit, max(-Self.offsetLimit, snapped))
        trackOffset = clamped

        var all = storedOffsets
        if clamped == 0 {
            all.removeValue(forKey: offsetKey)
        } else {
            all[offsetKey] = clamped
        }
        storedOffsets = all
        updateIndex()
    }

    private var storedOffsets: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.offsetStoreKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.offsetStoreKey) }
    }

    // MARK: - Lirik & sinkronisasi

    private func loadLyrics(for s: BridgeState) {
        lyricsTask?.cancel()
        lyricLines = []
        currentIndex = -1
        lyricsStatus = .loading

        let key = trackKey
        let query = LyricsQuery(title: s.title, artist: s.artist, album: s.album, duration: s.duration)
        lyricsTask = Task { [weak self] in
            let result = await LyricsService.shared.fetch(query)
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            switch result {
            case .synced(let lines):
                self.lyricLines = lines
                self.lyricsStatus = .found
                self.updateIndex()
            case .instrumental:
                self.lyricsStatus = .instrumental
            case .notFound:
                self.lyricsStatus = .notFound
            }
        }
    }

    private func currentPosition() -> Double {
        var position = basePosition
        if isPlaying { position += Date().timeIntervalSince(baseDate) }
        if let duration, duration > 0 { position = min(position, duration) }
        return max(0, position)
    }

    private func updateIndex() {
        guard isActive, lyricsStatus == .found else { return }
        let position = currentPosition() + globalOffset + trackOffset
        let index = lyricLines.lastIndex(where: { $0.time <= position }) ?? -1
        if index != currentIndex { currentIndex = index }
    }
}
