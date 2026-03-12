import AVFoundation
import CoreMedia
import Foundation

enum AudioMeter {
    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return 0
        }

        let asbd = streamDescription.pointee
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        guard bytesPerFrame > 0, bitsPerChannel > 0 else {
            return 0
        }

        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(Int(asbd.mChannelsPerFrame) - 1, 0) * MemoryLayout<AudioBuffer>.size
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListPointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return 0
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        var peak: Float = 0

        for buffer in audioBuffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if byteCount == 0 { continue }

            if bitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                peak = max(peak, peakFloat32(data: data, byteCount: byteCount))
            } else if bitsPerChannel == 16 {
                peak = max(peak, peakInt16(data: data, byteCount: byteCount))
            } else if bitsPerChannel == 32 {
                peak = max(peak, peakInt32(data: data, byteCount: byteCount))
            }
        }

        return uiLevel(fromPeak: peak)
    }

    static func smoothedLevel(previous: Float, incoming: Float) -> Float {
        let attack = max(incoming, previous * 0.82)
        return min(max(attack, 0), 1)
    }

    private static func peakFloat32(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }

    private static func peakInt16(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(Float(samples[index]) / Float(Int16.max)))
        }
        return peak
    }

    private static func peakInt32(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Int32>.size
        let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(Float(samples[index]) / Float(Int32.max)))
        }
        return peak
    }

    private static func uiLevel(fromPeak peak: Float) -> Float {
        let clampedPeak = max(peak, 0.000_01)
        let decibels = 20 * log10(clampedPeak)
        let floorDB: Float = -55
        let normalized = (decibels - floorDB) / -floorDB
        return min(max(normalized, 0), 1)
    }
}
