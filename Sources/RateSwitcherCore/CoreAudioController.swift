import CoreAudio
import Foundation

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let supportedRates: [Double]
    public let isDefault: Bool

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        sampleRate: Double,
        supportedRates: [Double],
        isDefault: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.supportedRates = supportedRates
        self.isDefault = isDefault
    }
}

public enum SampleRateSwitchResult: Equatable, Sendable {
    case unchanged(AudioOutputDevice, Double)
    case changed(AudioOutputDevice, requested: Double, applied: Double)
    case failed(String)
}

public final class CoreAudioController {
    public var onDevicesChanged: (([AudioOutputDevice]) -> Void)?

    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.core-audio", qos: .userInitiated)
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public init() {
        installListeners()
    }

    deinit { removeListeners() }

    public func outputDevices() -> [AudioOutputDevice] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs()
            .filter(hasOutputStreams)
            .compactMap { makeDevice(id: $0, defaultID: defaultID) }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public func selectedDevice(uid: String?) -> AudioOutputDevice? {
        let devices = outputDevices()
        if let uid, let selected = devices.first(where: { $0.uid == uid }) { return selected }
        return devices.first(where: \.isDefault)
    }

    public func switchSampleRate(
        sourceRate: Double,
        deviceUID: String?,
        completion: @escaping (SampleRateSwitchResult) -> Void
    ) {
        queue.async {
            guard let device = self.selectedDevice(uid: deviceUID) else {
                return self.finish(.failed("找不到可用的音频输出设备"), completion)
            }
            guard let target = SampleRateMatcher.bestRate(for: sourceRate, supported: device.supportedRates) else {
                return self.finish(.failed("设备 \(device.name) 没有报告可用采样率"), completion)
            }
            if abs(device.sampleRate - target) < 0.5 {
                return self.finish(.unchanged(device, target), completion)
            }

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var settable = DarwinBoolean(false)
            let settableStatus = AudioObjectIsPropertySettable(device.id, &address, &settable)
            guard settableStatus == noErr, settable.boolValue else {
                return self.finish(.failed("设备 \(device.name) 不允许修改采样率"), completion)
            }

            var mutableTarget = target
            let status = AudioObjectSetPropertyData(
                device.id,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Double>.size),
                &mutableTarget
            )
            guard status == noErr else {
                return self.finish(.failed("切换 \(device.name) 失败（Core Audio \(Self.fourCC(status))）"), completion)
            }

            let applied = self.waitForSampleRate(target, on: device.id, timeout: 1.6)
                ?? self.nominalSampleRate(device.id)
                ?? device.sampleRate
            guard abs(applied - target) < 0.5 else {
                return self.finish(.failed("设备没有应用请求的采样率（当前 \(SourceAudioFormat.formatRate(applied))）"), completion)
            }
            let refreshed = self.makeDevice(id: device.id, defaultID: self.defaultOutputDeviceID()) ?? device
            Diagnostics.shared.info(
                "输出设备 \(device.name)：\(SourceAudioFormat.formatRate(device.sampleRate)) → \(SourceAudioFormat.formatRate(applied))"
            )
            self.finish(.changed(refreshed, requested: sourceRate, applied: applied), completion)
        }
    }

    public func refresh() {
        queue.async { self.notifyDevicesChanged() }
    }

    /// Returns whether the given process currently has at least one active
    /// Core Audio output stream. This uses the public Audio Process object API
    /// available on macOS 14.2 and later.
    public var supportsProcessOutputActivity: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    public func processOutputActivity(_ pid: pid_t) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var queriedPID = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let translateStatus = withUnsafePointer(to: &queriedPID) { qualifier in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &processObject
            )
        }
        guard translateStatus == noErr, processObject != kAudioObjectUnknown else { return false }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &isRunning) == noErr
            && isRunning != 0
    }

    public func isProcessProducingOutput(_ pid: pid_t) -> Bool {
        processOutputActivity(pid) ?? false
    }

    private func finish(
        _ result: SampleRateSwitchResult,
        _ completion: @escaping (SampleRateSwitchResult) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func makeDevice(id: AudioObjectID, defaultID: AudioObjectID?) -> AudioOutputDevice? {
        guard
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, selector: kAudioObjectPropertyName),
            let rate = nominalSampleRate(id)
        else { return nil }
        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            sampleRate: rate,
            supportedRates: availableSampleRates(id),
            isDefault: id == defaultID
        )
    }

    private func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func waitForSampleRate(_ target: Double, on id: AudioObjectID, timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            Thread.sleep(forTimeInterval: 0.08)
            if let current = nominalSampleRate(id), abs(current - target) < 0.5 { return current }
        } while Date() < deadline
        return nil
    }

    private func availableSampleRates(_ id: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        let status = ranges.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }

        var result = Set<Double>()
        for range in ranges {
            if abs(range.mMinimum - range.mMaximum) < 0.5 {
                result.insert(range.mMinimum)
            } else {
                SampleRateMatcher.commonRates
                    .filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
                    .forEach { result.insert($0) }
                result.insert(range.mMinimum)
                result.insert(range.mMaximum)
            }
        }
        return result.sorted()
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.notifyDevicesChanged() }
        }
        listenerBlock = block
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &defaultAddress, queue, block)
        AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddress, queue, block)
    }

    private func removeListeners() {
        guard let block = listenerBlock else { return }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(systemObject, &defaultAddress, queue, block)
        AudioObjectRemovePropertyListenerBlock(systemObject, &devicesAddress, queue, block)
    }

    private func notifyDevicesChanged() {
        let devices = outputDevices()
        DispatchQueue.main.async { self.onDevicesChanged?(devices) }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return "\(status)"
    }
}
