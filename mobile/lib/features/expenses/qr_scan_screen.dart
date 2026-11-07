/// QR expense entry (Phase 5) — scans a SplitNest QR code and
/// parses it into the same verify-before-save flow as an OCR
/// receipt. Nothing is ever saved straight from a scan.
///
/// Payload format (see domain/qr_payload.dart):
///   `SPLITNEST|<title>|<amount>|<category>[|<yyyy-MM-dd>]`
///
/// Graceful degradation: on a device/browser without a usable
/// camera the scanner shows its error state with a plain message
/// and a "enter manually instead" action — the expense form stays
/// reachable without a scan.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';
import '../../domain/qr_payload.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;
  String? _notice;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    final payload = parseQrPayload(raw);
    if (payload == null) {
      // Not a SplitNest expense code — stay on the scanner and say
      // so plainly; the user can try another code or go manual.
      setState(() => _notice =
          'That QR code is not a SplitNest expense code. Try another '
          'one, or enter the expense manually.');
      return;
    }
    _handled = true;
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan expense QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography_outlined, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'Camera scanning is not available on this '
                        'device or browser.',
                        style: SplitNestTheme.sectionStyle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Enter the expense manually instead — the '
                        'Add Expense form takes the same details.',
                        style: SplitNestTheme.supportingStyle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Enter manually instead'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (_notice != null) ...[
                  Text(
                    _notice!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'Point the camera at a SplitNest expense code, e.g. '
                  'SPLITNEST|Internet Bill|1500.00|Utilities. The '
                  'details are shown for you to check before anything '
                  'is saved.',
                  style: SplitNestTheme.supportingStyle,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Enter manually instead'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
