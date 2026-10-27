//
//  main.swift
//  DimBar — entry point. No arguments starts the menu bar app,
//  arguments run the command line interface.
//

import AppKit

private let usage = """
DimBar — external display brightness over DDC/CI (Apple Silicon).

usage:
  dimbar                      run the menu bar app
  dimbar list                 list external displays and their brightness
  dimbar get [index]          print brightness percentage
  dimbar set <index|all> <p>  set brightness (0-100)
  dimbar step <index|all> <d> adjust brightness by d
  dimbar login on|off|status  toggle "open at login"
  dimbar --help

Without an index, commands act on all external displays.
Global shortcuts in the app: ctrl+option+up / ctrl+option+down
"""

private func selected(_ displays: [ExternalDisplay], _ spec: String?) -> [ExternalDisplay] {
    guard let spec, spec != "all" else { return displays }
    guard let index = Int(spec), index >= 1, index <= displays.count else { return [] }
    return [displays[index - 1]]
}

private func runCLI(_ args: [String]) -> Int32 {
    guard let command = args.first else { return 0 }

    switch command {
    case "--help", "-h", "help":
        print(usage)
        return 0

    case "list":
        let displays = DisplayDiscovery.externalDisplays()
        guard !displays.isEmpty else {
            print("No external display with DDC found.")
            return 1
        }
        for (index, display) in displays.enumerated() {
            let percent = display.bus.read(vcp: VCP.brightness)?.percent
            let value = percent.map { "\($0)%" } ?? "n/a"
            let size = "\(CGDisplayPixelsWide(display.id))x\(CGDisplayPixelsHigh(display.id))"
            print("[\(index + 1)] \(display.name)  \(value)  (id \(display.id), \(size))")
        }
        return 0

    case "get":
        let displays = selected(DisplayDiscovery.externalDisplays(), args.dropFirst().first)
        guard !displays.isEmpty else {
            print("No matching display.")
            return 1
        }
        for display in displays {
            if let value = display.bus.read(vcp: VCP.brightness) {
                print(value.percent)
            } else {
                print("n/a")
                return 1
            }
        }
        return 0

    case "set":
        let rest = Array(args.dropFirst())
        guard rest.count >= 2, let percent = Int(rest[1]), (0...100).contains(percent) else {
            print("usage: dimbar set <index|all> <0-100>")
            return 2
        }
        let displays = selected(DisplayDiscovery.externalDisplays(), rest[0])
        guard !displays.isEmpty else {
            print("No matching display.")
            return 1
        }
        for display in displays {
            display.bus.setBrightness(percent: percent)
        }
        return 0

    case "step":
        let rest = Array(args.dropFirst())
        guard rest.count >= 2, let delta = Int(rest[1]) else {
            print("usage: dimbar step <index|all> <delta>")
            return 2
        }
        let displays = selected(DisplayDiscovery.externalDisplays(), rest[0])
        guard !displays.isEmpty else {
            print("No matching display.")
            return 1
        }
        for display in displays {
            let current = display.bus.read(vcp: VCP.brightness)?.percent ?? 50
            display.bus.setBrightness(percent: min(100, max(0, current + delta)))
        }
        return 0

    case "login":
        switch args.dropFirst().first {
        case "on":
            print(LoginItem.enable() ? "login item enabled" : "failed to enable login item")
            return LoginItem.isEnabled ? 0 : 1
        case "off":
            _ = LoginItem.disable()
            print("login item disabled")
            return 0
        case "status":
            print(LoginItem.isEnabled ? "on" : "off")
            return 0
        default:
            print("usage: dimbar login on|off|status")
            return 2
        }

    default:
        print(usage)
        return 2
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    exit(runCLI(arguments))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
