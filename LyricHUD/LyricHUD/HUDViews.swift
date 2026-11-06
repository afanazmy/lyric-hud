import SwiftUI

// MARK: - Ukuran & warna (ubah di sini untuk menyetel kemiripan dengan mockup)

enum Metrics {
    static let compact = CGSize(width: 420, height: 34)
    static let expanded = CGSize(width: 420, height: 244)
    /// Ruang transparan di sekeliling bentuk, untuk bayangan.
    static let pad: CGFloat = 14
    static let gapBelowMenuBar: CGFloat = 6
    static let expandedCornerRadius: CGFloat = 30
}

enum Theme {
    static let surface = Color(white: 0.07)
    static let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
}

// MARK: - Root: satu bentuk yang berubah ukuran (morph) antara compact dan expanded

struct HUDRootView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        let expanded = model.isExpanded
        let size = expanded ? Metrics.expanded : Metrics.compact
        let radius = expanded ? Metrics.expandedCornerRadius : size.height / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack(alignment: .top) {
            CompactContent(model: model)
                .frame(width: Metrics.compact.width, height: Metrics.compact.height)
                .opacity(expanded ? 0 : 1)

            ExpandedContent(model: model)
                .frame(width: Metrics.expanded.width, height: Metrics.expanded.height)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Theme.surface))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(Metrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: expanded)
    }
}

// MARK: - State 1: pill 1 baris

struct CompactContent: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            EqualizerView(isPlaying: model.isPlaying)

            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)

            // Baris lama keluar ke atas, baris baru masuk dari bawah.
            ZStack(alignment: .leading) {
                Text(model.currentLine)
                    .id(model.currentIndex)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.3), value: model.currentIndex)
    }
}

// MARK: - State 2: expanded (header, lirik 4 baris, kontrol)

struct ExpandedContent: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 10) {
            header
            lyricsBox
            controls
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Placeholder cover. Nanti bisa diganti artwork dari MediaSession.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.42, green: 0.20, blue: 0.80), Color(red: 0.93, green: 0.32, blue: 0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(model.artist) • \(model.album)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if model.lyricsStatus == .found {
                SyncAdjuster(model: model)
            }
        }
        .frame(height: 44)
    }

    private var lyricsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.visibleLines) { line in
                HStack(spacing: 6) {
                    if line.isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: line.isCurrent ? 16 : 13, weight: line.isCurrent ? .bold : .medium))
                        .foregroundStyle(lineColor(line))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 116, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.currentIndex)
    }

    private func lineColor(_ line: VisibleLine) -> Color {
        if line.isCurrent { return .white }
        // Baris yang sudah lewat lebih redup daripada baris yang akan datang.
        return Color.white.opacity(line.id < model.currentIndex ? 0.28 : 0.45)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            CircleButton(systemName: "backward.end.fill") { model.send(.previous) }

            Button {
                model.send(.togglePlay)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(model.isPlaying ? "SYNCING" : "PAUSED")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.8)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(Theme.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            CircleButton(systemName: "forward.end.fill") { model.send(.next) }
        }
        .frame(height: 36)
    }
}

// MARK: - Komponen kecil

struct CircleButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Tiga batang equalizer hijau; bergerak saat memutar, diam saat pause.
struct EqualizerView: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let level = isPlaying ? 0.35 + 0.65 * abs(sin(t * 4 + Double(i) * 1.7)) : 0.3
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2.5, height: 14 * level)
                }
            }
            .frame(height: 14)
        }
    }
}

/// Atur waktu tampil lirik untuk lagu yang sedang diputar.
/// "+" = lirik muncul lebih awal (pakai kalau lirik terasa telat),
/// "−" = lebih lambat (pakai kalau lirik terasa terlalu cepat). Klik angkanya untuk reset ke 0.
struct SyncAdjuster: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(spacing: 0) {
            nudgeButton(systemName: "minus", delta: -0.25)

            Button {
                model.setOffset(0)
            } label: {
                Text(model.offsetLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.trackOffset == 0 ? Color.white.opacity(0.5) : Theme.accent)
                    .frame(minWidth: 54)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            nudgeButton(systemName: "plus", delta: 0.25)
        }
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .help("Lirik telat? Tekan +. Lirik terlalu cepat? Tekan −. Klik angka untuk reset.")
    }

    private func nudgeButton(systemName: String, delta: Double) -> some View {
        Button {
            model.nudgeOffset(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
