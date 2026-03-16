import Foundation
import CoreBluetooth

protocol CentralManagerDelegate: AnyObject {
    func centralDidReceiveClipboard(_ data: Data)
    func centralDidConnect()
    func centralDidDisconnect()
}

class BLECentralManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?
    private var clipCharacteristic: CBCharacteristic?
    private let reassembler = ChunkReassembler()

    weak var delegate: CentralManagerDelegate?
    var isConnected: Bool { discoveredPeripheral?.state == .connected && clipCharacteristic != nil }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public

    func sendData(_ data: Data) {
        guard let peripheral = discoveredPeripheral, let characteristic = clipCharacteristic else {
            Logger.debug("Central: no connection, cannot send")
            return
        }

        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let chunks = ChunkProtocol.encode(data, mtu: mtu)
        Logger.debug("Central: sending \(chunks.count) chunk(s) via write (MTU=\(mtu), total=\(data.count)B)")

        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
        }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        guard !centralManager.isScanning else { return }
        centralManager.scanForPeripherals(withServices: [BLEConstants.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        Logger.info("Scanning started")
    }

    func stopScanning() {
        centralManager.stopScan()
        Logger.debug("Scanning stopped")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Logger.debug("Central state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            if central.state == .unauthorized {
                Logger.info("Bluetooth permission denied. Please allow in System Settings > Privacy & Security > Bluetooth.")
            }
            return
        }
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "unknown"
        Logger.info("Discovered peripheral: \(name) (\(peripheral.identifier))")

        discoveredPeripheral = peripheral
        peripheral.delegate = self
        stopScanning()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Logger.info("Connected to peripheral: \(peripheral.identifier)")
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Logger.info("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        discoveredPeripheral = nil
        clipCharacteristic = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Logger.info("Disconnected from peripheral")
        discoveredPeripheral = nil
        clipCharacteristic = nil
        delegate?.centralDidDisconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startScanning()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics([BLEConstants.characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics where char.uuid == BLEConstants.characteristicUUID {
            clipCharacteristic = char
            peripheral.setNotifyValue(true, for: char)
            Logger.info("Subscribed to clipboard characteristic")
            delegate?.centralDidConnect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if let assembled = reassembler.receive(data) {
            Logger.debug("Central: received complete data (\(assembled.count) bytes)")
            delegate?.centralDidReceiveClipboard(assembled)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            Logger.debug("Central: write error: \(error.localizedDescription)")
        }
    }
}
