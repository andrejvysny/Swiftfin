import Foundation

#if DEBUG

/// Mock network service for testing
public final class MockNetworkService: NetworkServiceProtocol {
    public var tasks: [DownloadID: MockDownloadTask] = [:]
    public var shouldFailDownloads = false
    public var downloadDelay: TimeInterval = 0.1
    
    public init() {}
    
    public func createDownloadTask(with url: URL, identifier: DownloadID) -> URLSessionDownloadTask {
        let task = MockDownloadTask(url: url, identifier: identifier, service: self)
        tasks[identifier] = task
        return task
    }
    
    public func createDownloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        // For simplicity, create a new task
        let id = DownloadID()
        return createDownloadTask(with: URL(string: "https://example.com/file")!, identifier: id)
    }
    
    public func invalidateAndCancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

/// Mock download task for testing
public final class MockDownloadTask: URLSessionDownloadTask {
    private let url: URL
    private let identifier: DownloadID
    private weak var service: MockNetworkService?
    private var isCancelled = false
    private var progress: Double = 0
    
    init(url: URL, identifier: DownloadID, service: MockNetworkService) {
        self.url = url
        self.identifier = identifier
        self.service = service
        super.init()
    }
    
    public override func resume() {
        guard !isCancelled, let service else { return }
        
        Task {
            // Simulate download progress
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: UInt64(service.downloadDelay * 100_000_000))
                
                guard !isCancelled else { return }
                
                progress = Double(i) / 10.0
                
                // Notify delegate of progress
                // This would be connected to the NetworkLayer delegate in a real test
            }
            
            // Simulate completion or failure
            if service.shouldFailDownloads {
                // Simulate failure
            } else {
                // Simulate success
            }
        }
    }
    
    public override func cancel() {
        isCancelled = true
    }
    
    public override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        isCancelled = true
        // Simulate resume data
        let resumeData = "mock-resume-data".data(using: .utf8)
        completionHandler(resumeData)
    }
}

/// URLProtocol for intercepting network requests in tests
public final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    
    public override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    public override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler not set")
        }
        
        do {
            let (response, data) = try handler(request)
            
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    public override func stopLoading() {
        // No-op
    }
}

/// Mock persistence for testing
public actor MockPersistenceLayer: PersistenceLayerProtocol {
    private var storage: [DownloadID: DownloadRecord] = [:]
    
    public init() {}
    
    public func save(_ record: DownloadRecord) async throws {
        storage[record.id] = record
    }
    
    public func update(_ record: DownloadRecord) async throws {
        guard storage[record.id] != nil else {
            throw PersistenceError.notFound
        }
        storage[record.id] = record
    }
    
    public func delete(id: DownloadID) async throws {
        storage.removeValue(forKey: id)
    }
    
    public func fetchAll() async throws -> [DownloadRecord] {
        Array(storage.values)
    }
    
    public func fetch(id: DownloadID) async throws -> DownloadRecord? {
        storage[id]
    }
    
    public func deleteAll() async throws {
        storage.removeAll()
    }
}

#endif 