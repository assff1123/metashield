import Foundation

public enum MetaShieldError: LocalizedError, Equatable {
  case notARegularFile
  case symbolicLinkNotAllowed
  case unsupportedOrCorruptImage
  case animatedImageNotAllowed
  case inputFileTooLarge(byteCount: Int, limit: Int)
  case imageTooLarge(width: Int, height: Int)
  case hardLinkedFileNotAllowed
  case sourceChangedDuringProcessing
  case managedLocationNotAllowed
  case invalidDimensions
  case bitmapAllocationFailed
  case imageEncodingFailed
  case invalidPNG(String)
  case verificationFailed(String)
  case unsupportedInPlaceFormat(String)
  case avifEncodingUnavailable
  case fileOperationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notARegularFile:
      return "일반 파일이 아닙니다."
    case .symbolicLinkNotAllowed:
      return "심볼릭 링크는 안전을 위해 처리하지 않습니다."
    case .unsupportedOrCorruptImage:
      return "지원되지 않거나 손상된 이미지입니다."
    case .animatedImageNotAllowed:
      return "움직이는 이미지는 프레임 손실을 막기 위해 처리하지 않습니다."
    case .inputFileTooLarge(let byteCount, let limit):
      return "이미지 파일이 너무 큽니다 (\(Self.megabytes(byteCount))MB, 최대 \(Self.megabytes(limit))MB)."
    case .imageTooLarge(let width, let height):
      return "이미지가 너무 큽니다 (\(width)×\(height))."
    case .hardLinkedFileNotAllowed:
      return "여러 파일명이 같은 원본을 가리키는 하드 링크는 안전한 원본 교체를 위해 처리하지 않습니다."
    case .sourceChangedDuringProcessing:
      return "처리 중 원본이 다른 앱에서 변경되어 안전을 위해 덮어쓰지 않았습니다."
    case .managedLocationNotAllowed:
      return "사진 보관함 또는 임시 관리 경로의 파일은 직접 덮어쓸 수 없습니다. 사진 앱의 공유 메뉴에서 처리하세요."
    case .invalidDimensions:
      return "이미지 크기가 올바르지 않습니다."
    case .bitmapAllocationFailed:
      return "이미지 처리용 메모리를 만들 수 없습니다."
    case .imageEncodingFailed:
      return "깨끗한 PNG를 생성하지 못했습니다."
    case .invalidPNG(let reason):
      return "PNG 구조가 올바르지 않습니다: \(reason)"
    case .verificationFailed(let reason):
      return "정리 결과 검증에 실패했습니다: \(reason)"
    case .unsupportedInPlaceFormat(let ext):
      return "원본 덮어쓰기는 PNG만 지원합니다 (입력: \(ext))."
    case .avifEncodingUnavailable:
      return "이 macOS 버전은 AVIF 저장을 지원하지 않습니다. 메타데이터 제거는 그대로 사용할 수 있습니다."
    case .fileOperationFailed(let reason):
      return "파일 처리에 실패했습니다: \(reason)"
    }
  }

  private static func megabytes(_ bytes: Int) -> Int {
    max(1, (bytes + 1_048_575) / 1_048_576)
  }
}
