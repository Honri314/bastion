import Foundation

public enum ProxmoxKitResources {
    public static var bundle: Bundle { Bundle.module }
    public static func url(_ name: String) -> URL? {
        bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension())
    }
}

extension String {
    public var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
    public func pathExtension() -> String {
        (self as NSString).pathExtension
    }
}
