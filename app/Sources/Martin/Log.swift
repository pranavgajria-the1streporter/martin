import Foundation

/// A plain text log at ~/Library/Logs/Martin.log, so a quiet Martin can always explain himself.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Martin.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ text: String) {
        let line = "\(stamp.string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
