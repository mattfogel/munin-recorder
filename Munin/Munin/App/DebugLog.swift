import Foundation

var muninDebugEnabled: Bool {
    #if DEBUG
    return true
    #else
    return UserDefaults.standard.bool(forKey: "MuninDebug")
    #endif
}

func debugLog(_ message: String) {
    if muninDebugEnabled {
        print("Munin: \(message)")
    }
}
