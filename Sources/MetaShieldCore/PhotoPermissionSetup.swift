import Foundation

/// Identifies the one-time Photos share-extension permission setup request.
///
/// The provider also contains this canonical, metadata-free PNG so macOS
/// considers it an image share. The extension checks the private marker and
/// requests PhotoKit access without sanitizing or importing the setup image.
public enum PhotoPermissionSetup {
  public static let typeIdentifier = "kr.metashield.photo-permission-setup"
  public static let suggestedFileName = "MetaShield Photo Permission Setup.png"
  public static let markerData = Data("MetaShield photo permission setup v1".utf8)

  public static let previewPNGData = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAD0lEQVR4AQEEAPv/AP///wX+Av5JZm4rAAAAAElFTkSuQmCC"
  )!

  public static func isSetupRequest(registeredTypeIdentifiers: [String]) -> Bool {
    registeredTypeIdentifiers.contains(typeIdentifier)
  }
}
