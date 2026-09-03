import 'dart:typed_data';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum FaceFramePlatform { android, ios }

class FaceCameraPlane {
  const FaceCameraPlane({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}

class PreparedFaceCameraFrame {
  const PreparedFaceCameraFrame({
    required this.bytes,
    required this.format,
    required this.bytesPerRow,
  });

  final Uint8List bytes;
  final InputImageFormat format;
  final int bytesPerRow;
}

/// Prepares only documented camera layouts for the ML Kit byte-array bridge.
///
/// Android YUV_420_888 is Y/U/V with per-plane row and pixel strides; merely
/// concatenating the planes does not produce NV21. The native byte-array API
/// expects NV21 (or YV12), not a YUV_420_888 media.Image layout.
/// https://developer.android.com/reference/android/graphics/ImageFormat#YUV_420_888
/// https://developers.google.com/ml-kit/vision/face-detection/android
PreparedFaceCameraFrame? prepareFaceCameraFrame({
  required FaceFramePlatform platform,
  required int width,
  required int height,
  required int rawFormat,
  required List<FaceCameraPlane> planes,
}) {
  if (width <= 0 || height <= 0 || planes.isEmpty) return null;
  final format = InputImageFormatValue.fromRawValue(rawFormat);

  if (platform == FaceFramePlatform.ios) {
    if (format != InputImageFormat.bgra8888 || planes.length != 1) return null;
    final plane = planes.single;
    if (plane.bytesPerRow < width * 4 ||
        plane.bytes.length < plane.bytesPerRow * height) {
      return null;
    }
    return PreparedFaceCameraFrame(
      bytes: plane.bytes,
      format: InputImageFormat.bgra8888,
      bytesPerRow: plane.bytesPerRow,
    );
  }

  if (width.isOdd || height.isOdd) return null;
  final expectedBytes = width * height * 3 ~/ 2;
  if (format == InputImageFormat.nv21 && planes.length == 1) {
    final plane = planes.single;
    if (plane.bytesPerRow != width ||
        (plane.bytesPerPixel ?? 1) != 1 ||
        plane.bytes.length < expectedBytes) {
      return null;
    }
    return PreparedFaceCameraFrame(
      bytes: Uint8List.sublistView(plane.bytes, 0, expectedBytes),
      format: InputImageFormat.nv21,
      bytesPerRow: width,
    );
  }

  if ((format != InputImageFormat.yuv_420_888 &&
          format != InputImageFormat.nv21) ||
      planes.length != 3) {
    return null;
  }
  final y = planes[0];
  final u = planes[1];
  final v = planes[2];
  final chromaWidth = width ~/ 2;
  final chromaHeight = height ~/ 2;
  if (!_hasSamples(y, width, height) ||
      !_hasSamples(u, chromaWidth, chromaHeight) ||
      !_hasSamples(v, chromaWidth, chromaHeight)) {
    return null;
  }

  final bytes = Uint8List(expectedBytes);
  final yPixelStride = y.bytesPerPixel ?? 1;
  for (var row = 0; row < height; row++) {
    for (var column = 0; column < width; column++) {
      bytes[row * width + column] =
          y.bytes[row * y.bytesPerRow + column * yPixelStride];
    }
  }
  var destination = width * height;
  final uPixelStride = u.bytesPerPixel ?? 1;
  final vPixelStride = v.bytesPerPixel ?? 1;
  for (var row = 0; row < chromaHeight; row++) {
    for (var column = 0; column < chromaWidth; column++) {
      bytes[destination++] =
          v.bytes[row * v.bytesPerRow + column * vPixelStride];
      bytes[destination++] =
          u.bytes[row * u.bytesPerRow + column * uPixelStride];
    }
  }
  return PreparedFaceCameraFrame(
    bytes: bytes,
    format: InputImageFormat.nv21,
    bytesPerRow: width,
  );
}

bool _hasSamples(FaceCameraPlane plane, int columns, int rows) {
  final pixelStride = plane.bytesPerPixel ?? 1;
  if (pixelStride <= 0 || plane.bytesPerRow <= 0) return false;
  final rowBytes = (columns - 1) * pixelStride + 1;
  if (plane.bytesPerRow < rowBytes) return false;
  final requiredBytes = (rows - 1) * plane.bytesPerRow + rowBytes;
  return plane.bytes.length >= requiredBytes;
}
