import Darwin
import Foundation
import MachO
import MinuitCore

/// Capture minimale des plantages, sans service externe.
///
/// - Exceptions Objective-C non rattrapées : nom, raison et pile, écrits en Swift.
/// - Signaux fatals (erreur Swift, accès mémoire…) : gestionnaire réduit aux appels
///   sûrs (`open`, `write`, `backtrace_symbols_fd`), qui écrit la pile brute et le
///   décalage de chargement de l'exécutable (pour symbolisation avec le dSYM).
///
/// Au lancement suivant, le rapport est versé dans le journal de diagnostic et affiché
/// dans Réglages → Diagnostics. Aucune donnée ne quitte l'appareil.
enum CrashReporter {
    private(set) static var lastReport: String?

    static var reportURL: URL {
        FileCache.applicationCaches().directory.appendingPathComponent("last-crash.txt")
    }

    @MainActor
    static func install() {
        let url = reportURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? String(contentsOf: url, encoding: .utf8), !previous.isEmpty {
            lastReport = previous
            DiagnosticsLog.shared.log(.error, "plantage", "Fermeture inattendue lors de la session précédente :\n\(previous.prefix(4000))")
            try? FileManager.default.removeItem(at: url)
        }

        crashPath = strdup(url.path)
        frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let slide = _dyld_get_image_vmaddr_slide(0)
        let header = "Minuit \(version) (\(build)) — décalage de chargement 0x\(String(slide, radix: 16))\n"
        headerText = strdup(header)

        NSSetUncaughtExceptionHandler { exception in
            let text = """
            Exception : \(exception.name.rawValue)
            Raison : \(exception.reason ?? "?")
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            if let path = crashPath {
                try? text.write(toFile: String(cString: path), atomically: false, encoding: .utf8)
            }
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
    }
}

// État global préparé à l'installation : le gestionnaire de signal n'alloue rien.
nonisolated(unsafe) private var crashPath: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var headerText: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private let maxFrames: Int32 = 64

private func crashSignalHandler(_ sig: Int32) {
    if let path = crashPath, let frames {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            if let headerText { _ = write(fd, headerText, strlen(headerText)) }
            // « Signal NN »
            var buffer: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
                (83, 105, 103, 110, 97, 108, 32, 48, 48, 10, 0) // "Signal 00\n"
            buffer.7 = CChar(48 + (sig / 10) % 10)
            buffer.8 = CChar(48 + sig % 10)
            withUnsafePointer(to: &buffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 11) { _ = write(fd, $0, 10) }
            }
            let count = backtrace(frames, maxFrames)
            backtrace_symbols_fd(frames, count, fd)
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
