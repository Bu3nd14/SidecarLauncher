import AppKit
import SidecarSwitchCore

@MainActor
final class DockIconController {
    private let normalImage: NSImage?
    private let switchingImage: NSImage?
    private let applyImage: (NSImage?) -> Void

    init(normalImage: NSImage?, switchingImage: NSImage?,
         applyImage: @escaping (NSImage?) -> Void = { image in
             NSApp?.applicationIconImage = image
         }) {
        self.normalImage = normalImage
        self.switchingImage = switchingImage
        self.applyImage = applyImage
    }

    convenience init(resourceDirectory: URL? = Bundle.main.resourceURL) {
        let normal = resourceDirectory.map { NSImage(contentsOf: $0.appendingPathComponent("AppIcon.icns")) } ?? nil
        let switching = resourceDirectory.map { NSImage(contentsOf: $0.appendingPathComponent("AppIconSwitch.icns")) } ?? nil
        self.init(normalImage: normal, switchingImage: switching)
    }

    var switchingAssetAvailable: Bool { switchingImage != nil }

    func apply(isTransitioning: Bool) {
        let variant = DockIconPlanner.plan(isTransitioning: isTransitioning,
                                          switchingAssetAvailable: switchingAssetAvailable)
        if let image = variant == .switching ? switchingImage : normalImage {
            applyImage(image)
        }
    }
}
