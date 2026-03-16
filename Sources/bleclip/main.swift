import Foundation
import AppKit

// MARK: - CLI Argument Parsing

var debugMode = false
var secureMode = false
var args = Array(CommandLine.arguments.dropFirst())

// Parse flags
args = args.filter { arg in
    switch arg {
    case "--debug", "-d":
        debugMode = true
        return false
    case "--secure", "-s":
        secureMode = true
        return false
    case "--help", "-h":
        print("""
        bleclip - BLE Clipboard Sharing for macOS

        Share clipboard between two Macs via Bluetooth Low Energy.
        No IP address needed. Just run bleclip on both Macs.

        Usage: bleclip [--secure/-s] [--debug/-d] [--help/-h]

        Options:
          --secure, -s   Encrypt clipboard data with a shared password
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

// Read password if secure mode
var password: Data? = nil
if secureMode {
    print("Password: ", terminator: "")
    // Disable echo for password input
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

    if let line = readLine() {
        password = Data(line.utf8)
    }

    // Restore terminal
    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
    print() // newline after password

    guard let pw = password, !pw.isEmpty else {
        fputs("Error: password cannot be empty\n", stderr)
        exit(1)
    }
    Logger.info("Secure mode enabled")
}

// MARK: - App Coordinator

class AppCoordinator: PeripheralManagerDelegate, CentralManagerDelegate {
    let clipboardMonitor = ClipboardMonitor()
    let peripheralManager = BLEPeripheralManager()
    let centralManager = BLECentralManager()
    let password: Data?
    private var pollTimer: Timer?

    private var centralConnected = false
    private var peripheralConnected = false

    init(password: Data?) {
        self.password = password
    }

    func start() {
        peripheralManager.delegate = self
        centralManager.delegate = self

        Logger.info("Starting bleclip...")
        if password != nil {
            Logger.info("Encryption enabled")
        }
        Logger.info("Waiting for another bleclip instance nearby...")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        guard let content = clipboardMonitor.checkForChange() else { return }
        var data = content.toData()
        switch content {
        case .text(let str):
            Logger.info("Sending text (\(str.count) chars)")
        case .image(let imgData):
            Logger.info("Sending image (\(imgData.count) bytes)")
        }

        // Encrypt if secure mode
        if let pw = password {
            guard let encrypted = Crypto.encrypt(data, password: pw) else {
                Logger.info("Encryption failed, skipping")
                return
            }
            Logger.debug("Encrypted: \(data.count)B -> \(encrypted.count)B")
            data = encrypted
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
        var payload = data

        // Decrypt if secure mode
        if let pw = password {
            guard let decrypted = Crypto.decrypt(payload, password: pw) else {
                Logger.info("Decryption failed (wrong password or corrupted data), ignoring")
                return
            }
            Logger.debug("Decrypted: \(payload.count)B -> \(decrypted.count)B")
            payload = decrypted
        }

        guard let content = ClipboardContent.fromData(payload) else {
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

let coordinator = AppCoordinator(password: password)
coordinator.start()

RunLoop.main.run()
