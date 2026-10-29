//
//  StudioTalkKey.swift
//  Construct Desktop
//
//  The talk key of Studio's hold-to-talk: ⌃⌥T, held, from any application — the engineer is in
//  the DAW, not in the call window. A Carbon hot key, because it is the one system-wide key
//  that reports its release and needs neither Accessibility nor Input Monitoring permission (an
//  `NSEvent` global monitor needs both and does not see key-up reliably). Registered only while
//  hold-to-talk is in use, so ⌃⌥T belongs to the DAW the rest of the time.
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class StudioTalkKey {
    static let shared = StudioTalkKey()

    /// For the hint under the talk button.
    static let label = "⌃⌥T"

    /// Called on press and on release; repeats of a held key arrive as presses and are harmless.
    var onChange: ((_ held: Bool) -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    var isRegistered: Bool {
        get { hotKey != nil }
        set { newValue ? register() : unregister() }
    }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                let held = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                // The application event target delivers on the main thread.
                MainActor.assumeIsolated { StudioTalkKey.shared.onChange?(held) }
                return noErr
            }, types.count, &types, nil, &handler)
            guard status == noErr else {
                Log.error("Studio talk key: handler not installed (\(status))", category: "Studio")
                return
            }
        }
        let id = EventHotKeyID(signature: OSType(0x4B4E_5354), id: 1) // "KNST"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            // Another application holds ⌃⌥T; the on-screen button still works.
            Log.error("Studio talk key: \(Self.label) not registered (\(status))", category: "Studio")
            hotKey = nil
        }
    }

    private func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        // A key held while it is unregistered never reports its release.
        onChange?(false)
    }
}
