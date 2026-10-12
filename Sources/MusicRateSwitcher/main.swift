import AppKit

let application = NSApplication.shared

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    application.setActivationPolicy(.accessory)
    SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}
#endif

let delegate = AppDelegate()
application.delegate = delegate
application.run()
