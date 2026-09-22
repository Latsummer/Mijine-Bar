import AppKit

@MainActor
final class NativeWallpaperManager {
    enum ApplyResult {
        case success
        case missingResource
        case partialFailure([String])
    }

    private let workspace = NSWorkspace.shared

    @discardableResult
    func applyToAllScreens() -> ApplyResult {
        guard let imageURL = Bundle.main.url(forResource: "KrustyKrab", withExtension: "jpg") else {
            return .missingResource
        }

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true
        ]
        var failures: [String] = []

        for (index, screen) in NSScreen.screens.enumerated() {
            do {
                try workspace.setDesktopImageURL(imageURL, for: screen, options: options)
            } catch {
                failures.append("显示器 \(index + 1)：\(error.localizedDescription)")
            }
        }

        return failures.isEmpty ? .success : .partialFailure(failures)
    }
}
