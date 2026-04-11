import OSLog

enum AppLog {
    private static let subsystem = "CodexQuotaViewer"

    static let refresh = Logger(subsystem: subsystem, category: "refresh")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let sessionManager = Logger(subsystem: subsystem, category: "session-manager")
    static let safeSwitch = Logger(subsystem: subsystem, category: "safe-switch")
}
