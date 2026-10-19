import Foundation

/// Quick-fill presets for Bailian Happy Oyster models (demo only; the SDK is unaware of them).
///
/// happyoyster is split into different sub-models by mode, and **each sub-model is an independent Bailian gateway app route**,
/// so `OysterConfig.model` is required, and a single initialize only serves worlds of one mode.
/// This lists the values commonly used for testing and provides a "map to the same-group model for a world mode" mapping,
/// used to align automatically before entering a world (see `AppSession.ensureModel(for:)`).
///
/// Corresponds one-to-one with the Android demo's `DEMO_MODEL_PRESETS`. On Android the world list is fetched under a model,
/// so it naturally only shows worlds of the current model's mode; this demo's world list comes from the app's own backend and includes all modes,
/// hence this explicit mapping layer.
struct ModelPreset: Identifiable, Hashable {
    let name: String
    /// The world mode this model serves. Models and modes map one-to-one, which is the basis of this automatic mapping.
    let mode: ServerWorldMode

    var id: String { name }

    /// All quick-fill values for production models (the demo lists production only; for internal environments, type the model name into the input field).
    static let all: [ModelPreset] = [
        ModelPreset(name: "happyoyster-1.0-adventure", mode: .wander),
        ModelPreset(name: "happyoyster-1.0-directing", mode: .story),
        ModelPreset(name: "happyoyster-1.0-acting",    mode: .acting),
    ]

    /// The preset matching the configured model name; a manually entered legacy unsplit model (e.g. `happyoyster-1.0`)
    /// or any custom value returns nil.
    static func preset(named model: String) -> ModelPreset? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.name == trimmed }
    }

    /// Maps the configured model to the model name that "serves worlds of `mode`".
    ///
    /// Only maps when the configured model itself is a known split model. In all other cases (legacy unsplit model, custom model name,
    /// empty value) it is **returned as-is, with no guessing**: the demo cannot tell whether an unfamiliar model name is already split by mode,
    /// and a wrong guess would turn a request that could have succeeded into one that is guaranteed to be `AccessDenied`.
    static func resolve(configured model: String, for mode: ServerWorldMode) -> String {
        guard preset(named: model) != nil else { return model }
        guard let target = all.first(where: { $0.mode == mode }) else { return model }
        return target.name
    }
}
