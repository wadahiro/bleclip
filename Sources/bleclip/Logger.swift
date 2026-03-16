import Foundation

enum Logger {
    static var debugEnabled = false

    static func info(_ msg: String) {
        fputs("[bleclip] \(msg)\n", stderr)
    }

    static func debug(_ msg: String) {
        if debugEnabled {
            fputs("[bleclip:debug] \(msg)\n", stderr)
        }
    }
}
