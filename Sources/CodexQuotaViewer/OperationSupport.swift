import Foundation

enum ForegroundOperation: Equatable {
    case apiOnboarding
    case chatGPTBrowserLogin
    case chatGPTDeviceLogin
    case chatGPTProviderMode
    case safeSwitch
    case repair
    case rollback
}

struct ForegroundOperationState: Equatable {
    private(set) var activeOperation: ForegroundOperation?

    var isBusy: Bool {
        activeOperation != nil
    }

    mutating func begin(_ operation: ForegroundOperation) -> Bool {
        guard activeOperation == nil else {
            return false
        }

        activeOperation = operation
        return true
    }

    mutating func handoff(to operation: ForegroundOperation) {
        activeOperation = operation
    }

    mutating func end(_ operation: ForegroundOperation) {
        guard activeOperation == operation else {
            return
        }

        activeOperation = nil
    }
}

struct RefreshRequestState: Equatable {
    private(set) var isRefreshing = false
    private(set) var hasPendingRefresh = false

    mutating func begin() -> Bool {
        guard !isRefreshing else {
            hasPendingRefresh = true
            return false
        }

        isRefreshing = true
        return true
    }

    mutating func finish() -> Bool {
        isRefreshing = false
        let shouldRunAgain = hasPendingRefresh
        hasPendingRefresh = false
        return shouldRunAgain
    }
}

struct RefreshProgress: Equatable {
    let completedCount: Int
    let totalCount: Int

    var fractionText: String {
        "\(completedCount)/\(totalCount)"
    }
}

struct DeferredPresentationRefreshState: Equatable {
    private(set) var hasPendingRefresh = false

    mutating func requestRefresh() {
        hasPendingRefresh = true
    }

    mutating func takePendingRefresh() -> Bool {
        let shouldRefresh = hasPendingRefresh
        hasPendingRefresh = false
        return shouldRefresh
    }
}
