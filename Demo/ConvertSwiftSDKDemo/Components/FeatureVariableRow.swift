import ConvertSwiftSDK
import SwiftUI

/// One typed feature-variable row for the demo's Features screen (Story 7.4).
///
/// Renders a single variable as **name (body) · type chip (caption, neutral) ·
/// value (SF Mono)**. The type chip carries the *type name as text* — color is
/// never the only channel — using the same neutral soft-fill pattern as the
/// `queued`/`info` states of `StatusBadge` (`secondarySystemFill` fill +
/// `secondaryLabel` text), with an optional decorative SF Symbol hidden from
/// VoiceOver. The mono value wraps and never truncates (JSON especially), and
/// the whole row fuses into one VoiceOver element naming **name, type, value**.
///
/// The honest headline behavior of the screen is the **absent** rendition: when
/// a feature returns no value for a variable, the row shows the *expected* type
/// in the chip, an em-dash value, and a neutral muted note — deliberately
/// distinct from an error (no error hue), because a missing value is a normal
/// state, not a failure.
///
/// All visual differences (chip text, mono value, muted note) are owned by the
/// `Presentation` enum's per-case computed properties — mirroring
/// `ResultCard.Variant` / `StatusBadge.Style` — so `FeatureVariableRow` reads
/// every channel generically and never switches on the case itself.
struct FeatureVariableRow: View {

    /// What the row renders: the five SDK `FeatureVariable` cases mapped to their
    /// display form, plus an `absent` case for "the feature returned nil for this
    /// variable". Each case's computed properties own the chip text, the SF Mono
    /// value string, and the optional muted note, so the view body stays generic.
    enum Presentation {
        /// A boolean variable → chip "bool", value "true"/"false".
        case boolean(Bool)
        /// An integer variable → chip "int", value the decimal integer.
        case integer(Int)
        /// A floating-point variable → chip "float", value the decimal double.
        case float(Double)
        /// A string variable → chip "string", value the string verbatim.
        case string(String)
        /// A JSON variable → chip "json", value the pretty-printed JSON (sorted
        /// keys); on any decode/serialize failure the value falls back to the
        /// muted note "invalid JSON" with an em-dash value.
        case json(Data)
        /// No value for this variable → chip shows the *expected* type, value is
        /// an em-dash, plus a neutral muted note. Not an error — a normal state.
        case absent(expectedType: String)

        /// Em-dash shown as the value when there is nothing to render (absent, or
        /// JSON that could not be decoded).
        private static let emDash = "—"

        /// Type-name text rendered inside the chip. This is the load-bearing
        /// signal — the chip's color is identical for every type, so the *word*
        /// carries the type. For `.absent` it is the expected type so the row
        /// still tells you what the variable *should* be.
        var typeName: String {
            switch self {
            case .boolean: return "bool"
            case .integer: return "int"
            case .float: return "float"
            case .string: return "string"
            case .json: return "json"
            case let .absent(expectedType): return expectedType
            }
        }

        /// The SF Mono value string. Booleans render "true"/"false"; numbers via
        /// `String(_:)`; strings verbatim; JSON pretty-printed (or an em-dash when
        /// it cannot be decoded); absent an em-dash.
        var monoValue: String {
            switch self {
            case let .boolean(value): return value ? "true" : "false"
            case let .integer(value): return String(value)
            case let .float(value): return String(value)
            case let .string(value): return value
            case let .json(data): return Self.prettyJSON(from: data) ?? Self.emDash
            case .absent: return Self.emDash
            }
        }

        /// A neutral, secondary muted note rendered under the value, or `nil` when
        /// there is none. Present for `.absent` (the honest "no value" line) and
        /// for `.json` that failed to decode ("invalid JSON"). Never an error hue.
        var note: String? {
            switch self {
            case .boolean, .integer, .float, .string:
                return nil
            case let .json(data):
                return Self.prettyJSON(from: data) == nil ? "invalid JSON" : nil
            case .absent:
                return "no value — feature returned nil for this variable"
            }
        }

        /// The value fragment spoken by VoiceOver. Present cases speak the mono
        /// value; absent speaks "no value" so the state survives without sight.
        var accessibilityValue: String {
            switch self {
            case .absent: return "no value"
            default: return monoValue
            }
        }

        /// Pretty-prints raw JSON `Data` with sorted keys, returning `nil` on any
        /// failure (invalid JSON, non-serializable object, non-UTF-8 output).
        /// No force-unwraps anywhere: every fallible step uses `try?` / `guard`.
        private static func prettyJSON(from data: Data) -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let string = String(data: pretty, encoding: .utf8) else {
                return nil
            }
            return string
        }
    }

    /// The variable's display name (e.g. "buttonColor").
    private let name: String

    /// What the row renders — type, value, and any muted note all flow from this.
    private let presentation: Presentation

    /// Larger Dynamic Type sizes stack the value below the name+chip so the mono
    /// value (JSON especially) gets the full width and wraps instead of crowding
    /// a single line. `dynamicTypeSize` + `isAccessibilitySize` are iOS 15+.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Builds a row from an SDK `FeatureVariable`, mapping every case to its
    /// `Presentation` form (exhaustive — no `default`).
    ///
    /// - Parameters:
    ///   - name: The variable's display name.
    ///   - variable: The resolved SDK variable to render.
    init(name: String, variable: FeatureVariable) {
        self.name = name
        switch variable {
        case let .boolean(value): self.presentation = .boolean(value)
        case let .integer(value): self.presentation = .integer(value)
        case let .float(value): self.presentation = .float(value)
        case let .string(value): self.presentation = .string(value)
        case let .json(data): self.presentation = .json(data)
        }
    }

    /// Builds the honest **absent** row — the feature returned no value for this
    /// variable. The chip shows the expected type; the value is an em-dash with a
    /// neutral muted note.
    ///
    /// - Parameters:
    ///   - name: The variable's display name.
    ///   - absentType: The type the variable was expected to be (chip text).
    init(name: String, absentType: String) {
        self.name = name
        self.presentation = .absent(expectedType: absentType)
    }

    /// Builds a row directly from a `Presentation` (e.g. for previews).
    ///
    /// - Parameters:
    ///   - name: The variable's display name.
    ///   - presentation: The pre-mapped presentation to render.
    init(name: String, presentation: Presentation) {
        self.name = name
        self.presentation = presentation
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Accessibility sizes: name+chip on top, value (and note) below,
                // so the mono value gets the full width and wraps cleanly.
                VStack(alignment: .leading, spacing: ConvertTheme.space1) {
                    HStack(alignment: .firstTextBaseline, spacing: ConvertTheme.space2) {
                        nameLabel
                        typeChip
                    }
                    valueBlock
                }
            } else {
                // Normal sizes: a single-line-ish row — name, chip, then value.
                // The value still wraps vertically via `fixedSize`.
                HStack(alignment: .firstTextBaseline, spacing: ConvertTheme.space2) {
                    nameLabel
                    typeChip
                    valueBlock
                }
            }
        }
        // Fuse the row into ONE VoiceOver element naming name, type, and value
        // (e.g. "buttonColor, string, blue" / "buttonColor, string, no value").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(presentation.typeName), \(presentation.accessibilityValue)")
    }

    /// The variable name in body type.
    private var nameLabel: some View {
        Text(name)
            .font(.body)
    }

    /// The mono value plus its optional muted note, stacked so both wrap to the
    /// full available width and never truncate.
    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space1) {
            Text(presentation.monoValue)
                .font(ConvertTheme.monospacedBody())
                // Wrap, never truncate — JSON in particular spans many lines.
                .fixedSize(horizontal: false, vertical: true)
            if let note = presentation.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The neutral type chip — the same soft-fill pattern as `StatusBadge`'s
    /// neutral states (`secondarySystemFill` fill + `secondaryLabel` text). The
    /// type *name* is the meaning; the SF Symbol is decorative and hidden from
    /// VoiceOver.
    private var typeChip: some View {
        HStack(spacing: ConvertTheme.space1) {
            Image(systemName: "curlybraces")
                // The fused row label already names the type; never announce the
                // decorative symbol separately.
                .accessibilityHidden(true)
            Text(presentation.typeName)
        }
        .font(.caption)
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.horizontal, ConvertTheme.space2)
        .padding(.vertical, ConvertTheme.space1 / 2)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: ConvertTheme.radiusSm, style: .continuous))
    }
}

#if DEBUG
struct FeatureVariableRow_Previews: PreviewProvider {

    /// One small, real JSON payload exercised by both the valid- and (implicitly)
    /// the layout previews. Building it via `Data(_: .utf8)` keeps the preview free
    /// of force-unwraps and of copy-pasted byte literals.
    private static let sampleJSON = Data(#"{"a":1,"b":[true]}"#.utf8)

    /// Every present type plus the absent case, as (name, presentation) pairs, so
    /// the preview renders them through one `ForEach` instead of repeating the row
    /// construction six times (SonarQube duplication discipline).
    private static let rows: [(name: String, presentation: FeatureVariableRow.Presentation)] = [
        ("isEnabled", .boolean(true)),
        ("maxItems", .integer(42)),
        ("discountRate", .float(0.15)),
        ("buttonColor", .string("blue")),
        ("theme", .json(sampleJSON)),
        ("headline", .absent(expectedType: "string"))
    ]

    static var previews: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                FeatureVariableRow(name: row.name, presentation: row.presentation)
            }

            Divider()

            // Prove the accessibility-size stacking: name+chip above, value below.
            FeatureVariableRow(name: "theme", presentation: .json(sampleJSON))
                .environment(\.dynamicTypeSize, .accessibility3)
        }
        .padding(ConvertTheme.space5)
        .previewLayout(.sizeThatFits)
    }
}
#endif
