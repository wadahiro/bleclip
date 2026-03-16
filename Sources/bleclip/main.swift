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

    private var centralConnected = false
    private var peripheralConnected = false

    func start() {
        peripheralManager.delegate = self
        centralManager.delegate = self

        Logger.info("Starting bleclip...")
        Logger.info("Waiting for another bleclip instance nearby...")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        guard let content = clipboardMonitor.checkForChange() else { return }
        let data = content.toData()
        switch content {
        case .text(let str):
            Logger.info("Sending text (\(str.count) chars)")
        case .image(let imgData):
            Logger.info("Sending image (\(imgData.count) bytes)")
        }
        sendToRemote(data)
    }

    private func sendToRemote(_ data: Data) {
        if centralConnected {
            centralManager.sendData(data)
        }
        if peripheralConnected {
            peripheralManager.sendData(data)
        }
    }

    private func receiveFromRemote(_ data: Data) {
        guard let content = ClipboardContent.fromData(data) else {
            Logger.debug("Failed to decode received clipboard data")
            return
        }
        clipboardMonitor.setClipboard(content)
        switch content {
        case .text(let str):
            Logger.info("Received text (\(str.count) chars)")
        case .image(let imgData):
            Logger.info("Received image (\(imgData.count) bytes)")
        }
    }

    private func updateConnectionStatus() {
        if centralConnected || peripheralConnected {
            Logger.info("Connected - clipboard sharing active")
        }
    }

    // MARK: - PeripheralManagerDelegate

    func peripheralDidReceiveClipboard(_ data: Data) {
        receiveFromRemote(data)
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

    func centralDidReceiveClipboard(_ data: Data) {
        receiveFromRemote(data)
    }

    func centralDidConnect() {
        centralConnected = true
        peripheralManager.stopAdvertising()
        updateConnectionStatus()
    }

    func centralDidDisconnect() {
        centralConnected = false
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

RunLoop.main.run()
