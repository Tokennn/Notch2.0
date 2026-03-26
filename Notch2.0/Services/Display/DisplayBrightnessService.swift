import CoreGraphics
import Darwin

final class DisplayBrightnessService {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let getBrightnessFn: GetBrightnessFn?
    private let setBrightnessFn: SetBrightnessFn?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices"
        let handle = dlopen(path, RTLD_NOW)
        self.handle = handle

        if let handle {
            getBrightnessFn = DisplayBrightnessService.resolveSymbol(named: "DisplayServicesGetBrightness", in: handle)
            setBrightnessFn = DisplayBrightnessService.resolveSymbol(named: "DisplayServicesSetBrightness", in: handle)
        } else {
            getBrightnessFn = nil
            setBrightnessFn = nil
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func currentBrightness() -> Float? {
        guard let getBrightnessFn else { return nil }

        var value = Float(0)
        let result = getBrightnessFn(CGMainDisplayID(), &value)
        guard result == 0 else { return nil }

        return clamp(value)
    }

    func nudge(by delta: Float) -> Float? {
        guard let current = currentBrightness() else { return nil }
        let updated = clamp(current + delta)

        guard setBrightness(updated) else { return nil }
        return updated
    }

    private func setBrightness(_ value: Float) -> Bool {
        guard let setBrightnessFn else { return false }
        let result = setBrightnessFn(CGMainDisplayID(), clamp(value))
        return result == 0
    }

    private static func resolveSymbol<T>(named name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
