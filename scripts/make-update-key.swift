// Generates the offline Ed25519 key used to sign release manifests.
//
//   swift scripts/make-update-key.swift ~/somewhere/metashield-update.key
//
// The private key must never be committed, never be stored in GitHub Secrets,
// and never stay on the release machine between releases. Keep two encrypted
// backups: losing it means installed copies can no longer verify new manifests.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  fputs("사용법: swift scripts/make-update-key.swift <개인키 저장 경로>\n", stderr)
  exit(64)
}

let destination = URL(fileURLWithPath: arguments[1])
guard !FileManager.default.fileExists(atPath: destination.path) else {
  fputs("이미 파일이 있습니다. 덮어쓰지 않습니다: \(destination.path)\n", stderr)
  exit(1)
}

let privateKey = Curve25519.Signing.PrivateKey()
let privateText = privateKey.rawRepresentation.base64EncodedString() + "\n"

let descriptor = destination.path.withCString {
  open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
}
guard descriptor >= 0 else {
  fputs("개인키 파일을 만들지 못했습니다: \(String(cString: strerror(errno)))\n", stderr)
  exit(1)
}
let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
try handle.write(contentsOf: Data(privateText.utf8))
try handle.synchronize()
try handle.close()

print("개인키: \(destination.path) (권한 0600)")
print("공개키(앱에 내장할 값): \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
