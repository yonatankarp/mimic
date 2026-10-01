/// The UserDefaults keys the app saves and Terminal reads, through the app's suite, as
/// `MinisFolder.key` and `Power.key` are: a typo in one would break Terminal without a word.
/// Not `Settings`, which would hide SwiftUI's Settings scene.
public enum SettingsKey {
    /// The 3D model chosen in Settings → 3D Model (`EngineModel.id`).
    public static let model = "model"
    /// The slicer chosen in Settings: a `Slicer.id`, or `Slicer.macDefault`.
    public static let slicer = "slicer"
    /// The folder of an install from before the standard layout, while it's still there (`Install.locate`).
    public static let installDir = "installDir"
}
