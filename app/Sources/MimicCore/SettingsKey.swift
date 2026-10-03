/// The UserDefaults keys saved in one place and read in another: the app's settings Terminal
/// reads through the app's suite, as `MinisFolder.key` and `Power.key` are, and the size card's
/// choices it remembers. A typo in one would forget it without a word.
/// Not `Settings`, which would hide SwiftUI's Settings scene.
public enum SettingsKey {
    /// The 3D model chosen in Settings → 3D Model (`EngineModel.id`).
    public static let model = "model"
    /// The slicer chosen in Settings: a `Slicer.id`, or `Slicer.macDefault`.
    public static let slicer = "slicer"
    /// The folder of an install from before the standard layout, while it's still there (`Install.locate`).
    public static let installDir = "installDir"
    /// The size card's last choices (`SizeCard.remembered`): most people keep one printer.
    public static let purpose = "purpose", nozzle = "nozzle", kind = "kind"
    public static let baseShape = "baseShape", baseStyle = "baseStyle", magnet = "magnet"
}
