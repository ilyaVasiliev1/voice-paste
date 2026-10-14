import Foundation

/// Причина ошибки для журнала: без путей, имён и переносов строк.
nonisolated public enum ErrorSummary {
    public static func describe(_ error: Error) -> String {
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            let label = mirror.children.first?.label ?? String(describing: error)
            return "\(String(describing: type(of: error))).\(label)"
        }
        let bridged = error as NSError
        return "\(bridged.domain)#\(bridged.code)"
    }
}
