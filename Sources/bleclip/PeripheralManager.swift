import Foundation
import CoreBluetooth

protocol PeripheralManagerDelegate: AnyObject {
    func peripheralDidReceiveClipboard(_ data: Data)
    func peripheralDidConnect()
    func peripheralDidDisconnect()
}

class BLEPeripheralManager: NSObject, CBPeripheralManagerDelegate {
    private var peripheralManager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    private var pendingChunks: [Data] = []
    private let reassembler = ChunkReassembler()

    weak var delegate: PeripheralManagerDelegate?
    var isConnected: Bool { subscribedCentral != nil }

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - Public

    func sendData(_ data: Data, mtu: Int? = nil) {
        guard let central = subscribedCentral, let characteristic = characteristic else {
            Logger.debug("Peripheral: no subscriber, cannot send")
            return
        }

        let effectiveMTU = mtu ?? central.maximumUpdateValueLength
        let chunks = ChunkProtocol.encode(data, mtu: effectiveMTU)
        Logger.debug("Peripheral: sending \(chunks.count) chunk(s) via notify (MTU=\(effectiveMTU), total=\(data.count)B)")

        for (i, chunk) in chunks.enumerated() {
            let sent = peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [central])
            if !sent {
                pendingChunks = Array(chunks[i...])
                Logger.debug("Peripheral: BLE queue full, \(pendingChunks.count) chunks queued")
                return
            }
        }
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }
        guard !peripheralManager.isAdvertising else { return }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "bleclip"
        ])
        Logger.info("Advertising started")
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        Logger.debug("Advertising stopped")
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Logger.debug("Peripheral state: \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized {
                Logger.info("Bluetooth permission denied. Please allow in System Settings > Privacy & Security > Bluetooth.")
            }
            return
        }

        let char = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        self.characteristic = char

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [char]
        peripheralManager.add(service)

        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Logger.info("Central subscribed: \(central.identifier) (notify MTU=\(central.maximumUpdateValueLength))")
        subscribedCentral = central
        stopAdvertising()
        delegate?.peripheralDidConnect()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Logger.info("Central unsubscribed: \(central.identifier)")
        subscribedCentral = nil
        delegate?.peripheralDidDisconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startAdvertising()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value {
                if let assembled = reassembler.receive(data) {
                    Logger.debug("Peripheral: received complete data (\(assembled.count) bytes)")
                    delegate?.peripheralDidReceiveClipboard(assembled)
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let central = subscribedCentral, let characteristic = characteristic else { return }
        Logger.debug("Peripheral: ready to send, \(pendingChunks.count) chunks pending")

        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.first!
            let sent = peripheral.updateValue(chunk, for: characteristic, onSubscribedCentrals: [central])
            if sent {
                pendingChunks.removeFirst()
            } else {
                break
            }
        }
    }
}
