import Foundation

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                elements.append(value)
            } else {
                _ = try? container.superDecoder()
            }
        }
        self.elements = elements
    }
}

func nonnegativeAmpCost(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

func ampEpochDate(_ value: Int64) -> Date? {
    guard value > 0 else { return nil }
    let seconds = value >= 100_000_000_000 ? Double(value) / 1000 : Double(value)
    return Date(timeIntervalSince1970: seconds)
}
