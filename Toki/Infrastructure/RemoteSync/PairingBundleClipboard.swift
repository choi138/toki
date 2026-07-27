import AppKit
import Foundation

@MainActor
protocol PairingBundlePasteboard: AnyObject {
    var changeCount: Int { get }

    func prepareForPairingBundle()
    func setPairingBundle(_ bundle: String) -> Bool
    func setPrivacyMarker(_ type: NSPasteboard.PasteboardType) -> Bool
    func clearPairingBundle()
}

extension NSPasteboard: PairingBundlePasteboard {
    func prepareForPairingBundle() {
        declareTypes([.string, .tokiConcealed, .tokiTransient], owner: nil)
    }

    func setPairingBundle(_ bundle: String) -> Bool {
        setString(bundle, forType: .string)
    }

    func setPrivacyMarker(_ type: NSPasteboard.PasteboardType) -> Bool {
        setData(Data(), forType: type)
    }

    func clearPairingBundle() {
        clearContents()
    }
}

@MainActor
final class PairingBundleClipboard: PairingBundleCopying {
    private let pasteboard: any PairingBundlePasteboard
    private let retentionNanoseconds: UInt64
    private var clearTask: Task<Void, Never>?
    private var copiedPasteboardChangeCount: Int?

    init(
        pasteboard: any PairingBundlePasteboard = NSPasteboard.general,
        retentionNanoseconds: UInt64 = 60 * 1_000_000_000) {
        self.pasteboard = pasteboard
        self.retentionNanoseconds = retentionNanoseconds
    }

    func copy(_ bundle: String) throws {
        clearTask?.cancel()
        clearIfUnchanged()
        pasteboard.prepareForPairingBundle()
        guard pasteboard.setPairingBundle(bundle),
              pasteboard.setPrivacyMarker(.tokiConcealed),
              pasteboard.setPrivacyMarker(.tokiTransient) else {
            pasteboard.clearPairingBundle()
            throw RemoteSyncSettingsError.clipboardWriteFailed
        }
        let expectedChangeCount = pasteboard.changeCount
        copiedPasteboardChangeCount = expectedChangeCount
        let pasteboard = pasteboard
        let retentionNanoseconds = retentionNanoseconds
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: retentionNanoseconds)
            guard !Task.isCancelled else { return }
            self?.copiedPasteboardChangeCount = nil
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearPairingBundle()
        }
    }

    private func clearIfUnchanged() {
        defer { copiedPasteboardChangeCount = nil }
        guard let expectedChangeCount = copiedPasteboardChangeCount,
              pasteboard.changeCount == expectedChangeCount else {
            return
        }
        pasteboard.clearPairingBundle()
    }
}

private extension NSPasteboard.PasteboardType {
    static let tokiConcealed = Self("org.nspasteboard.ConcealedType")
    static let tokiTransient = Self("org.nspasteboard.TransientType")
}
