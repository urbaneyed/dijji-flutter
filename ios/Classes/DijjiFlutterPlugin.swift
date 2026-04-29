import Flutter
import UIKit
import Darwin

/// iOS side of `package:dijji`. Two responsibilities:
///
/// 1. **Native crash capture** — install both `NSSetUncaughtExceptionHandler`
///    (Objective-C exceptions) and POSIX signal handlers (pure-Swift crashes
///    like `fatalError`, forced unwrap of nil, array OOB). On crash, write a
///    minimal JSON marker to disk; next launch detects + forwards it to Dart.
///
/// 2. **Mark this side as "fetchInstallReferrer = unsupported"** — the iOS
///    App Store has no equivalent install-attribution API the way Play does,
///    so the Dart fetchInstallReferrer call returns null on iOS and the
///    SDK's caller skips the /t/app/install POST. Honest no-op.
///
/// Method-channel contract (matches DijjiFlutterPlugin.kt):
///   "installCrashHandler"  → null. Idempotent.
///   "fetchInstallReferrer" → null on iOS. (Caller checks for null.)
///   "drainPendingCrash"    → Map | null. On next launch, returns any marker
///                            written during the previous crash. Plugin
///                            removes the marker after returning so we don't
///                            re-deliver.
public class DijjiFlutterPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dijji/native", binaryMessenger: registrar.messenger())
        let instance = DijjiFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "installCrashHandler":
            DijjiCrashCatcher.install()
            result(nil)
        case "fetchInstallReferrer":
            // Apple has no public install-referrer API. SKAdNetwork is for
            // ad-attribution, scoped to the ad network; not the same surface
            // as Play's installreferrer. Honest null.
            result(nil)
        case "drainPendingCrash":
            result(DijjiCrashCatcher.drainPendingCrash())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Crash capture, signal-safe. Mirrors the proven `dijji-ios` SignalHandler
/// pattern — write a minimal marker inside the handler (signal-safe APIs
/// only), parse-and-forward on next launch.
enum DijjiCrashCatcher {

    private static let signalsToCatch: [Int32] = [
        SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP,
    ]

    /// Pre-allocated null-terminated C string with the crash dump path.
    /// Must exist before the signal fires — String allocation isn't safe
    /// from inside the handler.
    private static var crashFileCPath: UnsafeMutablePointer<CChar>?
    private static var installed = false
    private static var previousNSExceptionHandler: NSUncaughtExceptionHandler?

    static func install() {
        guard !installed else { return }
        installed = true

        // Resolve the marker path once and pin it as a C string.
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = (docs as NSString).appendingPathComponent("dijji-flutter-crash.json")
        let utf8 = path.utf8CString
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
        utf8.withUnsafeBufferPointer { src in
            buf.update(from: src.baseAddress!, count: utf8.count)
        }
        crashFileCPath = buf

        // ── NSException ─────────────────────────────────────────
        previousNSExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // We're back on a regular runtime here (NSException is on the main
            // thread, runtime intact), so we can use Foundation.
            let report: [String: Any] = [
                "type": exception.name.rawValue,
                "reason": exception.reason ?? "",
                "stack": exception.callStackSymbols.joined(separator: "\n"),
                "platform": "ios",
                "kind": "nsexception",
                "ts": Int(Date().timeIntervalSince1970),
            ]
            DijjiCrashCatcher.writeMarkerSync(report)
            // Chain so other reporters / OS still get a chance.
            previousNSExceptionHandler?(exception)
        }

        // ── POSIX signals ───────────────────────────────────────
        for sig in signalsToCatch {
            var action = sigaction()
            action.sa_flags = SA_NODEFER | SA_RESETHAND
            #if canImport(Darwin)
            action.__sigaction_u = __sigaction_u(__sa_handler: signalCallback)
            #endif
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    /// On the next launch (typically inside Dijji.initialize → Dart calls
    /// "drainPendingCrash"), read the marker, return it as a Dart-friendly
    /// dictionary, then delete it.
    static func drainPendingCrash() -> [String: Any]? {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let path = (docs as NSString).appendingPathComponent("dijji-flutter-crash.json")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parsed
    }

    /// Foundation-level marker writer for NSException path. Safe to use
    /// JSON encoding here — runtime is intact during the NSException callback.
    private static func writeMarkerSync(_ report: [String: Any]) {
        guard let pathPtr = crashFileCPath,
              let path = String(validatingUTF8: pathPtr),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// POSIX signal handler. ASYNC-SIGNAL-SAFE ONLY — no String, no malloc,
    /// no Foundation. We pre-allocate the path and write a tiny JSON blob
    /// using only write(2) / open(2) / close(2).
    private static let signalCallback: @convention(c) (Int32) -> Void = { sig in
        guard let pathPtr = crashFileCPath else {
            signal(sig, SIG_DFL)
            raise(sig)
            return
        }
        let fd = open(pathPtr, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        if fd >= 0 {
            writeRawString(fd, "{\"signal\":")
            writeRawInt(fd, Int(sig))
            writeRawString(fd, ",\"name\":\"")
            writeRawString(fd, signalNameC(sig))
            writeRawString(fd, "\",\"platform\":\"ios\",\"kind\":\"signal\",\"ts\":")
            writeRawInt(fd, Int(time(nil)))
            writeRawString(fd, "}\n")
            close(fd)
        }
        // Re-raise so OS / Xcode / other reporters still see the crash.
        raise(sig)
    }

    private static func writeRawInt(_ fd: Int32, _ v: Int) {
        if v == 0 { _ = write(fd, "0", 1); return }
        var n = v
        let neg = n < 0
        if neg { n = -n }
        var buf = [CChar](repeating: 0, count: 24)
        var i = buf.count - 1
        while n > 0 {
            buf[i] = CChar(0x30 + (n % 10))
            n /= 10
            i -= 1
        }
        if neg { buf[i] = 0x2D; i -= 1 }
        let start = i + 1
        let len = buf.count - start
        buf.withUnsafeBufferPointer { p in
            _ = write(fd, p.baseAddress!.advanced(by: start), len)
        }
    }

    private static func writeRawString(_ fd: Int32, _ s: UnsafePointer<CChar>) {
        _ = write(fd, s, strlen(s))
    }

    private static func signalNameC(_ sig: Int32) -> UnsafePointer<CChar> {
        switch sig {
        case SIGABRT: return UnsafePointer<CChar>(strdup("SIGABRT"))
        case SIGILL:  return UnsafePointer<CChar>(strdup("SIGILL"))
        case SIGSEGV: return UnsafePointer<CChar>(strdup("SIGSEGV"))
        case SIGFPE:  return UnsafePointer<CChar>(strdup("SIGFPE"))
        case SIGBUS:  return UnsafePointer<CChar>(strdup("SIGBUS"))
        case SIGTRAP: return UnsafePointer<CChar>(strdup("SIGTRAP"))
        default:      return UnsafePointer<CChar>(strdup("UNKNOWN"))
        }
    }
}
