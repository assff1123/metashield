import Foundation
import MetaShieldCore

private func printUsage() {
  print(
    """
    MetaShield — 강력 이미지 메타데이터 제거기

    사용법:
      metashield-cli --verify <PNG 파일>...
      metashield-cli --quick-action <이미지 파일>...
      metashield-cli --avif [--quality <0.3~0.95>] <이미지 파일>...
      metashield-cli <PNG 파일>...

    기본 동작은 검증된 새 8-bit RGB PNG로 원본을 영구 교체합니다.
    --quick-action은 PNG를 교체하고 다른 형식은 같은 폴더에 .clean.png를 만듭니다.
    --avif는 원본을 그대로 두고 같은 폴더에 .clean.avif 사본을 만듭니다.
    품질을 지정하지 않으면 거의 손실이 없는 고품질로 변환합니다.
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty, arguments.first != "--help", arguments.first != "-h" else {
  printUsage()
  exit(arguments.isEmpty ? 64 : 0)
}

// A release check needs to prove that the isolated decoder is reachable and
// produces the same bytes as the in-process path. Only meaningful when this
// binary runs from inside the app bundle, where the service lives.
if arguments.first == "--xpc-self-test" {
  let sanitizer = ImageSanitizer()
  let client = DecodingServiceClient()
  do {
    let sample = try Data(contentsOf: URL(fileURLWithPath: arguments.dropFirst().first ?? ""))
    let (local, localSize) = try sanitizer.encodedSanitizedPNG(from: sample)
    let (remote, remoteSize) = try client.encodedSanitizedPNG(from: sample)
    print("격리 디코더 연결: OK")
    print("  크기 일치: \(localSize == remoteSize) (\(remoteSize.width)×\(remoteSize.height))")
    print("  바이트 일치: \(local == remote) (\(remote.count) bytes)")
    exit(local == remote && localSize == remoteSize ? 0 : 1)
  } catch {
    fputs("격리 디코더 실패: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}

// Inside the app bundle the isolated decoder is available and used. Run
// standalone (a plain `swift build` binary) there is no service, so decoding
// happens in process; that path is for development and scripting.
let isolatedEncoder: CanonicalImageEncoding? =
  FileManager.default.fileExists(
    atPath: Bundle.main.bundlePath + "/Contents/XPCServices/MetaShieldDecodeService.xpc")
  ? DecodingServiceClient() : nil
let sanitizer = ImageSanitizer(isolatedEncoder: isolatedEncoder)

let verifyOnly = arguments.first == "--verify"
let quickAction = arguments.first == "--quick-action"
let avifMode = arguments.first == "--avif"

var remaining = (verifyOnly || quickAction || avifMode) ? Array(arguments.dropFirst()) : arguments
var avifQuality = AVIFQuality.high
if avifMode, remaining.first == "--quality" {
  guard remaining.count >= 2, let value = Double(remaining[1]) else {
    fputs("실패: --quality 뒤에 0.3~0.95 사이의 숫자가 필요합니다.\n", stderr)
    exit(64)
  }
  avifQuality = .compressed(value)
  remaining.removeFirst(2)
}
let paths = remaining
guard !paths.isEmpty else {
  printUsage()
  exit(64)
}
guard paths.count <= 100 else {
  fputs("실패: 한 번에 최대 100개 이미지까지 처리할 수 있습니다.\n", stderr)
  exit(64)
}
if let unknownOption = paths.first(where: { $0.hasPrefix("-") }) {
  fputs("실패: 알 수 없는 옵션입니다: \(unknownOption)\n\n", stderr)
  printUsage()
  exit(64)
}

var failed = false
for path in paths {
  let url = URL(fileURLWithPath: path)
  do {
    if verifyOnly {
      let inspection = try sanitizer.verifyCanonicalPNG(at: url)
      print(
        "검증 완료: \(path) — \(inspection.width)×\(inspection.height), \(inspection.chunkTypes.joined(separator: ","))"
      )
    } else if ImageInputLocationPolicy.shouldImportIntoPhotos(url) {
      throw MetaShieldError.managedLocationNotAllowed
    } else if avifMode {
      let destination = OutputNaming.uniqueCleanAVIFURL(
        in: url.deletingLastPathComponent(),
        baseName: url.deletingPathExtension().lastPathComponent
      )
      let report = try sanitizer.writeCanonicalAVIF(
        from: url, to: destination, quality: avifQuality)
      let saved =
        report.originalByteCount > 0
        ? Int((1.0 - Double(report.sanitizedByteCount) / Double(report.originalByteCount)) * 100)
        : 0
      print(
        "완료: \(path) → \(report.url.path) — \(report.width)×\(report.height), "
          + "\(report.originalByteCount) → \(report.sanitizedByteCount) bytes (\(saved)% 절감)"
      )
    } else if quickAction, url.pathExtension.lowercased() != "png" {
      let destination = OutputNaming.uniqueCleanPNGURL(
        in: url.deletingLastPathComponent(),
        baseName: url.deletingPathExtension().lastPathComponent
      )
      let report = try sanitizer.writeCanonicalPNG(from: url, to: destination)
      print("완료: \(path) → \(report.url.path) — \(report.width)×\(report.height)")
    } else {
      let report = try sanitizer.sanitizePNGInPlace(at: url)
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
