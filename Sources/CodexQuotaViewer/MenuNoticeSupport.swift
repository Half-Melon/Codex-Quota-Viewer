import Foundation

enum MenuNoticeLifetime: Equatable {
    case operationBound
    case timed(TimeInterval)
    case persistent
}

struct MenuNoticeEntry: Equatable {
    let notice: MenuNotice
    let expiresAt: Date?
    let requiresActiveOperation: Bool

    static func operationBound(_ notice: MenuNotice) -> MenuNoticeEntry {
        MenuNoticeEntry(
            notice: notice,
            expiresAt: nil,
            requiresActiveOperation: true
        )
    }

    static func timed(
        _ notice: MenuNotice,
        now: Date = Date(),
        duration: TimeInterval
    ) -> MenuNoticeEntry {
        MenuNoticeEntry(
            notice: notice,
            expiresAt: now.addingTimeInterval(duration),
            requiresActiveOperation: false
        )
    }

    static func persistent(_ notice: MenuNotice) -> MenuNoticeEntry {
        MenuNoticeEntry(
            notice: notice,
            expiresAt: nil,
            requiresActiveOperation: false
        )
    }

    func visibleNotice(
        at now: Date = Date(),
        operationIsActive: Bool
    ) -> MenuNotice? {
        let trimmedMessage = notice.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return nil
        }

        if requiresActiveOperation && !operationIsActive {
            return nil
        }

        if let expiresAt,
           now > expiresAt {
            return nil
        }

        return notice
    }
}

func normalizeMenuNoticeEntry(
    _ entry: MenuNoticeEntry?,
    at now: Date = Date(),
    operationIsActive: Bool
) -> MenuNoticeEntry? {
    guard let entry,
          entry.visibleNotice(at: now, operationIsActive: operationIsActive) != nil else {
        return nil
    }

    return entry
}

func nextMenuNoticeExpiry(
    safeSwitchNotice: MenuNoticeEntry?,
    isForegroundOperationActive: Bool,
    sessionManagerNotice: MenuNoticeEntry?,
    isLaunchingSessionManager: Bool,
    now: Date = Date()
) -> Date? {
    [
        normalizeMenuNoticeEntry(
            safeSwitchNotice,
            at: now,
            operationIsActive: isForegroundOperationActive
        )?.expiresAt,
        normalizeMenuNoticeEntry(
            sessionManagerNotice,
            at: now,
            operationIsActive: isLaunchingSessionManager
        )?.expiresAt,
    ]
    .compactMap { $0 }
    .min()
}

func visibleMenuNotice(
    safeSwitchNotice: MenuNoticeEntry?,
    isForegroundOperationActive: Bool,
    sessionManagerNotice: MenuNoticeEntry?,
    isLaunchingSessionManager: Bool,
    localizationNotice: MenuNotice?,
    statusNotice: MenuNotice?,
    currentError: String?,
    loadWarningNotice: String?,
    now: Date = Date()
) -> MenuNotice? {
    if let notice = normalizeMenuNoticeEntry(
        safeSwitchNotice,
        at: now,
        operationIsActive: isForegroundOperationActive
    )?.notice {
        return notice
    }

    if let notice = normalizeMenuNoticeEntry(
        sessionManagerNotice,
        at: now,
        operationIsActive: isLaunchingSessionManager
    )?.notice {
        return notice
    }

    if let localizationNotice,
       !localizationNotice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return localizationNotice
    }

    if let statusNotice,
       !statusNotice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return statusNotice
    }

    if let currentError,
       !currentError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return MenuNotice(
            kind: .error,
            message: AppLocalization.localized(
                en: "Current account refresh failed: \(currentError)",
                zh: "当前账号刷新失败：\(currentError)"
            )
        )
    }

    if let loadWarningNotice,
       !loadWarningNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return MenuNotice(kind: .warning, message: loadWarningNotice)
    }

    return nil
}
