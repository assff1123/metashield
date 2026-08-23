#!/usr/bin/swift

import AppKit
import Darwin
import Foundation

private let defaultServiceName = "메타데이터 완전 제거 및 덮어쓰기"

// A release check has to exercise every declared service, not just the default
// one, so the menu title can be chosen from the command line.
var arguments = Array(CommandLine.arguments.dropFirst())
var serviceName = defaultServiceName
if arguments.first == "--service" {
  guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("--service 뒤에 서비스 이름이 필요합니다.\n".utf8))
    exit(64)
  }
  serviceName = arguments[1]
  arguments.removeFirst(2)
}

guard !arguments.isEmpty else {
  FileHandle.standardError.write(
    Data("사용법: test-service-invocation.swift [--service <이름>] <이미지> [...]\n".utf8))
  exit(64)
}

let paths = arguments.map {
  URL(fileURLWithPath: $0).standardizedFileURL.path
}
guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
  FileHandle.standardError.write(Data("존재하지 않는 입력 파일이 있습니다.\n".utf8))
  exit(66)
}

// A broken service registration must not leave CI or a release check hanging
// forever. SIGALRM deliberately terminates only this short-lived test client.
signal(SIGALRM) { _ in
  FileHandle.standardError.write(Data("서비스 호출이 20초 안에 반환되지 않았습니다.\n".utf8))
  _exit(124)
}
alarm(20)

_ = NSApplication.shared
let pasteboard = NSPasteboard(name: NSPasteboard.Name("kr.metashield.service-test"))
pasteboard.clearContents()
let urls = paths.map { NSURL(fileURLWithPath: $0) }
guard pasteboard.writeObjects(urls) else {
  FileHandle.standardError.write(Data("파일 URL을 테스트 pasteboard에 기록하지 못했습니다.\n".utf8))
  exit(74)
}
pasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

let invoked = NSPerformService(serviceName, pasteboard)
alarm(0)
guard invoked else {
  FileHandle.standardError.write(Data("등록된 MetaShield 서비스를 찾거나 호출하지 못했습니다.\n".utf8))
  exit(69)
}
print("서비스 호출 전달 완료: \(paths.count)개")
