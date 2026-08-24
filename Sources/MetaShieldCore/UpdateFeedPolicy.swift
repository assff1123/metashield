import Foundation

/// What the app should conclude from one release-feed answer.
public enum UpdateFeedJudgement: Equatable, Sendable {
  case upToDate(current: ReleaseVersion)
  case updateAvailable(latest: ReleaseVersion)
  /// The feed reported a version older than one this copy has already seen.
  /// A release host that regresses like this is either yanking a release or
  /// being used to hide a newer, possibly security-fixing, version.
  case regressionSuspected(highestSeen: ReleaseVersion, reported: ReleaseVersion)
}

/// Decides what a release-feed answer means, given what this copy has seen before.
///
/// The signed manifest protects the *contents* of a download, but the feed that
/// names the latest version is consulted first and is not signed. An attacker
/// holding the release host can therefore point everyone at an older tag to hide
/// that a newer version exists. Remembering the highest version this copy has
/// ever been told about turns that silent suppression into something visible.
///
/// The protection is deliberately narrow, and `AUDIT.md` says so: it catches a
/// host that regresses *after* this copy has seen a newer version. It cannot
/// help a copy that has never seen the newer version, and nothing here stops an
/// attacker who simply stops publishing.
public enum UpdateFeedPolicy {
  public static func judge(
    reported: ReleaseVersion,
    current: ReleaseVersion,
    highestSeen: ReleaseVersion?
  ) -> UpdateFeedJudgement {
    if let highestSeen, reported < highestSeen {
      return .regressionSuspected(highestSeen: highestSeen, reported: reported)
    }
    if reported > current {
      return .updateAvailable(latest: reported)
    }
    return .upToDate(current: current)
  }

  /// The value to remember after a judgement. A suspected regression must not
  /// lower the stored high-water mark, or one poisoned answer would erase the
  /// evidence that made the next one detectable.
  public static func updatedHighestSeen(
    reported: ReleaseVersion,
    current: ReleaseVersion,
    highestSeen: ReleaseVersion?
  ) -> ReleaseVersion {
    var candidates = [reported, current]
    if let highestSeen { candidates.append(highestSeen) }
    return candidates.max() ?? current
  }
}
