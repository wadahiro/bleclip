import CoreBluetooth

enum BLEConstants {
    static let serviceUUID = CBUUID(string: "B1E3C11B-0001-4000-8000-00805F9B34FB")
    static let characteristicUUID = CBUUID(string: "B1E3C11B-0002-4000-8000-00805F9B34FB")
    static let chunkHeaderSize = 5
    static let defaultMTU = 512
    static let maxChunkPayload = defaultMTU - chunkHeaderSize
}
