import Foundation
import MetaShieldCore

private func printUsage() {
  print(
    """
    MetaShield — 강력 이미지 메타데이터 제거기

    사용법:
      metashield-cli --verify <PNG 파일>...
      metashield-cli --quick-action <이미지 파일>...
      metashield-cli <PNG 파일>...

    기본 동작은 검증된 새 8-bit RGB PNG로 원본을 영구 교체합니다.
    --quick-action은 PNG를 교체하고 다른 형식은 같은 폴더에 .clean.png를 만듭니다.
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty, arguments.first != "--help", arguments.first != "-h" else {
  printUsage()
  exit(arguments.isEmpty ? 64 : 0)
}

let verifyOnly = arguments.first == "--verify"
let quickAction = arguments.first == "--quick-action"
let paths = (verifyOnly || quickAction) ? Array(arguments.dropFirst()) : arguments
guard !paths.isEmpty else {
  printUsage()
  exit(64)
}
guard paths.count <= 100 else {
  fputs("실패: 한 번에 최대 100개 이미지까지 처리할 수 있습니다.\n", stderr)
  exit(64)
}

var failed = false
for path in paths {
  let url = URL(fileURLWithPath: path)
  do {
    if verifyOnly {
      let inspection = try ImageSanitizer.shared.verifyCanonicalPNG(at: url)
      print(
        "검증 완료: \(path) — \(inspection.width)×\(inspection.height), \(inspection.chunkTypes.joined(separator: ","))"
      )
    } else if ImageInputLocationPolicy.shouldImportIntoPhotos(url) {
      throw MetaShieldError.managedLocationNotAllowed
    } else if quickAction, url.pathExtension.lowercased() != "png" {
      let destination = uniqueOutputURL(for: url)
      let report = try ImageSanitizer.shared.writeCanonicalPNG(from: url, to: destination)
      print("완료: \(path) → \(report.url.path) — \(report.width)×\(report.height)")
    } else {
      let report = try ImageSanitizer.shared.sanitizePNGInPlace(at: url)
      print(
        "완료: \(path) — \(report.width)×\(report.height), \(report.originalByteCount) → \(report.sanitizedByteCount) bytes"
      )
    }
  } catch {
    failed = true
    fputs("실패: \(path) — \(error.localizedDescription)\n", stderr)
  }
}

exit(failed ? 1 : 0)

private func uniqueOutputURL(for source: URL) -> URL {
  let directory = source.deletingLastPathComponent()
  let baseName = source.deletingPathExtension().lastPathComponent
  var candidate = directory.appendingPathComponent("\(baseName).clean.png")
  var index = 2
  while FileManager.default.fileExists(atPath: candidate.path) {
    candidate = directory.appendingPathComponent("\(baseName).clean-\(index).png")
    index += 1
  }
  return candidate
}
