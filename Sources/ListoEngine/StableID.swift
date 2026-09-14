import Foundation
import CryptoKit

extension UUID {
    /// A UUID deterministically derived from `seed`. Used so that re-parsing
    /// a document after an unrelated edit assigns the *same* id to a task
    /// or section whose content and position haven't changed, instead of a
    /// fresh random one every time.
    ///
    /// This matters for the SwiftUI layer: `ForEach(id: \.id)` and `@State`
    /// tied to a row's identity (an open note popover, an in-progress
    /// rename, a drag) only survive a re-render if the id stays the same.
    /// With a random id per parse, *every* row would look "new" after
    /// *any* edit anywhere in the document, discarding all of that state
    /// — e.g. a just-saved note appearing empty when reopened, because the
    /// popover's view identity (and the state seeded from it) had already
    /// been torn down and recreated by the time it reopened.
    ///
    /// Still purely in-memory/ephemeral (spec §09) — nothing here is
    /// written to the file — just stable *within* a session as long as the
    /// content it's derived from doesn't change.
    init(stableSeed seed: String) {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        let rawUUID: uuid_t = digest.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: rawUUID)
    }
}
