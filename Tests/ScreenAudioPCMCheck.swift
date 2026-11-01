import Foundation
import CoreMedia

@main enum Check {
    static func main() {
        func decode(_ bytes: [[UInt8]], bits: UInt32, flags: UInt32, stride: UInt32, channels: UInt32 = 1, frames: Int) -> [Float]? {
            let size = MemoryLayout<AudioBufferList>.size + max(0, bytes.count - 1) * MemoryLayout<AudioBuffer>.stride
            let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
            list.pointee.mNumberBuffers = UInt32(bytes.count)
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let data = bytes.map { b -> UnsafeMutableRawPointer in
                let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, b.count), alignment: 8)
                b.withUnsafeBytes { if !$0.isEmpty { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }; return p
            }
            defer { data.forEach { $0.deallocate() } }
            for i in bytes.indices { buffers[i] = AudioBuffer(mNumberChannels: bytes.count == 1 ? channels : 1, mDataByteSize: UInt32(bytes[i].count), mData: data[i]) }
            let format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags, mBytesPerPacket: stride, mFramesPerPacket: 1, mBytesPerFrame: stride,
                mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
            return ScreenAudioPCM.mono(format, buffers: list, frames: frames)
        }
        func near(_ actual: [Float]?, _ expected: [Float]) {
            precondition(actual?.count == expected.count)
            for i in expected.indices { precondition(abs(actual![i] - expected[i]) < 0.000001) }
        }
        let signed = kAudioFormatFlagIsSignedInteger, big = kAudioFormatFlagIsBigEndian
        near(decode([[0,0x40,0,0xc0]], bits:16,flags:signed,stride:2,frames:2),[0.5,-0.5])
        near(decode([[0x40,0,0xc0,0]], bits:16,flags:signed|big,stride:2,frames:2),[0.5,-0.5])
        near(decode([[0,0,0x40,0,0,0xc0]], bits:24,flags:signed,stride:3,frames:2),[0.5,-0.5])
        near(decode([[0x40,0,0,0xc0,0,0]], bits:24,flags:signed|big,stride:3,frames:2),[0.5,-0.5])
        near(decode([[0,0,0,0x40]],bits:24,flags:signed|kAudioFormatFlagIsAlignedHigh,stride:4,frames:1),[0.5])
        near(decode([[0,0,0x80,0]],bits:32,flags:signed|(24 << kLinearPCMFormatFlagsSampleFractionShift),stride:4,frames:1),[0.5])
        near(decode([[0,0,0,0xc0]],bits:32,flags:signed,stride:4,frames:1),[-0.5])
        near(decode([[0x3f,0xe0,0,0,0,0,0,0]],bits:64,flags:kAudioFormatFlagIsFloat|big,stride:8,frames:1),[0.5])
        near(decode([[0,0x40,255,255]],bits:16,flags:signed,stride:2,frames:1),[0.5])
        near(decode([[0x3f,0,0,0]],bits:32,flags:kAudioFormatFlagIsFloat|big,stride:4,frames:1),[0.5])
        near(decode([[0,0x40],[0,0xc0]],bits:16,flags:signed|kAudioFormatFlagIsNonInterleaved,stride:2,channels:2,frames:1),[0])
        near(decode([[0,0x40,0,0xc0]],bits:16,flags:signed,stride:4,channels:2,frames:1),[0])
        near(decode([[0,128,255]],bits:8,flags:0,stride:1,frames:3),[-1,0,127/128])
        precondition(decode([[0]],bits:24,flags:signed,stride:3,frames:1) == nil)
        var packed: [UInt8] = [], reference: [Float] = []
        for n in 0..<2048 {
            let x = 0.7 * sin(2 * .pi * 440 * Double(n) / 44100)
            let value = UInt32(bitPattern: Int32(x * 8388608))
            packed += [UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)]
            reference.append(Float(x))
        }
        let wave = decode([packed],bits:24,flags:signed|big,stride:3,frames:2048)!
        precondition(zip(wave,reference).allSatisfy { abs($0-$1) < 0.000001 })
        precondition(zip(wave.dropFirst(),wave).allSatisfy { abs($0-$1) < 0.05 }, "Packed24 tone must remain continuous, not just retain a detectable frequency")
        print("PASS PCM16/24 LE/BE, aligned24, fixed8.24, BE float, planar/interleaved mix, unsigned8, bounds and24-bit waveform continuity")
    }
}
