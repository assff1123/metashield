import Foundation

/// Decides whether a sanitized copy may replace its source.
///
/// Leaving the source in place is not neutral: a JPEG that still carries its
/// EXIF and GPS sits next to the cleaned copy, and someone who believes the
/// folder is clean will share the very data they meant to remove. So the scrub
/// command retires the source — but only when doing so cannot lose anything.
public enum OriginalDisposal {
  public enum Decision: Equatable, Sendable {
    case moveToTrash
    /// Kept, with the reason, so the app can say why rather than staying silent.
    case keep(String)
  }

  /// The copy has already been written and verified when this runs.
  public static func decide(source: URL, sanitizedCopy: URL) -> Decision {
    let sourceDirectory = source.deletingLastPathComponent().standardizedFileURL.path
    let copyDirectory = sanitizedCopy.deletingLastPathComponent().standardizedFileURL.path
    guard sourceDirectory == copyDirectory else {
      // The copy went somewhere else (a read-only folder falls back to
      // Downloads). Retiring the source would leave the user looking at an
      // empty folder wondering where the file went.
      return .keep("정리본이 원본과 다른 폴더에 저장되어 원본을 그대로 두었습니다.")
    }
    guard source.standardizedFileURL != sanitizedCopy.standardizedFileURL else {
      return .keep("원본이 이미 교체되었습니다.")
    }
    // A managed Photos original is not ours to retire; the library owns it.
    guard !ImageInputLocationPolicy.shouldImportIntoPhotos(source) else {
      return .keep("사진 보관함이 관리하는 원본은 삭제하지 않습니다.")
    }
    return .moveToTrash
  }
}
