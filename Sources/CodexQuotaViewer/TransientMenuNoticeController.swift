import Foundation

@MainActor
final class TransientMenuNoticeController {
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DispatchWorkItem

    private(set) var safeSwitchNotice: MenuNoticeEntry?
    private(set) var sessionManagerNotice: MenuNoticeEntry?

    private var pendingExpiryRefresh: DispatchWorkItem?
    private let scheduler: Scheduler
    private let onNoticeExpired: @MainActor () -> Void

    init(
        scheduler: @escaping Scheduler = TransientMenuNoticeController.defaultScheduler,
        onNoticeExpired: @escaping @MainActor () -> Void
    ) {
        self.scheduler = scheduler
        self.onNoticeExpired = onNoticeExpired
    }

    func presentSafeSwitchNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date(),
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool
    ) {
        safeSwitchNotice = makeMenuNoticeEntry(notice, lifetime: lifetime, now: now)
        scheduleExpiryRefreshIfNeeded(
            now: now,
            isForegroundOperationActive: isForegroundOperationActive,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    func presentSessionManagerNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date(),
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool
    ) {
        sessionManagerNotice = makeMenuNoticeEntry(notice, lifetime: lifetime, now: now)
        scheduleExpiryRefreshIfNeeded(
            now: now,
            isForegroundOperationActive: isForegroundOperationActive,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    func clearSessionManagerNotice(
        now: Date = Date(),
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool
    ) {
        sessionManagerNotice = nil
        scheduleExpiryRefreshIfNeeded(
            now: now,
            isForegroundOperationActive: isForegroundOperationActive,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    func normalize(
        now: Date = Date(),
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool
    ) {
        safeSwitchNotice = normalizeMenuNoticeEntry(
            safeSwitchNotice,
            at: now,
            operationIsActive: isForegroundOperationActive
        )
        sessionManagerNotice = normalizeMenuNoticeEntry(
            sessionManagerNotice,
            at: now,
            operationIsActive: isLaunchingSessionManager
        )
        scheduleExpiryRefreshIfNeeded(
            now: now,
            isForegroundOperationActive: isForegroundOperationActive,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    func visibleNotice(
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool,
        localizationNotice: MenuNotice?,
        statusNotice: MenuNotice?,
        currentError: String?,
        loadWarningNotice: String?,
        now: Date = Date()
    ) -> MenuNotice? {
        CodexQuotaViewer.visibleMenuNotice(
            safeSwitchNotice: safeSwitchNotice,
            isForegroundOperationActive: isForegroundOperationActive,
            sessionManagerNotice: sessionManagerNotice,
            isLaunchingSessionManager: isLaunchingSessionManager,
            localizationNotice: localizationNotice,
            statusNotice: statusNotice,
            currentError: currentError,
            loadWarningNotice: loadWarningNotice,
            now: now
        )
    }

    private func makeMenuNoticeEntry(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date
    ) -> MenuNoticeEntry {
        switch lifetime {
        case .operationBound:
            return .operationBound(notice)
        case .timed(let duration):
            return .timed(notice, now: now, duration: duration)
        case .persistent:
            return .persistent(notice)
        }
    }

    private func scheduleExpiryRefreshIfNeeded(
        now: Date,
        isForegroundOperationActive: Bool,
        isLaunchingSessionManager: Bool
    ) {
        pendingExpiryRefresh?.cancel()
        pendingExpiryRefresh = nil

        guard let expiresAt = nextMenuNoticeExpiry(
            safeSwitchNotice: safeSwitchNotice,
            isForegroundOperationActive: isForegroundOperationActive,
            sessionManagerNotice: sessionManagerNotice,
            isLaunchingSessionManager: isLaunchingSessionManager,
            now: now
        ) else {
            return
        }

        let delay = max(0, expiresAt.timeIntervalSince(now))
        pendingExpiryRefresh = scheduler(delay) { [weak self] in
            guard let self else { return }
            self.pendingExpiryRefresh = nil
            self.normalize(
                now: Date(),
                isForegroundOperationActive: isForegroundOperationActive,
                isLaunchingSessionManager: isLaunchingSessionManager
            )
            self.onNoticeExpired()
        }
    }

    private static func defaultScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> DispatchWorkItem {
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return workItem
    }
}
