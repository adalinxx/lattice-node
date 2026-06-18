import Foundation
import cashew
import OrderedCollections

final class BufferedStorer: Storer {
    private(set) var entries: OrderedDictionary<String, Data> = [:]

    var entryList: [(String, Data)] {
        entries.map { ($0.key, $0.value) }
    }

    func store(rawCid: String, data: Data) throws {
        if entries[rawCid] == nil { entries[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        entries[rawCid] != nil
    }
}
