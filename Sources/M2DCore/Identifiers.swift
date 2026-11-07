import Foundation

/// Stable string identifiers for every object in a rig. Strings keep the
/// project JSON readable and diffable, and survive copy/paste between files.
public typealias ObjectID = String

public enum IDGenerator {
    /// Short random identifier with a readable prefix, e.g. `mesh_k3x9q2ab`.
    public static func make(_ prefix: String) -> ObjectID {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        let suffix = String((0..<10).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
        return "\(prefix)_\(suffix)"
    }
}
