import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class EncodedFrame {
  const EncodedFrame(this.width, this.height, this.jpeg);
  final int width;
  final int height;
  final Uint8List jpeg;
}

class RgbFrame {
  const RgbFrame(this.width, this.height, this.pixels);
  final int width;
  final int height;
  final Uint8List pixels;
}

/// Downsamples a YUV_420_888 camera frame straight into RGB so only a small
/// buffer (not the multi-megabyte planes) crosses into the encoding isolate.
RgbFrame sampleYuvToRgb(CameraImage image, {int targetWidth = 640}) {
  final step = max(1, (image.width / targetWidth).round());
  final outWidth = image.width ~/ step;
  final outHeight = image.height ~/ step;
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final yRow = yPlane.bytesPerRow;
  final uvRow = uPlane.bytesPerRow;
  final uvPixel = uPlane.bytesPerPixel ?? 1;
  final yBytes = yPlane.bytes;
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;
  final rgb = Uint8List(outWidth * outHeight * 3);
  var o = 0;
  for (var oy = 0; oy < outHeight; oy++) {
    final sy = oy * step;
    final yRowStart = sy * yRow;
    final uvRowStart = (sy >> 1) * uvRow;
    for (var ox = 0; ox < outWidth; ox++) {
      final sx = ox * step;
      final y = yBytes[yRowStart + sx];
      final uvIndex = uvRowStart + (sx >> 1) * uvPixel;
      final u = uBytes[uvIndex] - 128;
      final v = vBytes[uvIndex] - 128;
      rgb[o++] = (y + 1.402 * v).round().clamp(0, 255);
      rgb[o++] = (y - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
      rgb[o++] = (y + 1.772 * u).round().clamp(0, 255);
    }
  }
  return RgbFrame(outWidth, outHeight, rgb);
}

Future<EncodedFrame> encodePreviewJpeg(RgbFrame frame, int rotationDegrees) {
  return Isolate.run(() {
    var image = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.pixels.buffer,
      numChannels: 3,
    );
    if (rotationDegrees % 360 != 0) image = img.copyRotate(image, angle: rotationDegrees);
    return EncodedFrame(image.width, image.height, img.encodeJpg(image, quality: 70));
  });
}
