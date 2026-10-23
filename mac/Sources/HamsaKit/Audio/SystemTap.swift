#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// T04: all system audio except Hamsa itself ("them" channel), via a Core Audio process tap.
/// Pattern from insidegui/AudioCap (BSD-2): tap -> private aggregate device -> IOProc.
@available(macOS 14.2, *)
public final class SystemTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hamsa.systemtap", qos: .userInitiated)

    public init() {}

    public func start(onBuffer: @escaping AudioSink) throws {
        // Our own process object only exists once we are an audio client (start the mic first); 0 = exclude nobody.
        let own = try Self.ownProcessObject()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw AudioError("process tap creation failed (system audio recording permission?)", status: err) }
        tapID = tap

        do {
            var asbd = try Self.tapFormat(tap)
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw AudioError("bad tap format") }

            // No main sub-device / output UID on purpose: the aggregate holds only the tap, so switching output
            // (e.g. to AirPods) keeps working. If macOS refuses a tap-only aggregate, add the default output UID
            // (AudioCap style) and comment `shortcut:` here.
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "HamsaTap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]
                ],
            ]
            err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
            guard err == noErr else { throw AudioError("aggregate device creation failed", status: err) }

            err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
                // No-copy view: only valid during this callback, the sink converts synchronously.
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inData, deallocator: nil) else { return }
                onBuffer(buffer)
            }
            guard err == noErr else { throw AudioError("IOProc creation failed", status: err) }
            err = AudioDeviceStart(aggregateID, procID)
            guard err == noErr else { throw AudioError("AudioDeviceStart failed", status: err) }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func ownProcessObject() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard err == noErr else { throw AudioError("cannot translate own pid to audio object", status: err) }
        return object
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw AudioError("cannot read tap format", status: err) }
        return asbd
    }
}
#endif
