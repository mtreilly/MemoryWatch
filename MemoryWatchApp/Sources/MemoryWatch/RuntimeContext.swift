import Foundation

public enum RuntimeContext {
    private static let environment = Foundation.ProcessInfo.processInfo.environment

    public static let isSandboxed: Bool = {
        if let override = environment["MEMWATCH_FORCE_SANDBOX"] {
            return override == "1" || override.lowercased() == "true"
        }
        if environment["CODEX_MANAGED_BY_BUN"] != nil { return true }
        if environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        return false
    }()

    public static var maintenanceEnabled: Bool {
        if let override = environment["MEMWATCH_ENABLE_MAINTENANCE"] {
            return override == "1" || override.lowercased() == "true"
        }
        if let disable = environment["MEMWATCH_DISABLE_MAINTENANCE"],
           disable == "1" || disable.lowercased() == "true" {
            return false
        }
        return !isSandboxed
    }

    public static var walIntrospectionEnabled: Bool {
        if let override = environment["MEMWATCH_ENABLE_WAL_INTROSPECTION"] {
            return override == "1" || override.lowercased() == "true"
        }
        if let disable = environment["MEMWATCH_DISABLE_WAL_INTROSPECTION"],
           disable == "1" || disable.lowercased() == "true" {
            return false
        }
        return !isSandboxed
    }
}
