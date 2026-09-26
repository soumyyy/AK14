import Foundation

/// What the participant is told before any thumbnail leaves the machine (spec §10.5). Kept in sync with docs/study/consent.md.
public enum Disclosure {
    public static let version = "disclosure-1"
    public static let text = """
    Before AK14 asks the AI model for help, here is exactly what leaves this Mac:
      • Small, low-resolution copies (160–384 px) of up to about 100 of the photos AK14 shortlisted.
        Your original photos, GPS coordinates and file names are never sent.
      • Short text notes about those photos (time within the event, number of faces, scene labels).
    They go to OpenAI's API (model gpt-6-luna) only to choose and arrange photos for your carousel.
    OpenAI does not train on API data by default and may keep it for up to 30 days for abuse monitoring.
    Everything else (analysis, rendering, the report) stays on this Mac. You can ask for your run to be deleted at any time.
    """
}

public struct Consent: Codable, Sendable, Equatable {
    public var acknowledgedAt: Date
    public var disclosureVersion: String
    public init(acknowledgedAt: Date, disclosureVersion: String) {
        self.acknowledgedAt = acknowledgedAt; self.disclosureVersion = disclosureVersion
    }
}

public enum StudyCode {
    /// Pseudonymous participant code: letters, digits, '-' or '_', 1–16 characters. Never a name.
    public static func isValid(_ code: String) -> Bool { code.wholeMatch(of: /[A-Za-z0-9_-]{1,16}/) != nil }
}
