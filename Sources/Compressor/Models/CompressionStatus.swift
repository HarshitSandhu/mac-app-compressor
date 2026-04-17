import Foundation

enum CompressionStatus: String, Codable, Equatable {
    case archived
    case restoring
    case restored
    case failed
}
