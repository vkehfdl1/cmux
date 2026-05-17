import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationStoreMemoryCapTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
    }

    override func tearDown() {
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        super.tearDown()
    }

    func testNotificationsCappedAtMaxRetained() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let now = Date()
        let oversized = (0..<2_000).map { idx in
            TerminalNotification(
                id: UUID(),
                tabId: tabId,
                surfaceId: surfaceId,
                title: "n\(idx)",
                subtitle: nil,
                body: "body \(idx)",
                createdAt: now.addingTimeInterval(TimeInterval(idx)),
                isRead: false,
                paneFlash: false
            )
        }
        store.replaceNotificationsForTesting(oversized)
        XCTAssertEqual(
            store.notifications.count,
            1_000,
            "Notification array must be capped to max retained size"
        )
    }
}
