import Foundation

// Chunk frame format (little-endian):
// [0]     flags       - bit0: isFirst, bit1: isLast
// [1..2]  sequenceId  - random per transfer session
// [3..4]  chunkIndex  - 0-based chunk number
// [5..]   payload     - raw bytes (text or image fragment)

struct ChunkProtocol {

    static func encode(_ data: Data, mtu: Int = BLEConstants.defaultMTU) -> [Data] {
        let maxPayload = max(mtu - BLEConstants.chunkHeaderSize, 1)
        let sequenceId = UInt16.random(in: 0...UInt16.max)

        if data.isEmpty {
            return [makeChunk(flags: 0x03, sequenceId: sequenceId, chunkIndex: 0, payload: Data())]
        }

        var chunks: [Data] = []
        var offset = 0
        var chunkIndex: UInt16 = 0

        while offset < data.count {
            let end = min(offset + maxPayload, data.count)
            let fragment = data[offset..<end]

            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }           // isFirst
            if end == data.count { flags |= 0x02 }      // isLast

            chunks.append(makeChunk(flags: flags, sequenceId: sequenceId, chunkIndex: chunkIndex, payload: fragment))
            offset = end
            chunkIndex += 1
        }

        return chunks
    }

    private static func makeChunk(flags: UInt8, sequenceId: UInt16, chunkIndex: UInt16, payload: Data) -> Data {
        var data = Data(capacity: BLEConstants.chunkHeaderSize + payload.count)
        data.append(flags)
        data.append(contentsOf: withUnsafeBytes(of: sequenceId.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: chunkIndex.littleEndian) { Array($0) })
        data.append(payload)
        return data
    }
}

class ChunkReassembler {
    private var currentSequenceId: UInt16?
    private var chunks: [UInt16: Data] = [:]
    private var expectedLast: UInt16?

    func receive(_ data: Data) -> Data? {
        guard data.count >= BLEConstants.chunkHeaderSize else {
            Logger.debug("Received chunk too small: \(data.count) bytes")
            return nil
        }

        let flags = data[0]
        let sequenceId = data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        let chunkIndex = data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        let payload = data.subdata(in: 5..<data.count)

        let isFirst = (flags & 0x01) != 0
        let isLast = (flags & 0x02) != 0

        Logger.debug("Chunk received: seq=\(sequenceId) idx=\(chunkIndex) first=\(isFirst) last=\(isLast) payload=\(payload.count)B")

        // New transfer session
        if isFirst {
            currentSequenceId = sequenceId
            chunks.removeAll()
            expectedLast = nil
        }

        guard currentSequenceId == sequenceId else {
            Logger.debug("Ignoring chunk with stale sequenceId \(sequenceId)")
            return nil
        }

        chunks[chunkIndex] = payload

        if isLast {
            expectedLast = chunkIndex
        }

        // Check if all chunks received
        if let last = expectedLast {
            let totalChunks = Int(last) + 1
            if chunks.count == totalChunks {
                var assembled = Data()
                for i in 0..<UInt16(totalChunks) {
                    if let chunk = chunks[i] {
                        assembled.append(chunk)
                    } else {
                        Logger.debug("Missing chunk \(i), cannot reassemble")
                        return nil
                    }
                }
                // Reset state
                currentSequenceId = nil
                chunks.removeAll()
                expectedLast = nil

                return assembled
            }
        }

        return nil
    }
}
