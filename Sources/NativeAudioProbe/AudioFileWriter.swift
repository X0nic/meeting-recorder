import AVFoundation
import Foundation

enum AudioFileWriterError: LocalizedError {
    case missingFormat
    case couldNotReadAudioBuffers(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingFormat:
            return "Sample buffer did not contain a readable audio format."
        case .couldNotReadAudioBuffers(let status):
            return "Failed to read audio sample buffers (OSStatus \(status))."
        }
    }
}

final class AudioFileWriter {
    let url: URL
    var formatDescription: String?

    private let eventHandler: @Sendable (String) -> Void
    private var audioFile: AVAudioFile?
    private var started = false
    private var finished = false

    init(url: URL, eventHandler: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.eventHandler = eventHandler
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        let pcmBuffer = try Self.makePCMBuffer(from: sampleBuffer)

        if audioFile == nil {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: pcmBuffer.format.settings,
                commonFormat: pcmBuffer.format.commonFormat,
                interleaved: pcmBuffer.format.isInterleaved
            )
            formatDescription = describe(format: pcmBuffer.format)
        }

        try audioFile?.write(from: pcmBuffer)

        if !started {
            started = true
            eventHandler("File writer started: \(url.lastPathComponent)")
        }

        return pcmBuffer
    }

    func finish() {
        guard !finished else { return }
        finished = true
        audioFile = nil
        eventHandler("File writer finished: \(url.lastPathComponent)")
    }

    private func describe(format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat)"
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioFileWriterError.missingFormat
        }

        let formatPointer = UnsafePointer<AudioStreamBasicDescription>(streamDescription)
        guard let format = AVAudioFormat(streamDescription: formatPointer) else {
            throw AudioFileWriterError.missingFormat
        }

        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw AudioFileWriterError.missingFormat
        }

        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(Int(format.channelCount) - 1, 0) * MemoryLayout<AudioBuffer>.size
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
            throw AudioFileWriterError.couldNotReadAudioBuffers(status)
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        pcmBuffer.frameLength = frameLength

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                continue
            }

            let bytesToCopy = min(Int(sourceBuffers[index].mDataByteSize), Int(destinationBuffers[index].mDataByteSize))
            memcpy(destinationData, sourceData, bytesToCopy)
            destinationBuffers[index].mDataByteSize = UInt32(bytesToCopy)
        }

        return pcmBuffer
    }
}
