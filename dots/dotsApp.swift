import AppKit

@main
enum DotsMain {
    private static let delegate = AppDelegate()

    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
