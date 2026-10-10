import AppKit
import AudioToolbox

/// Short sounds for the moments that matter: a job starts, finishes or fails, something is saved, copied, added or
/// deleted. All apps of the same author use this palette, so they sound like one family. The sounds belong to macOS:
/// they are read from the system at run time, not copied into the app, and play the way the system's own interface
/// sounds do, at the alert volume of System Settings → Sound and through the device chosen there for sound effects.
/// The switch is in Settings (⌘,).
enum SoundEffects {
    enum Event: CaseIterable {
        /// A job finished: a timer ran out, something was made or saved.
        case success
        /// Something failed: an error alert, an action that did not work.
        case failure
        /// A job started: a timer, a long action.
        case start
        /// A small confirmation: something copied, added or switched on.
        case mark
        /// Something deleted or cleared.
        case delete
        /// Something sent out: saved to a file, shared.
        case send
    }

    /// The switch in Settings; on by default.
    static let enabledKey = "soundEffects"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Plays the sound of `event` unless the sounds are off. Returns at once: loading and playing happen on a queue
    /// of their own.
    static func play(_ event: Event) {
        guard isEnabled else { return }
        queue.async {
            if let id = systemSounds[event] {
                AudioServicesPlaySystemSound(id)
            } else {
                // The file is gone in this version of macOS: the classic sound of /System/Library/Sounds instead.
                let name = event.fallback
                DispatchQueue.main.async { NSSound(named: name)?.play() }
            }
        }
    }

    private static let queue = DispatchQueue(label: "Theine.SoundEffects", qos: .userInitiated)

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"

    /// Every file is registered with the system once, when the first sound is needed.
    private static let systemSounds: [Event: SystemSoundID] = {
        var ids: [Event: SystemSoundID] = [:]
        for event in Event.allCases {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(URL(fileURLWithPath: folder + event.file) as CFURL, &id) == kAudioServicesNoError {
                ids[event] = id
            }
        }
        return ids
    }()
}

private extension SoundEffects.Event {
    /// The sound in the system sounds folder of Core Audio.
    var file: String {
        switch self {
        case .success: return "system/head_gestures_double_nod.caf"
        case .failure: return "system/head_gestures_double_shake.caf"
        case .start: return "system/begin_record.caf"
        case .mark: return "system/head_gestures_partial_nod.caf"
        case .delete: return "dock/poof item off dock.aif"
        case .send: return "system/SentMessage.caf"
        }
    }

    /// The nearest classic sound, for a macOS without the file.
    var fallback: String {
        switch self {
        case .success: return "Glass"
        case .failure: return "Basso"
        case .start, .mark: return "Tink"
        case .delete: return "Pop"
        case .send: return "Purr"
        }
    }
}
