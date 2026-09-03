import 'dart:typed_data';

import 'package:fingerspeak_mobile/services/face_camera_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

FaceCameraPlane plane(List<int> values, int rowStride, [int pixelStride = 1]) =>
    FaceCameraPlane(
      bytes: Uint8List.fromList(values),
      bytesPerRow: rowStride,
      bytesPerPixel: pixelStride,
    );

void main() {
  test('packed Android NV21 retains exact pixels and correct metadata', () {
    final values = List<int>.generate(12, (index) => index + 1);
    final result = prepareFaceCameraFrame(
      platform: FaceFramePlatform.android,
      width: 4,
      height: 2,
      rawFormat: InputImageFormat.nv21.rawValue,
      planes: [plane(values, 4)],
    );

    expect(result, isNotNull);
    expect(result!.format, InputImageFormat.nv21);
    expect(result.bytesPerRow, 4);
    expect(result.bytes, values);
  });

  test('planar YUV420 strips row padding and interleaves V before U', () {
    final result = prepareFaceCameraFrame(
      platform: FaceFramePlatform.android,
      width: 4,
      height: 4,
      rawFormat: InputImageFormat.yuv_420_888.rawValue,
      planes: [
        plane([
          1,
          2,
          3,
          4,
          0,
          0,
          5,
          6,
          7,
          8,
          0,
          0,
          9,
          10,
          11,
          12,
          0,
          0,
          13,
          14,
          15,
          16,
        ], 6),
        plane([101, 102, 0, 103, 104], 3),
        plane([201, 202, 0, 203, 204], 3),
      ],
    );

    expect(result, isNotNull);
    expect(result!.format, InputImageFormat.nv21);
    expect(result.bytes, [
      ...List<int>.generate(16, (index) => index + 1),
      201,
      101,
      202,
      102,
      203,
      103,
      204,
      104,
    ]);
  });

  test('interleaved chroma views honor pixel stride and truncated padding', () {
    final result = prepareFaceCameraFrame(
      platform: FaceFramePlatform.android,
      width: 4,
      height: 4,
      rawFormat: InputImageFormat.yuv_420_888.rawValue,
      planes: [
        plane(List<int>.generate(16, (index) => index + 1), 4),
        plane([101, 202, 102, 203, 103, 204, 104], 4, 2),
        plane([201, 101, 202, 102, 203, 103, 204], 4, 2),
      ],
    );

    expect(result!.bytes, [
      ...List<int>.generate(16, (index) => index + 1),
      201,
      101,
      202,
      102,
      203,
      103,
      204,
      104,
    ]);
  });

  test('malformed or unknown Android layouts are not guessed', () {
    PreparedFaceCameraFrame? prepare(
      int format,
      List<FaceCameraPlane> planes, {
      int width = 4,
    }) =>
        prepareFaceCameraFrame(
          platform: FaceFramePlatform.android,
          width: width,
          height: 2,
          rawFormat: format,
          planes: planes,
        );

    expect(prepare(999, [plane(List<int>.filled(12, 0), 4)]), isNull);
    expect(prepare(InputImageFormat.nv21.rawValue, []), isNull);
    expect(
        prepare(InputImageFormat.nv21.rawValue, [
          plane([1, 2], 4)
        ]),
        isNull);
    expect(
      prepare(InputImageFormat.nv21.rawValue, [plane(List.filled(12, 0), 6)]),
      isNull,
    );
    expect(
      prepare(InputImageFormat.nv21.rawValue, [plane(List.filled(12, 0), 3)],
          width: 3),
      isNull,
    );
    expect(
      prepare(InputImageFormat.yuv_420_888.rawValue, [
        plane(List.filled(8, 0), 4),
        plane([1], 2),
        plane([2, 3], 2),
      ]),
      isNull,
    );
  });

  test('iOS BGRA preserves its row stride and rejects short buffers', () {
    final pixels = List<int>.generate(24, (index) => index);
    final result = prepareFaceCameraFrame(
      platform: FaceFramePlatform.ios,
      width: 2,
      height: 2,
      rawFormat: InputImageFormat.bgra8888.rawValue,
      planes: [plane(pixels, 12, 4)],
    );
    expect(result!.format, InputImageFormat.bgra8888);
    expect(result.bytesPerRow, 12);
    expect(result.bytes, pixels);

    expect(
      prepareFaceCameraFrame(
        platform: FaceFramePlatform.ios,
        width: 2,
        height: 2,
        rawFormat: InputImageFormat.bgra8888.rawValue,
        planes: [
          plane([1, 2, 3, 4], 8, 4)
        ],
      ),
      isNull,
    );
    expect(
      prepareFaceCameraFrame(
        platform: FaceFramePlatform.ios,
        width: 2,
        height: 2,
        rawFormat: InputImageFormat.nv21.rawValue,
        planes: [plane(List.filled(24, 0), 12, 4)],
      ),
      isNull,
    );
  });
}
