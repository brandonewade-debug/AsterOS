import SwiftUI
import LocalAuthentication
import Security
import CommonCrypto

struct AppLockRecord: Codable {
    let salt: Data
    let verifier: Data
    var biometrics: Bool
    var biometricDomain: Data?
    var failures = 0
    var retryAfter: Date?
}
enum PINProtection {
    static func valid(_ pin: String) -> Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    static func derive(_ pin: String, salt: Data) throws -> Data {
        guard valid(pin), salt.count == 32 else { throw AppError.message("Enter a six-digit PIN.") }
        var output = [UInt8](repeating: 0, count: 32)
        let status = pin.withCString { password in salt.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count, bytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &output, output.count)
        } }
        guard status == kCCSuccess else { throw AppError.message("Could not secure this PIN.") }
        return Data(output)
    }
    static func matches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func delay(failures: Int) -> TimeInterval { failures < 5 ? 0 : min(3600, 30 * pow(2, Double(min(failures - 5, 7)))) }
}
struct AppLockStorage {
    var read: () throws -> Data?
    var write: (Data) throws -> Void
    var remove: () throws -> Void
    static var keychain: Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AsterOS.AppLock", kSecAttrAccount as String: "device-lock"]
        return Self(read: {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw AppError.message("Could not read app security from Keychain. Unlock your device and retry.") }
            return data
        }, write: { data in
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Could not save app security to Keychain.") }
            } else if status != errSecSuccess { throw AppError.message("Could not update app security in Keychain.") }
        }, remove: {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Could not remove app security from Keychain.") }
        })
    }
}
@MainActor final class AppLockStore: ObservableObject {
    @Published private(set) var record: AppLockRecord?
    @Published private(set) var locked = true
    @Published private(set) var shield = false
    @Published private(set) var authenticating = false
    @Published private(set) var storageFailed = false
    @Published var error: String?
    private let storage: AppLockStorage
    private var context: LAContext?
    private var generation = UUID()
    var enabled: Bool { record != nil || storageFailed }
    var biometricName: String {
        let context = LAContext(); _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }
    var biometricSymbol: String { biometricName == "Touch ID" ? "touchid" : "faceid" }
    init(storage: AppLockStorage = .keychain) { self.storage = storage; reload() }
    func reload() {
        do {
            record = try storage.read().map { try JSONDecoder().decode(AppLockRecord.self, from: $0) }
            if let record, record.salt.count != 32 || record.verifier.count != 32 { throw AppError.message("Saved app security could not be read.") }
            storageFailed = false; locked = record != nil; error = nil
        } catch { storageFailed = true; locked = true; self.error = "App security could not be read. Unlock your device and retry." }
    }
    private func save(_ value: AppLockRecord) throws { try storage.write(JSONEncoder().encode(value)); record = value }
    func sceneChanged(_ phase: ScenePhase) {
        shield = enabled && phase != .active
        if phase == .background { lock() }
    }
    func lock() {
        guard enabled else { return }
        generation = UUID(); context?.invalidate(); context = nil; authenticating = false; locked = true; error = nil
    }
    func setPIN(_ pin: String, oldPIN: String?) throws {
        guard !storageFailed, !locked else { throw AppError.message("Unlock AsterOS first.") }
        if record != nil { guard let oldPIN, try verifyPIN(oldPIN) else { throw AppError.message(error ?? "Incorrect current PIN.") } }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppError.message("Could not create secure PIN settings.") }
        let value = AppLockRecord(salt: salt, verifier: try PINProtection.derive(pin, salt: salt), biometrics: false)
        try save(value); error = nil
        // Biometrics is enabled separately after successful system authentication.
    }
    @discardableResult func verifyPIN(_ pin: String, now: Date = Date()) throws -> Bool {
        guard var value = record, !storageFailed else { return false }
        if let date = value.retryAfter, date > now { error = "Too many attempts. Try again in \(Int(ceil(date.timeIntervalSince(now)))) seconds."; return false }
        guard PINProtection.valid(pin) else { error = "Enter your six-digit PIN."; return false }
        let valid = PINProtection.matches(try PINProtection.derive(pin, salt: value.salt), value.verifier)
        if valid { value.failures = 0; value.retryAfter = nil }
        else { value.failures = min(value.failures + 1, 100); let delay = PINProtection.delay(failures: value.failures); value.retryAfter = delay > 0 ? now.addingTimeInterval(delay) : nil }
        try save(value)
        error = valid ? nil : (value.retryAfter == nil ? "Incorrect PIN." : "Too many attempts. Please wait before trying again.")
        return valid
    }
    func unlockPIN(_ pin: String) {
        do { if try verifyPIN(pin) { locked = false } }
        catch { self.error = "Could not verify app security securely. Please retry." }
    }
    func disable(pin: String) throws {
        guard !locked, try verifyPIN(pin) else { throw AppError.message(error ?? "Enter the current PIN.") }
        try storage.remove(); record = nil; locked = false; shield = false; error = nil
    }
    func useBiometrics(enabling: Bool = false) async {
        guard !authenticating, !storageFailed, let current = record, enabling ? !locked : current.biometrics else { return }
        let revision = generation
        let auth = LAContext(); auth.localizedFallbackTitle = "Use PIN"
        guard auth.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { error = "\(biometricName) is unavailable. Use your PIN or set up biometrics in device Settings."; return }
        if !enabling, current.biometricDomain == nil || current.biometricDomain != auth.evaluatedPolicyDomainState { error = "Biometric settings changed. Unlock with your PIN, then enable biometrics again."; return }
        context = auth; authenticating = true
        defer { if generation == revision { authenticating = false; context = nil } }
        do {
            let accepted = try await auth.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: enabling ? "Enable biometric unlock for AsterOS" : "Unlock AsterOS")
            guard accepted, revision == generation, var value = record else { return }
            value.failures = 0; value.retryAfter = nil
            if enabling { value.biometrics = true; value.biometricDomain = auth.evaluatedPolicyDomainState }
            try save(value); locked = false; error = nil
        } catch { if revision == generation { self.error = "Biometric authentication did not complete. You can use your PIN." } }
    }
    func disableBiometrics() {
        guard !locked, var value = record else { return }
        value.biometrics = false; value.biometricDomain = nil
        do { try save(value) } catch { self.error = "Could not save biometric settings." }
    }
}
struct AppUnlockView: View {
    @ObservedObject var lock: AppLockStore
    @State private var pin = ""
    var body: some View {
        ZStack {
            AsterBackdrop()
            if !lock.shield {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.mint)
                    Text("Unlock AsterOS").font(.largeTitle.bold())
                    if lock.storageFailed { Button("Retry security settings") { lock.reload() } }
                    else {
                        SecureField("Six-digit PIN", text: $pin).keyboardType(.numberPad).textContentType(.password).textFieldStyle(AsterTextFieldStyle()).frame(maxWidth: 300)
                            .onChange(of: pin) { _, value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                        Button("Unlock") { lock.unlockPIN(pin); pin = "" }.buttonStyle(.borderedProminent).disabled(!PINProtection.valid(pin) || lock.authenticating)
                        if lock.record?.biometrics == true { Button { Task { await lock.useBiometrics() } } label: { Label("Use " + lock.biometricName, systemImage: lock.biometricSymbol) }.disabled(lock.authenticating) }
                    }
                    if let error = lock.error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                }.padding(28)
            } else { Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.mint) }
        }.preferredColorScheme(.dark).tint(.mint)
        .onChange(of: lock.shield) { _, covered in if covered { pin = "" } }
    }
}
// A separate scene window covers every presented sheet/browser, not just the root view.
struct AppSecurityWindow: UIViewRepresentable {
    @ObservedObject var lock: AppLockStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SecurityProbe {
        let view = SecurityProbe(frame: .zero)
        let coordinator = context.coordinator
        view.attached = { [weak view] in if let view { coordinator.update(view: view, lock: lock) } }
        return view
    }
    func updateUIView(_ view: SecurityProbe, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { coordinator.update(view: view, lock: lock) }
    }
    static func dismantleUIView(_ view: SecurityProbe, coordinator: Coordinator) { coordinator.clear() }
    final class SecurityProbe: UIView {
        var attached: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { attached?() } }
    }
    @MainActor final class Coordinator {
        var cover: UIWindow?
        weak var previous: UIWindow?
        func update(view: UIView, lock: AppLockStore) {
            guard let parent = view.window, let scene = parent.windowScene else { return }
            guard lock.locked || lock.shield else { clear(); return }
            if cover == nil {
                previous = parent
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.rootViewController = UIHostingController(rootView: AppUnlockView(lock: lock))
                cover = window; window.makeKeyAndVisible()
            }
        }
        func clear() { cover?.isHidden = true; cover?.rootViewController = nil; cover = nil; previous?.makeKey(); previous = nil }
    }
}
struct AppSecuritySettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var lock: AppLockStore
    @State private var mode: String?
    @State private var current = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    var body: some View {
        GlassForm {
            Section("App lock") {
                Label(lock.enabled ? "App lock is on" : "App lock is off", systemImage: lock.enabled ? "lock.fill" : "lock.open")
                Text("Optional protection for this device. When enabled, AsterOS locks on launch and whenever it goes into the background.").font(.caption).foregroundStyle(.secondary)
                if lock.enabled {
                    Button("Change PIN") { begin("Change PIN") }
                    Button("Turn off app lock", role: .destructive) { begin("Turn off app lock") }
                    Toggle("Use " + lock.biometricName, isOn: Binding(get: { lock.record?.biometrics == true }, set: { enabled in if enabled { Task { await lock.useBiometrics(enabling: true) } } else { lock.disableBiometrics() } })).disabled(lock.authenticating)
                    Button("Lock now") { lock.lock() }
                } else { Button("Set up PIN") { begin("Set up PIN") } }
                if let error = lock.error { Text(error).foregroundStyle(.orange).font(.caption) }
            }
        }.navigationTitle("App security")
        .onChange(of: scenePhase) { _, phase in if phase == .background { mode = nil; clear() } }
        .sheet(isPresented: Binding(get: { mode != nil }, set: { if !$0 { mode = nil; clear() } })) {
            NavigationStack {
                GlassForm {
                    Section {
                        if lock.enabled { SecureField("Current PIN", text: $current).keyboardType(.numberPad) }
                        if mode != "Turn off app lock" {
                            SecureField("New six-digit PIN", text: $pin).keyboardType(.numberPad)
                            SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad)
                            Text("Remember this PIN. There is no email reset. Biometric unlock can provide access while it remains available.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let message { Text(message).foregroundStyle(.orange) }
                        Button(mode ?? "Save") { save() }.buttonStyle(.borderedProminent)
                    }
                }.navigationTitle(mode ?? "PIN").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { mode = nil; clear() } }
            }.interactiveDismissDisabled()
        }
    }
    private func begin(_ value: String) { clear(); mode = value }
    private func clear() { current = ""; pin = ""; confirmation = ""; message = nil }
    private func save() {
        do {
            if mode == "Turn off app lock" { try lock.disable(pin: current) }
            else {
                guard PINProtection.valid(pin), pin == confirmation else { message = "Enter matching six-digit PINs."; return }
                try lock.setPIN(pin, oldPIN: lock.enabled ? current : nil)
            }
            mode = nil; clear()
        } catch { message = error.localizedDescription; current = "" }
    }
}
