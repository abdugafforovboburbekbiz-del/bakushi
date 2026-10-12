/// Minimal WAV reader/writer (float32 + PCM16). No external dependencies.
/// Used for exports and tests.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Encode interleaved stereo float32 WAV bytes.
Uint8List encodeWavFloat32(
  Float32List left,
  Float32List right,
  int sampleRate,
) {
  final frames = math.min(left.length, right.length);
  final data = ByteData(frames * 2 * 4);
  int o = 0;
  for (int i = 0; i < frames; i++) {
    data.setFloat32(o, left[i], Endian.little);
    o += 4;
    data.setFloat32(o, right[i], Endian.little);
    o += 4;
  }
  final body = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return _wrapWav(body, sampleRate, 2, 32, isFloat: true);
}

/// Encode interleaved stereo PCM16 WAV bytes (with clipping protection).
Uint8List encodeWavPcm16(
  Float32List left,
  Float32List right,
  int sampleRate, {
  double gain = 1.0,
}) {
  final frames = math.min(left.length, right.length);
  final data = ByteData(frames * 2 * 2);
  int o = 0;
  for (int i = 0; i < frames; i++) {
    final int l = ((left[i] * gain).clamp(-1.0, 1.0) * 32767).round();
    final int r = ((right[i] * gain).clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(o, l, Endian.little);
    o += 2;
    data.setInt16(o, r, Endian.little);
    o += 2;
  }
  final body = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return _wrapWav(body, sampleRate, 2, 16, isFloat: false);
}

Uint8List _wrapWav(
  Uint8List pcm,
  int sampleRate,
  int channels,
  int bits, {
  required bool isFloat,
}) {
  final byteRate = sampleRate * channels * (bits ~/ 8);
  final blockAlign = channels * (bits ~/ 8);
  final fmt = 3; // IEEE float when float, else PCM
  final out = BytesBuilder();
  final hdr = ByteData(44);

  void writeAscii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      hdr.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  hdr.setUint32(4, 36 + pcm.length, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  hdr.setUint32(16, 16, Endian.little);
  hdr.setUint16(20, isFloat ? fmt : 1, Endian.little);
  hdr.setUint16(22, channels, Endian.little);
  hdr.setUint32(24, sampleRate, Endian.little);
  hdr.setUint32(28, byteRate, Endian.little);
  hdr.setUint16(32, blockAlign, Endian.little);
  hdr.setUint16(34, bits, Endian.little);
  writeAscii(36, 'data');
  hdr.setUint32(40, pcm.length, Endian.little);

  out.add(hdr.buffer.asUint8List());
  out.add(pcm);
  return out.toBytes();
}

/// Write a float32 stereo WAV to disk.
Future<void> writeWavFloat32File(
  String path,
  Float32List left,
  Float32List right,
  int sampleRate,
) {
  return File(path)
      .writeAsBytes(encodeWavFloat32(left, right, sampleRate), flush: true);
}

/// Write a PCM16 stereo WAV to disk.
Future<void> writeWavPcm16File(
  String path,
  Float32List left,
  Float32List right,
  int sampleRate,
) {
  return File(path)
      .writeAsBytes(encodeWavPcm16(left, right, sampleRate), flush: true);
}

// ---------------------------------------------------------------------------
// Reader (used by tests to round-trip the writer output).
// ---------------------------------------------------------------------------

class DecodedWav {
  final Float32List left;
  final Float32List right;
  final int sampleRate;

  DecodedWav(this.left, this.right, this.sampleRate);
}

DecodedWav readWav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 44) throw const FormatException('WAV too short');
  String ascii(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (ascii(0) != 'RIFF' || ascii(8) != 'WAVE') {
    throw const FormatException('Not a WAV file');
  }
  final channels = bd.getUint16(22, Endian.little);
  final sr = bd.getUint32(24, Endian.little);
  final bits = bd.getUint16(34, Endian.little);
  final isFloat = bd.getUint16(20, Endian.little) == 3;

  // Walk chunks to find data.
  int offset = 12;
  int dataOffset = -1;
  int dataLength = 0;
  while (offset + 8 <= bytes.length) {
    final id = ascii(offset);
    final size = bd.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      dataOffset = offset + 8;
      dataLength = size;
      break;
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset < 0) throw const FormatException('No data chunk in WAV');

  final frameBytes = channels * (bits ~/ 8);
  final frames = dataLength ~/ frameBytes;
  final left = Float32List(frames);
  final right = Float32List(frames);
  for (int i = 0; i < frames; i++) {
    for (int c = 0; c < channels; c++) {
      final pos = dataOffset + i * frameBytes + c * (bits ~/ 8);
      double v;
      if (isFloat && bits == 32) {
        v = bd.getFloat32(pos, Endian.little);
      } else if (!isFloat && bits == 16) {
        v = bd.getInt16(pos, Endian.little) / 32768.0;
      } else {
        throw FormatException(
          'Unsupported WAV format: $bits-bit float=$isFloat',
        );
      }
      if (c == 0) left[i] = v;
      if (c == 1) right[i] = v;
    }
  }
  return DecodedWav(left, right, sr);
}
