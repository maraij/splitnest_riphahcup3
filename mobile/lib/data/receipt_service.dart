/// Receipt capture + OCR (Phase 5) — device-side only.
///
/// Flow: pick a receipt photo (camera/gallery via image_picker) →
/// run on-device text recognition (google_mlkit_text_recognition) →
/// the caller shows a verify-before-save screen with the extracted
/// fields editable — nothing is ever saved straight from OCR.
///
/// Uploading is deliberately NOT here: the bytes go to the local
/// store through the repository interface only
/// (`SplitNestRepository.uploadReceipt` / `uploadProfilePhoto`), so
/// the store can be swapped without touching this service or any
/// screen. The local implementation writes them to files under
/// the app documents directory (see local_json_repository.dart).
///
/// Honest failure modes, never faked results:
/// - ML Kit has NO web implementation: on web OCR is skipped outright
///   (`ocrAvailable == false`) and the UI says so; the photo can
///   still be attached and the fields entered manually.
/// - On a device, if ML Kit throws (missing native config, no text
///   engine), OCR is skipped the same way — the raw image is still
///   usable and the user types the fields in.
library;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

/// What a receipt pick produced. [ocrText] is the raw recognised
/// text (null when OCR was unavailable or found no text);
/// [ocrAvailable] is false exactly when recognition could not run
/// on this platform/device — the UI must say so and offer manual
/// entry instead of showing empty fields as if OCR had run.
class ReceiptCapture {
  const ReceiptCapture({
    required this.file,
    required this.ocrText,
    required this.ocrAvailable,
  });
  final XFile file;
  final String? ocrText;
  final bool ocrAvailable;
}

class ReceiptService {
  ReceiptService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Picks a receipt photo and runs text recognition on it. Returns
  /// null when the user cancels the picker. Never throws for an OCR
  /// failure — that comes back as `ocrAvailable == false`.
  Future<ReceiptCapture?> pickAndRecognize(ImageSource source) async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        imageQuality: 85,
      );
    } catch (_) {
      return null;
    }
    if (picked == null) return null;
    final result = await recognizeTextResult(picked);
    return ReceiptCapture(
      file: picked,
      ocrText: result.text,
      ocrAvailable: result.available,
    );
  }

  /// Runs on-device text recognition on [file]. Returns the raw text
  /// plus whether recognition actually ran: `available == false`
  /// means recognition is unavailable on this platform (web — ML
  /// Kit has no web implementation) or failed at runtime, and the
  /// caller must offer manual entry. `available == true` with a null
  /// text means OCR ran but found no readable text — also manual
  /// entry, but the UI can say so precisely. Never invents text.
  Future<({String? text, bool available})> recognizeTextResult(
      XFile file) async {
    if (kIsWeb) return (text: null, available: false);
    TextRecognizer? recognizer;
    try {
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final input = InputImage.fromFilePath(file.path);
      final result = await recognizer.processImage(input);
      final text = result.text.trim();
      return (text: text.isEmpty ? null : text, available: true);
    } catch (_) {
      // MissingPluginException (no native implementation), a
      // PlatformException, or a bad image path: OCR is unavailable,
      // not an empty result — the caller falls back to manual entry.
      return (text: null, available: false);
    } finally {
      try {
        await recognizer?.close();
      } catch (_) {
        // Closing a failed recognizer must never throw.
      }
    }
  }

  /// Convenience wrapper: the raw text, or null when recognition
  /// did not run or found no text.
  Future<String?> recognizeText(XFile file) async =>
      (await recognizeTextResult(file)).text;
}
