import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                PlaceholderView(onPick: open)
            }
        }
        .frame(minWidth: 720, minHeight: 405)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        }
    }

    private func open(_ url: URL) {
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        newPlayer.play()
    }
}

private struct PlaceholderView: View {
    let onPick: (URL) -> Void
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("DLXV")
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Deluxe video. For Mac.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
            Button("Open Video…") { isImporting = true }
                .controlSize(.large)
                .padding(.top, 8)
            Text("or drag a video file here")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onPick(url)
            }
        }
    }
}
