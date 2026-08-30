import AppKit
import Carbon.HIToolbox

/// グローバルホットキー。メニューを開かずに、遅いと感じたその瞬間に測定を叩けるようにする。
/// Carbon の RegisterEventHotKey はアクセシビリティ権限が不要なのでこれを使う。
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: kVK_ANSI_* の値
    ///   - modifiers: cmdKey / optionKey / shiftKey / controlKey の OR
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = HotKey.nextID; HotKey.nextID += 1
        HotKey.actions[id] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let a = HotKey.actions[hkID.id] { DispatchQueue.main.async(execute: a) }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }

        let hkID = EventHotKeyID(signature: OSType(0x57464443 /* 'WFDC' */), id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hkID,
                                  GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.actions[id] = nil
    }
}
