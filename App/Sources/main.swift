import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--record") {
    let out = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath
    exit(Recorder.run(outDir: URL(fileURLWithPath: out), only: args.count > i + 2 ? args[i + 2] : nil))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
