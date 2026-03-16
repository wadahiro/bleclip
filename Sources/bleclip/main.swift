import Foundation
import AppKit

// MARK: - CLI Argument Parsing

var debugMode = false
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--debug", "-d":
        debugMode = true
    case "--help", "-h":
        print("""
        bleclip - BLE Clipboard Sharing for macOS

        Share clipboard between two Macs via Bluetooth Low Energy.
        No IP address needed. Just run bleclip on both Macs.

        Usage: bleclip [--debug/-d] [--help/-h]

        Options:
          --debug, -d    Enable verbose debug logging
          --help, -h     Show this help message
        """)
        exit(0)
    default:
        fputs("Unknown option: \(arg)\n", stderr)
        exit(1)
    }
}

Logger.debugEnabled = debugMode

// MARK: - App Coordinator

class AppCoordinator: PeripheralManagerDelegate, CentralManagerDelegate {
    let clipboardMonitor = ClipboardMonitor()
    let peripheralManager = BLEPeripheralManager()
    let centralManager = BLECentralManager()
    private var pollTimer: Timer?

    // Track connection state to decide which path to send on
    private var centralConnected = false
    private var peripheralConnected = false

    func start() {
        peripheralManager.delegate = self
        centralManager.delegate = self

        Logger.info("Starting bleclip...")
        Logger.info("Waiting for another bleclip instance nearby...")

        // Poll clipboard every 1 second
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        guard let newText = clipboardMonitor.checkForChange() else { return }
        Logger.debug("Clipboard changed (\(newText.count) chars): \(newText.prefix(80))...")
        sendToRemote(newText)
    }

    private func sendToRemote(_ text: String) {
        if centralConnected {
            centralManager.sendClipboard(text)
        }
        if peripheralConnected {
            peripheralManager.sendClipboard(text)
        }
    }

    private func receiveFromRemote(_ text: String) {
        clipboardMonitor.setClipboard(text)
        Logger.info("Clipboard received (\(text.count) chars)")
    }

    private func updateConnectionStatus() {
        let connected = centralConnected || peripheralConnected
        if connected {
            Logger.info("Connected - clipboard sharing active")
        }
    }

    // MARK: - PeripheralManagerDelegate

    func peripheralDidReceiveClipboard(_ text: String) {
        receiveFromRemote(text)
    }

    func peripheralDidConnect() {
        peripheralConnected = true
        updateConnectionStatus()
    }

    func peripheralDidDisconnect() {
        peripheralConnected = false
        Logger.info("Peripheral connection lost. Waiting for reconnection...")
    }

    // MARK: - CentralManagerDelegate

    func centralDidReceiveClipboard(_ text: String) {
        receiveFromRemote(text)
    }

    func centralDidConnect() {
        centralConnected = true
        // Stop advertising when we connect as Central to avoid duplicate connections
        peripheralManager.stopAdvertising()
        updateConnectionStatus()
    }

    func centralDidDisconnect() {
        centralConnected = false
        // Resume advertising since Central connection is lost
        peripheralManager.startAdvertising()
        Logger.info("Central connection lost. Waiting for reconnection...")
    }
}

// MARK: - Signal Handling

signal(SIGINT) { _ in
    Logger.info("Shutting down...")
    exit(0)
}
signal(SIGTERM) { _ in
    Logger.info("Shutting down...")
    exit(0)
}

// MARK: - Main

let coordinator = AppCoordinator()
coordinator.start()

// CoreBluetooth requires RunLoop
RunLoop.main.run()
