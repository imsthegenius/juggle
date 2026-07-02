import Foundation

/// Resolves the git repository root enclosing a path by walking up for a `.git`
/// entry. Falls back to the path itself when none is found, so opening a
/// non-repo folder still works. (Process-based `git rev-parse` is deferred to
/// U7's GitService; this avoids a subprocess just to register a repo.)
enum GitRoot {
    static func find(from path: String) -> String {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return (path as NSString).expandingTildeInPath
    }
}
