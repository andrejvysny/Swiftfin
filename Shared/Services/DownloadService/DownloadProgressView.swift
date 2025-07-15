import SwiftUI
import Factory

/// Example SwiftUI view showing download progress
struct DownloadProgressView: View {
    @StateObject private var viewModel = DownloadProgressViewModel()
    
    let downloadURL: URL
    let itemTitle: String
    
    var body: some View {
        VStack(spacing: 16) {
            Text(itemTitle)
                .font(.headline)
            
            switch viewModel.state {
            case .idle:
                Button("Download") {
                    Task {
                        await viewModel.startDownload(url: downloadURL)
                    }
                }
                .buttonStyle(.borderedProminent)
                
            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        Button("Pause") {
                            Task { await viewModel.pauseDownload() }
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Cancel", role: .destructive) {
                            Task { await viewModel.cancelDownload() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
            case .paused:
                VStack(spacing: 8) {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .foregroundColor(.orange)
                    
                    HStack(spacing: 12) {
                        Button("Resume") {
                            Task { await viewModel.resumeDownload() }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Cancel", role: .destructive) {
                            Task { await viewModel.cancelDownload() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
            case .completed:
                Label("Download Complete", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                
            case .failed(let error):
                VStack(spacing: 8) {
                    Label("Download Failed", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                    
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        Task {
                            await viewModel.startDownload(url: downloadURL)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}

/// ViewModel for download progress tracking
@MainActor
final class DownloadProgressViewModel: ObservableObject {
    @Injected(\.downloadManager) private var downloadManager
    
    @Published private(set) var state: DownloadState = .idle
    
    private var downloadID: DownloadID?
    private var eventTask: Task<Void, Never>?
    
    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case paused
        case completed
        case failed(DownloadError)
    }
    
    func startDownload(url: URL) async {
        // Create download metadata
        let metadata = DownloadMetadata(
            expectedSize: nil, // Will be determined by server
            filename: url.lastPathComponent
        )
        
        // Start download
        let id = await downloadManager.enqueue(
            url,
            priority: .medium,
            metadata: metadata
        )
        
        self.downloadID = id
        
        // Start observing events
        startObservingEvents()
    }
    
    func pauseDownload() async {
        guard let id = downloadID else { return }
        await downloadManager.pause(id)
    }
    
    func resumeDownload() async {
        guard let id = downloadID else { return }
        await downloadManager.resume(id)
    }
    
    func cancelDownload() async {
        guard let id = downloadID else { return }
        await downloadManager.cancel(id)
        state = .idle
        downloadID = nil
    }
    
    func stopObserving() {
        eventTask?.cancel()
        eventTask = nil
    }
    
    private func startObservingEvents() {
        eventTask?.cancel()
        
        eventTask = Task { [weak self] in
            guard let self else { return }
            
            for await event in downloadManager.events {
                guard !Task.isCancelled else { break }
                
                // Only handle events for our download
                guard case let eventID = event.downloadID,
                      eventID == self.downloadID else { continue }
                
                switch event {
                case .queued:
                    self.state = .downloading(progress: 0)
                    
                case .started:
                    self.state = .downloading(progress: 0)
                    
                case .progress(_, let progress):
                    self.state = .downloading(progress: progress)
                    
                case .paused:
                    self.state = .paused
                    
                case .resumed:
                    self.state = .downloading(progress: 0)
                    
                case .completed:
                    self.state = .completed
                    
                case .failed(_, let error):
                    self.state = .failed(error)
                    
                case .cancelled:
                    self.state = .idle
                }
            }
        }
    }
}

// Helper to extract download ID from events
private extension DownloadEvent {
    var downloadID: DownloadID {
        switch self {
        case .queued(let id),
             .started(let id),
             .progress(let id, _),
             .completed(let id, _),
             .failed(let id, _),
             .paused(let id),
             .resumed(let id),
             .cancelled(let id):
            return id
        }
    }
}

// MARK: - Preview

#if DEBUG
struct DownloadProgressView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadProgressView(
            downloadURL: URL(string: "https://example.com/movie.mp4")!,
            itemTitle: "Sample Movie"
        )
    }
}
#endif 