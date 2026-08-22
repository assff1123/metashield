// Builds and signs the release manifest for one DMG.
//
//   swift scripts/sign-update-manifest.swift \
//       outputs/MetaShield-<version>-direct.dmg ~/usb/metashield-update.key outputs
//
// Produces metashield-update.json and metashield-update.json.sig next to the
// chosen output directory. The manifest holds no URL: the app derives every
// address from compiled-in constants.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
  fputs("사용법: swift scripts/sign-update-manifest.swift <DMG> <개인키> <출력 폴더>\n", stderr)
  exit(64)
}

let diskImageURL = URL(fileURLWithPath: arguments[1])
let keyURL = URL(fileURLWithPath: arguments[2])
let outputDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)

let name = diskImageURL.lastPathComponent
guard name.hasPrefix("MetaShield-"), name.hasSuffix("-direct.dmg") else {
  fputs("DMG 이름이 MetaShield-<버전>-direct.dmg 형식이 아닙니다: \(name)\n", stderr)
  exit(1)
}
let version = String(name.dropFirst("MetaShield-".count).dropLast("-direct.dmg".count))
let fields = version.split(separator: ".", omittingEmptySubsequences: false)
guard fields.count == 3,
  fields.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy(\.isNumber) })
else {
  fputs("DMG 이름에서 숫자 세 자리 버전을 읽지 못했습니다: \(version)\n", stderr)
  exit(1)
}

guard let keyText = try? String(contentsOf: keyURL, encoding: .utf8),
  let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
  let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else {
  fputs("개인키를 읽지 못했습니다: \(keyURL.path)\n", stderr)
  exit(1)
}

let handle = try FileHandle(forReadingFrom: diskImageURL)
var hasher = SHA256()
var byteCount = 0
while true {
  let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
  if chunk.isEmpty { break }
  byteCount += chunk.count
  hasher.update(data: chunk)
}
try handle.close()
let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

let payload: [String: Any] = [
  "schema": 1,
  "version": version,
  "dmgName": name,
  "sha256": digest,
  "size": byteCount,
]
let manifest = try JSONSerialization.data(
  withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
let signature = try privateKey.signature(for: manifest)

let manifestURL = outputDirectory.appendingPathComponent("metashield-update.json")
let signatureURL = outputDirectory.appendingPathComponent("metashield-update.json.sig")
try manifest.write(to: manifestURL, options: .atomic)
try Data((signature.base64EncodedString() + "\n").utf8).write(
  to: signatureURL, options: .atomic)

// Verify the freshly written pair exactly the way the app will.
guard privateKey.publicKey.isValidSignature(signature, for: manifest) else {
  fputs("서명 자체 검증에 실패했습니다.\n", stderr)
  exit(1)
}

print(manifestURL.path)
print(signatureURL.path)
print("공개키 확인용: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
