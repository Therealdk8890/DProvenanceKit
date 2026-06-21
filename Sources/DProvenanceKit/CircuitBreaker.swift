import Foundation

public actor CircuitBreaker {
    public enum State: Sendable, Equatable {
        case closed
        case open
        case halfOpen
    }
    
    public private(set) var state: State = .closed
    private let maxFailures: Int
    private let decayTimeout: TimeInterval
    private var failureCount = 0
    private var lastFailureTime: Date?
    
    public init(maxFailures: Int = 5, decayTimeout: TimeInterval = 30.0) {
        self.maxFailures = maxFailures
        self.decayTimeout = decayTimeout
    }
    
    public func allowRequest() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            if let last = lastFailureTime, Date().timeIntervalSince(last) >= decayTimeout {
                state = .halfOpen
                return true // Allow one probe
            }
            return false
        case .halfOpen:
            return false // We only allow the initial probe request, any concurrent requests must wait
        }
    }
    
    public func timeUntilAllowed() -> TimeInterval {
        switch state {
        case .closed, .halfOpen:
            return 0
        case .open:
            guard let last = lastFailureTime else { return 0 }
            let elapsed = Date().timeIntervalSince(last)
            return max(0, decayTimeout - elapsed)
        }
    }
    
    public func recordSuccess() {
        failureCount = 0
        state = .closed
        lastFailureTime = nil
    }
    
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        switch state {
        case .closed:
            if failureCount >= maxFailures {
                state = .open
            }
        case .halfOpen:
            state = .open
        case .open:
            break
        }
    }
}
