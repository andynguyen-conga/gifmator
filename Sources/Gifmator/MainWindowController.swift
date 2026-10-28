import AppKit

final class MainWindowController: NSWindowController {
    let rootViewController: RootViewController

    init() {
        let rootVC = RootViewController()
        self.rootViewController = rootVC

        let initial = NSRect(x: 0, y: 0, width: 1120, height: 760)
        let window = NSWindow(contentRect: initial,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Gifmator"
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.contentViewController = rootVC
        window.setFrameAutosaveName("GifmatorMainWindow")
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
