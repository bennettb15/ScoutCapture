import Foundation

struct SupabaseRuntimeConfiguration {
    enum Source: String, Equatable {
        case infoPlist = "info_plist"
        case environmentOverride = "environment_override"
        case invalidEnvironmentOverride = "invalid_environment_override"
    }

    enum TargetClassification: String, Equatable {
        case missing
        case invalid
        case localDev = "local_dev"
        case approvedStaging = "approved_staging"
        case approvedProductionValidation = "approved_production_validation"
        case remote
    }

    static let approvedSessionSnapshotStagingProjectRef = "hpekjqqiyurrewfjvjmn"
    static let productionSnapshotValidationProjectRef = "chlvazmtucoszicehtnm"
    static let productionSnapshotValidationEnvKey = "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_VALIDATION_ALLOWED"
    static let productionSnapshotHydrationEnvKey = "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_HYDRATION_ALLOWED"
    nonisolated static let productionSingleSessionCanonicalActivationEnabledEnvKey = "SCOUTCAPTURE_PRODUCTION_SINGLE_SESSION_CANONICAL_ACTIVATION_ENABLED"
    nonisolated static let productionSingleSessionCanonicalActivationOrgAllowlistEnvKey = "SCOUTCAPTURE_PRODUCTION_SINGLE_SESSION_CANONICAL_ACTIVATION_ORG_ALLOWLIST"
    nonisolated static let productionSingleSessionCanonicalActivationPropertyAllowlistEnvKey = "SCOUTCAPTURE_PRODUCTION_SINGLE_SESSION_CANONICAL_ACTIVATION_PROPERTY_ALLOWLIST"
    nonisolated static let productionSingleSessionCanonicalActivationSessionAllowlistEnvKey = "SCOUTCAPTURE_PRODUCTION_SINGLE_SESSION_CANONICAL_ACTIVATION_SESSION_ALLOWLIST"
    nonisolated static let canonicalReadCandidateEnabledEnvKey = "SCOUTCAPTURE_CANONICAL_READ_CANDIDATE_ENABLED"
    nonisolated static let canonicalReadCandidateOrgAllowlistEnvKey = "SCOUTCAPTURE_CANONICAL_READ_CANDIDATE_ORG_ALLOWLIST"
    nonisolated static let canonicalReadCandidatePropertyAllowlistEnvKey = "SCOUTCAPTURE_CANONICAL_READ_CANDIDATE_PROPERTY_ALLOWLIST"
    nonisolated static let canonicalReadCandidateSessionAllowlistEnvKey = "SCOUTCAPTURE_CANONICAL_READ_CANDIDATE_SESSION_ALLOWLIST"

    let url: URL?
    let anonKey: String?
    let source: Source
    let overrideURLRawValue: String?
    let overrideAnonKeyPresent: Bool
    let productionSnapshotValidationAllowed: Bool
    let productionSnapshotHydrationAllowed: Bool

    var isConfigured: Bool {
        url != nil && !(anonKey?.isEmpty ?? true)
    }

    var isOverrideActive: Bool {
        source == .environmentOverride || source == .invalidEnvironmentOverride
    }

    var targetClassification: TargetClassification {
        guard source != .invalidEnvironmentOverride else { return .invalid }
        guard let url else { return .missing }
        guard isConfigured else { return .invalid }
        let host = (url.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return .localDev
        }
        if host == "\(Self.approvedSessionSnapshotStagingProjectRef).supabase.co" {
            return .approvedStaging
        }
        if host == "\(Self.productionSnapshotValidationProjectRef).supabase.co",
           productionSnapshotValidationAllowed {
            return .approvedProductionValidation
        }
        return .remote
    }

    var isSafeLocalDevOverride: Bool {
        isOverrideActive && isConfigured && targetClassification == .localDev
    }

    var isSessionSnapshotShadowWriteOverrideAllowed: Bool {
        guard isConfigured else { return false }
        switch targetClassification {
        case .localDev, .approvedStaging:
            return isOverrideActive
        case .approvedProductionValidation:
            return true
        case .missing, .invalid, .remote:
            return false
        }
    }

    var isProductionSnapshotValidationManualOnly: Bool {
        targetClassification == .approvedProductionValidation
    }

    var isExactProductionSnapshotAutoUploadTarget: Bool {
        isExactProductionSnapshotHydrationTarget
    }

    var isExactProductionSnapshotHydrationTarget: Bool {
        guard let url else { return false }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "\(Self.productionSnapshotValidationProjectRef).supabase.co",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }

    var sanitizedURLDisplay: String {
        guard let url else {
            return overrideURLRawValue.map { "invalid:\(Self.sanitizedURLText($0))" } ?? "none"
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? Self.sanitizedURLText(url.absoluteString)
    }

    var redactedAnonKeyDisplay: String {
        guard let anonKey, !anonKey.isEmpty else {
            return overrideAnonKeyPresent ? "[invalid]" : "none"
        }
        if anonKey.count <= 10 {
            return "[redacted]"
        }
        return "\(anonKey.prefix(4))...\(anonKey.suffix(4))"
    }

    init(
        url: URL?,
        anonKey: String?,
        source: Source = .infoPlist,
        overrideURLRawValue: String? = nil,
        overrideAnonKeyPresent: Bool = false,
        productionSnapshotValidationAllowed: Bool = false,
        productionSnapshotHydrationAllowed: Bool = false
    ) {
        self.url = url
        self.anonKey = anonKey
        self.source = source
        self.overrideURLRawValue = overrideURLRawValue
        self.overrideAnonKeyPresent = overrideAnonKeyPresent
        self.productionSnapshotValidationAllowed = productionSnapshotValidationAllowed
        self.productionSnapshotHydrationAllowed = productionSnapshotHydrationAllowed
    }

    private static func sanitizedURLText(_ value: String) -> String {
        var components = URLComponents(string: value)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "[invalid-url]"
    }
}

enum CutoverPhase: String, CaseIterable {
    case phaseA = "phase_a"
    case phaseB = "phase_b"
    case phaseC = "phase_c"

    var displayName: String {
        switch self {
        case .phaseA:
            return "Phase A"
        case .phaseB:
            return "Phase B"
        case .phaseC:
            return "Phase C"
        }
    }

    var summary: String {
        switch self {
        case .phaseA:
            return "iCloud read/write"
        case .phaseB:
            return "iCloud read/write + Supabase metadata shadow-write"
        case .phaseC:
            return "Supabase canonical read/write + iCloud passive cache/DR"
        }
    }

    var logDescription: String {
        "\(displayName) (\(summary))"
    }
}

// 2C-08 rollback is operator-driven and restart-based. This catalog is only used to
// make the intended rollback posture explicit in startup logs.
enum CutoverRollbackTrigger: String, CaseIterable {
    case operatorFlagRollback = "operator_flag_rollback"
    case phaseBShadowWriteInstability = "phase_b_shadow_write_instability"
    case phaseCCanonicalPathInstability = "phase_c_canonical_path_instability"
    case unexpectedRemoteMetadataDivergence = "unexpected_remote_metadata_divergence"

    var summary: String {
        switch self {
        case .operatorFlagRollback:
            return "Operator changes cutover flags and restarts the app"
        case .phaseBShadowWriteInstability:
            return "Phase B metadata shadow-write failures or instability"
        case .phaseCCanonicalPathInstability:
            return "Phase C canonical Supabase read/write instability"
        case .unexpectedRemoteMetadataDivergence:
            return "Unexpected remote metadata divergence during cutover"
        }
    }

    static var restartCatalogForLogs: String {
        allCases.map { "\($0.rawValue)=\($0.summary)" }.joined(separator: " | ")
    }
}

struct BackendFeatureFlags {
    let supabaseEnabled: Bool
    let shadowWriteEnabled: Bool
    let supabaseReadEnabled: Bool
    let supabasePropertyReadEnabled: Bool
    let mediaSupabaseUploadEnabled: Bool
    let syncDeltaEnabled: Bool
    let sessionCoordinationEnabled: Bool
    let sessionSnapshotShadowWriteEnabled: Bool
    let sessionSnapshotAutoUploadEnabled: Bool
    let sessionSnapshotProductionAutoUploadTargetEnabled: Bool
    let sessionSnapshotAutoUploadKillSwitch: Bool
    let sessionSnapshotAutoUploadOrgAllowlist: Set<UUID>
    let sessionSnapshotAutoUploadPropertyAllowlist: Set<UUID>

    init(
        supabaseEnabled: Bool,
        shadowWriteEnabled: Bool,
        supabaseReadEnabled: Bool,
        supabasePropertyReadEnabled: Bool,
        mediaSupabaseUploadEnabled: Bool,
        syncDeltaEnabled: Bool,
        sessionCoordinationEnabled: Bool,
        sessionSnapshotShadowWriteEnabled: Bool = false,
        sessionSnapshotAutoUploadEnabled: Bool = false,
        sessionSnapshotProductionAutoUploadTargetEnabled: Bool = false,
        sessionSnapshotAutoUploadKillSwitch: Bool = false,
        sessionSnapshotAutoUploadOrgAllowlist: Set<UUID> = [],
        sessionSnapshotAutoUploadPropertyAllowlist: Set<UUID> = []
    ) {
        self.supabaseEnabled = supabaseEnabled
        self.shadowWriteEnabled = shadowWriteEnabled
        self.supabaseReadEnabled = supabaseReadEnabled
        self.supabasePropertyReadEnabled = supabasePropertyReadEnabled
        self.mediaSupabaseUploadEnabled = mediaSupabaseUploadEnabled
        self.syncDeltaEnabled = syncDeltaEnabled
        self.sessionCoordinationEnabled = sessionCoordinationEnabled
        self.sessionSnapshotShadowWriteEnabled = sessionSnapshotShadowWriteEnabled
        self.sessionSnapshotAutoUploadEnabled = sessionSnapshotAutoUploadEnabled
        self.sessionSnapshotProductionAutoUploadTargetEnabled = sessionSnapshotProductionAutoUploadTargetEnabled
        self.sessionSnapshotAutoUploadKillSwitch = sessionSnapshotAutoUploadKillSwitch
        self.sessionSnapshotAutoUploadOrgAllowlist = sessionSnapshotAutoUploadOrgAllowlist
        self.sessionSnapshotAutoUploadPropertyAllowlist = sessionSnapshotAutoUploadPropertyAllowlist
    }

    // The cutover phase is derived from the existing backend flags. Property-list
    // remote reads remain separately controlled by `supabase_property_read_enabled`
    // so the stabilized 2C-07 property refresh behavior is not coupled to phase.
    // `supabase_enabled` only indicates backend availability/bootstrap posture.
    // The actual A/B/C cutover meaning comes from `shadow_write_enabled` and
    // `supabase_read_enabled`.
    var cutoverPhase: CutoverPhase {
        if !supabaseEnabled {
            return .phaseA
        }
        if supabaseReadEnabled {
            return .phaseC
        }
        if shadowWriteEnabled {
            return .phaseB
        }
        return .phaseA
    }

    static func load(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowSessionSnapshotEnvironmentOverride: Bool = false,
        allowSessionSnapshotKillSwitchEnvironmentOverride: Bool = false
    ) -> BackendFeatureFlags {
        let preferSessionSnapshotBundleConfiguration = Self.preferSessionSnapshotBundleConfiguration(bundle: bundle)
        return BackendFeatureFlags(
            supabaseEnabled: Self.boolValue(for: "supabase_enabled", bundle: bundle, userDefaults: userDefaults),
            shadowWriteEnabled: Self.boolValue(for: "shadow_write_enabled", bundle: bundle, userDefaults: userDefaults),
            supabaseReadEnabled: Self.boolValue(for: "supabase_read_enabled", bundle: bundle, userDefaults: userDefaults),
            supabasePropertyReadEnabled: Self.boolValue(for: "supabase_property_read_enabled", bundle: bundle, userDefaults: userDefaults),
            mediaSupabaseUploadEnabled: Self.boolValue(for: "media_supabase_upload_enabled", bundle: bundle, userDefaults: userDefaults),
            syncDeltaEnabled: Self.boolValue(for: "sync_delta_enabled", bundle: bundle, userDefaults: userDefaults),
            sessionCoordinationEnabled: Self.boolValue(for: "session_coordination_enabled", bundle: bundle, userDefaults: userDefaults),
            sessionSnapshotShadowWriteEnabled: Self.sessionSnapshotShadowWriteValue(
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                allowEnvironmentOverride: allowSessionSnapshotEnvironmentOverride,
                preferBundleConfiguration: preferSessionSnapshotBundleConfiguration
            ),
            sessionSnapshotAutoUploadEnabled: Self.sessionSnapshotAutoUploadValue(
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                preferBundleConfiguration: preferSessionSnapshotBundleConfiguration
            ),
            sessionSnapshotProductionAutoUploadTargetEnabled: Self.boolValue(
                for: "session_snapshot_production_auto_upload_target_enabled",
                environmentKey: "SCOUTCAPTURE_SESSION_SNAPSHOT_PRODUCTION_AUTO_UPLOAD_TARGET_ENABLED",
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                preferBundleValueOverUserDefaults: preferSessionSnapshotBundleConfiguration
            ),
            sessionSnapshotAutoUploadKillSwitch: Self.sessionSnapshotAutoUploadKillSwitchValue(
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                allowEnvironmentOverride: allowSessionSnapshotKillSwitchEnvironmentOverride,
                preferBundleConfiguration: preferSessionSnapshotBundleConfiguration
            ),
            sessionSnapshotAutoUploadOrgAllowlist: Self.uuidAllowlistValue(
                for: "session_snapshot_auto_upload_org_allowlist",
                environmentKey: "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ORG_ALLOWLIST",
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                preferBundleValueOverUserDefaults: preferSessionSnapshotBundleConfiguration
            ),
            sessionSnapshotAutoUploadPropertyAllowlist: Self.uuidAllowlistValue(
                for: "session_snapshot_auto_upload_property_allowlist",
                environmentKey: "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_PROPERTY_ALLOWLIST",
                bundle: bundle,
                userDefaults: userDefaults,
                environment: environment,
                preferBundleValueOverUserDefaults: preferSessionSnapshotBundleConfiguration
            )
        )
    }

    var sessionSnapshotAutoUploadHasAllowlist: Bool {
        !sessionSnapshotAutoUploadOrgAllowlist.isEmpty || !sessionSnapshotAutoUploadPropertyAllowlist.isEmpty
    }

    private static func sessionSnapshotShadowWriteValue(
        bundle: Bundle,
        userDefaults: UserDefaults,
        environment: [String: String],
        allowEnvironmentOverride: Bool,
        preferBundleConfiguration: Bool
    ) -> Bool {
        let configuredValue = Self.boolValue(
            for: "session_snapshot_shadow_write_enabled",
            bundle: bundle,
            userDefaults: userDefaults,
            preferBundleValueOverUserDefaults: preferBundleConfiguration
        )

        #if DEBUG
        guard allowEnvironmentOverride else { return configuredValue }
        #else
        guard AppStateTestEnvironment.isRunningUnderXCTest, allowEnvironmentOverride else { return configuredValue }
        #endif

        guard let rawOverride = environment["session_snapshot_shadow_write_enabled"]
            ?? environment["SCOUTCAPTURE_SESSION_SNAPSHOT_SHADOW_WRITE_ENABLED"] else {
            return configuredValue
        }

        return Self.parsedBoolean(rawOverride) ?? configuredValue
    }

    private static func sessionSnapshotAutoUploadValue(
        bundle: Bundle,
        userDefaults: UserDefaults,
        environment: [String: String],
        preferBundleConfiguration: Bool
    ) -> Bool {
        let configuredValue = Self.boolValue(
            for: "session_snapshot_auto_upload_enabled",
            bundle: bundle,
            userDefaults: userDefaults,
            preferBundleValueOverUserDefaults: preferBundleConfiguration
        )

        guard let rawOverride = environment["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED"] else {
            return configuredValue
        }

        return Self.parsedBoolean(rawOverride) ?? configuredValue
    }

    private static func sessionSnapshotAutoUploadKillSwitchValue(
        bundle: Bundle,
        userDefaults: UserDefaults,
        environment: [String: String],
        allowEnvironmentOverride: Bool,
        preferBundleConfiguration: Bool
    ) -> Bool {
        let configuredValue = Self.boolValue(
            for: "session_snapshot_auto_upload_kill_switch",
            bundle: bundle,
            userDefaults: userDefaults,
            preferBundleValueOverUserDefaults: preferBundleConfiguration
        )

        guard allowEnvironmentOverride else { return configuredValue }
        guard let rawOverride = environment["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH"] else {
            return configuredValue
        }
        return Self.parsedBoolean(rawOverride) ?? configuredValue
    }

    private static func uuidAllowlistValue(
        for key: String,
        environmentKey: String,
        bundle: Bundle,
        userDefaults: UserDefaults,
        environment: [String: String],
        preferBundleValueOverUserDefaults: Bool = false
    ) -> Set<UUID> {
        if let rawValue = environment[environmentKey] {
            return Self.uuidSet(from: rawValue)
        }
        if preferBundleValueOverUserDefaults,
           let bundleValue = Self.uuidAllowlistBundleValue(for: key, bundle: bundle) {
            return bundleValue
        }
        if let rawValue = userDefaults.string(forKey: key) {
            return Self.uuidSet(from: rawValue)
        }
        if let rawValues = userDefaults.array(forKey: key) as? [String] {
            return Set(rawValues.compactMap { UUID(uuidString: $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) })
        }
        return Self.uuidAllowlistBundleValue(for: key, bundle: bundle) ?? []
    }

    private static func uuidAllowlistBundleValue(for key: String, bundle: Bundle) -> Set<UUID>? {
        if let rawValue = bundle.object(forInfoDictionaryKey: key) as? String {
            return Self.uuidSet(from: rawValue)
        }
        if let rawValues = bundle.object(forInfoDictionaryKey: key) as? [String] {
            return Set(rawValues.compactMap { UUID(uuidString: $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) })
        }
        return nil
    }

    private static func uuidSet(from rawValue: String) -> Set<UUID> {
        let parts = rawValue
            .split { character in
                character == "," || character == ";" || character == "\n" || character == "\t" || character == " "
            }
        return Set(parts.compactMap { part in
            UUID(uuidString: String(part).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        })
    }

    private static func parsedBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func boolValue(
        for key: String,
        environmentKey: String,
        bundle: Bundle,
        userDefaults: UserDefaults,
        environment: [String: String],
        preferBundleValueOverUserDefaults: Bool = false
    ) -> Bool {
        if let rawValue = environment[environmentKey],
           let override = Self.parsedBoolean(rawValue) {
            return override
        }
        return Self.boolValue(
            for: key,
            bundle: bundle,
            userDefaults: userDefaults,
            preferBundleValueOverUserDefaults: preferBundleValueOverUserDefaults
        )
    }

    private static func boolValue(
        for key: String,
        bundle: Bundle,
        userDefaults: UserDefaults,
        preferBundleValueOverUserDefaults: Bool = false
    ) -> Bool {
        if preferBundleValueOverUserDefaults,
           let bundleValue = Self.boolBundleValue(for: key, bundle: bundle) {
            return bundleValue
        }

        if userDefaults.object(forKey: key) != nil {
            return userDefaults.bool(forKey: key)
        }

        return Self.boolBundleValue(for: key, bundle: bundle) ?? false
    }

    private static func boolBundleValue(for key: String, bundle: Bundle) -> Bool? {
        if let number = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return number.boolValue
        }

        if let string = bundle.object(forInfoDictionaryKey: key) as? String {
            return Self.parsedBoolean(string) ?? false
        }

        return nil
    }

    private static func preferSessionSnapshotBundleConfiguration(bundle: Bundle) -> Bool {
        boolBundleValue(
            for: "session_snapshot_production_auto_upload_target_enabled",
            bundle: bundle
        ) == true
    }
}

