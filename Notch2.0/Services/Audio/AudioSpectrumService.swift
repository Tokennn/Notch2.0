import Foundation
import Combine
import Accelerate
import AudioToolbox
import CoreMedia
import CoreGraphics
import QuartzCore
import ScreenCaptureKit

final class AudioSpectrumService: NSObject, ObservableObject {
    static let shared = AudioSpectrumService()

    @Published private(set) var bands: [Float] = Array(repeating: 0, count: 14)
    @Published private(set) var hasLiveAudio: Bool = false

    private let processingQueue = DispatchQueue(label: "notch2.audio-spectrum.processing", qos: .userInteractive)

    private var stream: SCStream?
    private var isStarting = false
    private var isCapturing = false

    private let fftSize = 1024
    private let hopSize = 256
    private let barCount = 14
    private var sampleRate: Float = 48_000

    private var fftSetup: OpaquePointer?
    private var window: [Float]
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]

    private var sampleAccumulator: [Float] = []
    private var smoothedBars: [Float]
    private var previousRawBars: [Float]
    private var lastPublishTime: CFTimeInterval = 0

    private override init() {
        window = Array(repeating: 0, count: fftSize)
        inputReal = Array(repeating: 0, count: fftSize)
        inputImag = Array(repeating: 0, count: fftSize)
        outputReal = Array(repeating: 0, count: fftSize)
        outputImag = Array(repeating: 0, count: fftSize)
        smoothedBars = Array(repeating: 0, count: barCount)
        previousRawBars = Array(repeating: 0, count: barCount)
        super.init()

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), vDSP_DFT_Direction.FORWARD)
    }

    deinit {
        if let fftSetup {
            vDSP_DFT_DestroySetup(fftSetup)
        }
    }

    func startIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startCaptureIfNeeded()
        }
    }

    @MainActor
    private func startCaptureIfNeeded() async {
        guard isCapturing == false else { return }
        guard isStarting == false else { return }
        guard fftSetup != nil else { return }

        isStarting = true
        defer { isStarting = false }

        let hasPermission = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        guard hasPermission else {
            hasLiveAudio = false
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                hasLiveAudio = false
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.queueDepth = 1
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(sampleRate)
            configuration.channelCount = 2

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            try await stream.startCapture()

            self.stream = stream
            self.isCapturing = true
        } catch {
            hasLiveAudio = false
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        let asbd = asbdPointer.pointee

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        sampleRate = Float(asbd.mSampleRate)

        let mono = extractMonoSamples(
            from: sampleBuffer,
            frameCount: frameCount,
            asbd: asbd
        )
        guard mono.isEmpty == false else { return }

        sampleAccumulator.append(contentsOf: mono)

        while sampleAccumulator.count >= fftSize {
            for index in 0 ..< fftSize {
                inputReal[index] = sampleAccumulator[index] * window[index]
                inputImag[index] = 0
            }

            sampleAccumulator.removeFirst(min(hopSize, sampleAccumulator.count))
            computeAndPublishBands()
        }

        if sampleAccumulator.count > (fftSize * 6) {
            sampleAccumulator.removeFirst(sampleAccumulator.count - (fftSize * 2))
        }
    }

    private func computeAndPublishBands() {
        guard let fftSetup else { return }

        vDSP_DFT_Execute(
            fftSetup,
            &inputReal,
            &inputImag,
            &outputReal,
            &outputImag
        )

        let halfCount = fftSize / 2
        var magnitudes = Array(repeating: Float(0), count: halfCount)
        magnitudes[0] = 0

        if halfCount > 1 {
            for index in 1 ..< halfCount {
                let real = outputReal[index]
                let imag = outputImag[index]
                magnitudes[index] = sqrt((real * real) + (imag * imag))
            }
        }

        let rawBars = mapMagnitudesToBars(magnitudes: magnitudes, sampleRate: sampleRate)

        for index in 0 ..< barCount {
            let transient = max(0, rawBars[index] - previousRawBars[index]) * 1.35
            previousRawBars[index] = rawBars[index]

            let target = min(1, (rawBars[index] * 0.78) + transient)
            if target > smoothedBars[index] {
                smoothedBars[index] = (smoothedBars[index] * 0.24) + (target * 0.76)
            } else {
                smoothedBars[index] = max(target, smoothedBars[index] * 0.88)
            }
        }

        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= (1.0 / 30.0) else { return }
        lastPublishTime = now

        let barsForUI = smoothedBars
        DispatchQueue.main.async { [weak self] in
            self?.bands = barsForUI
            self?.hasLiveAudio = true
        }
    }

    private func mapMagnitudesToBars(magnitudes: [Float], sampleRate: Float) -> [Float] {
        let nyquist = max(sampleRate * 0.5, 1)
        let minFrequency: Float = 40
        let maxFrequency = min(12_000, nyquist - 1)
        guard maxFrequency > minFrequency else {
            return Array(repeating: 0, count: barCount)
        }

        var mapped = Array(repeating: Float(0), count: barCount)
        let maxBin = magnitudes.count - 1

        for bar in 0 ..< barCount {
            let startRatio = Float(bar) / Float(barCount)
            let endRatio = Float(bar + 1) / Float(barCount)

            let startFrequency = minFrequency * powf(maxFrequency / minFrequency, startRatio)
            let endFrequency = minFrequency * powf(maxFrequency / minFrequency, endRatio)

            let startBin = max(1, min(maxBin, Int((startFrequency / nyquist) * Float(maxBin))))
            let endBin = max(startBin + 1, min(maxBin, Int((endFrequency / nyquist) * Float(maxBin))))
            if startBin >= endBin {
                continue
            }

            var sum: Float = 0
            for bin in startBin ..< endBin {
                sum += magnitudes[bin]
            }

            let mean = sum / Float(endBin - startBin)
            let compressed = log10f(1 + (mean * 28))
            mapped[bar] = min(max(compressed / 2.05, 0), 1)
        }

        return mapped
    }

    private func extractMonoSamples(
        from sampleBuffer: CMSampleBuffer,
        frameCount: Int,
        asbd: AudioStreamBasicDescription
    ) -> [Float] {
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let maxBuffers = max(channelCount, 1)
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + ((maxBuffers - 1) * MemoryLayout<AudioBuffer>.size)
        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.isEmpty == false else { return [] }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var mono = Array(repeating: Float(0), count: frameCount)

        if isFloat {
            if isNonInterleaved {
                for frame in 0 ..< frameCount {
                    var sum: Float = 0
                    var usedChannels = 0
                    for channel in 0 ..< min(channelCount, buffers.count) {
                        guard let mData = buffers[channel].mData else { continue }
                        let channelPointer = mData.assumingMemoryBound(to: Float.self)
                        sum += channelPointer[frame]
                        usedChannels += 1
                    }

                    if usedChannels > 0 {
                        mono[frame] = sum / Float(usedChannels)
                    }
                }
            } else if let first = buffers.first, let mData = first.mData {
                let samples = mData.assumingMemoryBound(to: Float.self)
                for frame in 0 ..< frameCount {
                    var sum: Float = 0
                    for channel in 0 ..< channelCount {
                        sum += samples[(frame * channelCount) + channel]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            }
            return mono
        }

        if isSignedInt, asbd.mBitsPerChannel == 16 {
            let scale = Float(1.0 / 32768.0)
            if isNonInterleaved {
                for frame in 0 ..< frameCount {
                    var sum: Float = 0
                    var usedChannels = 0
                    for channel in 0 ..< min(channelCount, buffers.count) {
                        guard let mData = buffers[channel].mData else { continue }
                        let channelPointer = mData.assumingMemoryBound(to: Int16.self)
                        sum += Float(channelPointer[frame]) * scale
                        usedChannels += 1
                    }

                    if usedChannels > 0 {
                        mono[frame] = sum / Float(usedChannels)
                    }
                }
            } else if let first = buffers.first, let mData = first.mData {
                let samples = mData.assumingMemoryBound(to: Int16.self)
                for frame in 0 ..< frameCount {
                    var sum: Float = 0
                    for channel in 0 ..< channelCount {
                        sum += Float(samples[(frame * channelCount) + channel]) * scale
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            }
            return mono
        }

        return []
    }
}

extension AudioSpectrumService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        processAudioSampleBuffer(sampleBuffer)
    }
}

extension AudioSpectrumService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            self.hasLiveAudio = false
        }
    }
}
