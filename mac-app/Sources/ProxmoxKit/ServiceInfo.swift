import Foundation

public struct ServiceInfo: Codable, Identifiable {
    public let name: String
    public let state: String?
    public let desc: String?
    public var id: String { name }
}
