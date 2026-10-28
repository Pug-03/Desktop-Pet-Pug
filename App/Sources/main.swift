import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--record") {
    let out = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath
    exit(Recorder.run(outDir: URL(fileURLWithPath: out), only: args.count > i + 2 ? args[i + 2] : nil))
}

if let i = args.firstIndex(of: "--schedule-preview"), i + 1 < args.count {
    exit(SchedulePreview.run(args[i + 1]))
}

if let i = args.firstIndex(of: "--letter-preview"), i + 1 < args.count {
    exit(LetterPreview.run(args[i + 1], page: args.count > i + 2 ? Int(args[i + 2]) ?? 0 : 0))
}

if let i = args.firstIndex(of: "--guide-preview"), i + 1 < args.count {
    exit(GuidePreview.run(args[i + 1], lesson: args.count > i + 2 ? Int(args[i + 2]) ?? 0 : 0))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
