import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func foregroundOperationStateHandsOffWithoutUnlocking() {
    var state = ForegroundOperationState()

    let began = state.begin(.chatGPTBrowserLogin)
    #expect(began)
    #expect(state.isBusy)
    #expect(state.activeOperation == .chatGPTBrowserLogin)

    state.handoff(to: .chatGPTDeviceLogin)

    #expect(state.isBusy)
    #expect(state.activeOperation == .chatGPTDeviceLogin)

    state.end(.chatGPTBrowserLogin)
    #expect(state.isBusy)
    #expect(state.activeOperation == .chatGPTDeviceLogin)

    state.end(.chatGPTDeviceLogin)
    #expect(!state.isBusy)
    #expect(state.activeOperation == nil)
}

@Test
func menuNoticeEntryKeepsSuccessInfoVisibleUntilExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = MenuNoticeEntry.timed(
        MenuNotice(kind: .info, message: "Added account."),
        now: now,
        duration: 5
    )

    #expect(entry.visibleNotice(at: now, operationIsActive: false)?.message == "Added account.")
    #expect(entry.visibleNotice(at: now.addingTimeInterval(4.9), operationIsActive: false)?.message == "Added account.")
    #expect(entry.visibleNotice(at: now.addingTimeInterval(5.1), operationIsActive: false) == nil)
}

@Test
func visibleMenuNoticePrefersOperationNoticeButFallsBackToTimedSuccessToast() {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let activeNotice = MenuNoticeEntry.operationBound(
        MenuNotice(kind: .info, message: "Switching…")
    )
    let completedNotice = MenuNoticeEntry.timed(
        MenuNotice(kind: .info, message: "Switched."),
        now: now,
        duration: 4
    )

    #expect(
        visibleMenuNotice(
            safeSwitchNotice: activeNotice,
            isForegroundOperationActive: true,
            sessionManagerNotice: nil,
            isLaunchingSessionManager: false,
            localizationNotice: nil,
            statusNotice: nil,
            currentError: nil,
            loadWarningNotice: nil,
            now: now
        )?.message == "Switching…"
    )

    #expect(
        visibleMenuNotice(
            safeSwitchNotice: completedNotice,
            isForegroundOperationActive: false,
            sessionManagerNotice: nil,
            isLaunchingSessionManager: false,
            localizationNotice: nil,
            statusNotice: nil,
            currentError: nil,
            loadWarningNotice: nil,
            now: now.addingTimeInterval(1)
        )?.message == "Switched."
    )
}
