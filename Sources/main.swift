import AppKit

// With arguments → command-line tool. Without → menu-bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if let first = cliArgs.first, first != "--menubar" {
    exit(CLI.run(cliArgs))
}
if cliArgs.isEmpty && isatty(STDIN_FILENO) != 0 {
    // Typed in Terminal with no arguments: show help rather than starting a second menu-bar app.
    CLI.usage()
    exit(0)
}

Paths.ensure()
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
