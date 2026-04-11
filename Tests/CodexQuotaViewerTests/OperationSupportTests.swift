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

@Test
func nextMenuNoticeExpiryTracksNearestVisibleNoticeAcrossSources() {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let safeSwitchNotice = MenuNoticeEntry.timed(
        MenuNotice(kind: .info, message: "Switching…"),
        now: now,
        duration: 8
    )
    let sessionManagerNotice = MenuNoticeEntry.timed(
        MenuNotice(kind: .info, message: "Opening…"),
        now: now,
        duration: 3
    )

    #expect(
        nextMenuNoticeExpiry(
            safeSwitchNotice: safeSwitchNotice,
            isForegroundOperationActive: false,
            sessionManagerNotice: sessionManagerNotice,
            isLaunchingSessionManager: false,
            now: now
        ) == now.addingTimeInterval(3)
    )
    #expect(
        nextMenuNoticeExpiry(
            safeSwitchNotice: safeSwitchNotice,
            isForegroundOperationActive: false,
            sessionManagerNotice: sessionManagerNotice,
            isLaunchingSessionManager: false,
            now: now.addingTimeInterval(4)
        ) == now.addingTimeInterval(8)
    )
}

@Test
func deferredPresentationRefreshStateCoalescesRepeatedSignals() {
    var state = DeferredPresentationRefreshState()

    #expect(state.takePendingRefresh() == false)

    state.requestRefresh()
    state.requestRefresh()

    #expect(state.takePendingRefresh() == true)
    #expect(state.takePendingRefresh() == false)
}

@MainActor
@Test
func transientMenuNoticeControllerExpiresTimedNoticeAndInvokesCallback() {
    let now = Date(timeIntervalSince1970: 1_800_000_300)
    var scheduledDelay: TimeInterval?
    var scheduledAction: (@MainActor () -> Void)?
    var expiryCallbackCount = 0
    let controller = TransientMenuNoticeController(
        scheduler: { delay, action in
            scheduledDelay = delay
            scheduledAction = action
            return DispatchWorkItem {}
        },
        onNoticeExpired: {
            expiryCallbackCount += 1
        }
    )

    controller.presentSessionManagerNotice(
        MenuNotice(kind: .info, message: "Opening…"),
        lifetime: .timed(3),
        now: now,
        isForegroundOperationActive: false,
        isLaunchingSessionManager: false
    )

    #expect(
        controller.visibleNotice(
            isForegroundOperationActive: false,
            isLaunchingSessionManager: false,
            localizationNotice: nil,
            statusNotice: nil,
            currentError: nil,
            loadWarningNotice: nil,
            now: now
        )?.message == "Opening…"
    )
    #expect(scheduledDelay == 3)

    scheduledAction?()

    #expect(expiryCallbackCount == 1)
    #expect(
        controller.visibleNotice(
            isForegroundOperationActive: false,
            isLaunchingSessionManager: false,
            localizationNotice: nil,
            statusNotice: nil,
            currentError: nil,
            loadWarningNotice: nil,
            now: now.addingTimeInterval(4)
        ) == nil
    )
}

@MainActor
@Test
func transientMenuNoticeControllerUsesLatestOperationStateWhenExpiryCallbackRuns() {
    let now = Date(timeIntervalSince1970: 1_800_000_400)
    let stateBox = NoticeOperationStateBox(isForegroundOperationActive: true)
    var scheduledAction: (@MainActor () -> Void)?
    let controller = TransientMenuNoticeController(
        scheduler: { _, action in
            scheduledAction = action
            return DispatchWorkItem {}
        },
        operationStateProvider: {
            (
                isForegroundOperationActive: stateBox.isForegroundOperationActive,
                isLaunchingSessionManager: false
            )
        },
        onNoticeExpired: {}
    )

    controller.presentSafeSwitchNotice(
        MenuNotice(kind: .info, message: "Switching…"),
        lifetime: .operationBound,
        now: now,
        isForegroundOperationActive: stateBox.isForegroundOperationActive,
        isLaunchingSessionManager: false
    )
    controller.presentSessionManagerNotice(
        MenuNotice(kind: .info, message: "Opening…"),
        lifetime: .timed(3),
        now: now,
        isForegroundOperationActive: stateBox.isForegroundOperationActive,
        isLaunchingSessionManager: false
    )

    // Operation ends before the timed notice expires.
    stateBox.isForegroundOperationActive = false

    scheduledAction?()

    // Later a new operation starts; the old operation-bound notice should not re-appear.
    stateBox.isForegroundOperationActive = true
    #expect(
        controller.visibleNotice(
            isForegroundOperationActive: stateBox.isForegroundOperationActive,
            isLaunchingSessionManager: false,
            localizationNotice: nil,
            statusNotice: nil,
            currentError: nil,
            loadWarningNotice: nil,
            now: now.addingTimeInterval(4)
        ) == nil
    )
}

@MainActor
private final class NoticeOperationStateBox {
    var isForegroundOperationActive: Bool

    init(isForegroundOperationActive: Bool) {
        self.isForegroundOperationActive = isForegroundOperationActive
    }
}
