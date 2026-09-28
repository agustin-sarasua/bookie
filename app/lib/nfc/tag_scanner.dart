/// Reading a tag's UID, which is all this app ever wants from NFC.
///
/// The toy identifies a page by UID alone — `nfc.cpp` reads it and hands it
/// straight to `library::trackFor()`. Nothing is written to the tag, so any
/// tag with a stable UID works, blank NTAGs included.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import '../model/uid.dart';

class TagScanner {
  StreamController<String>? _controller;
  bool _running = false;

  bool get isRunning => _running;

  static Future<NfcAvailability> availability() =>
      NfcManager.instance.checkAvailability();

  /// Emits a normalised UID per tag presented. Stays open until [stop] so the
  /// same session can take several tags in a row — on iOS that keeps the system
  /// sheet up, which is exactly the "tag the whole book" flow we want.
  Stream<String> scan({String? prompt}) {
    stop();
    final controller = StreamController<String>.broadcast();
    _controller = controller;
    _running = true;

    NfcManager.instance
        .startSession(
          pollingOptions: {
            NfcPollingOption.iso14443,
            NfcPollingOption.iso15693,
            NfcPollingOption.iso18092,
          },
          invalidateAfterFirstReadIos: false,
          alertMessageIos: prompt ?? 'Hold the phone against a tag.',
          onSessionErrorIos: (error) {
            if (!controller.isClosed) controller.addError(error);
            _running = false;
          },
          onDiscovered: (tag) async {
            final uid = _uidOf(tag);
            if (uid == null || uid.isEmpty) {
              debugPrint('nfc: tag with no readable identifier, ignored');
              return;
            }
            if (!controller.isClosed) controller.add(uid);
          },
        )
        .catchError((Object e) {
          if (!controller.isClosed) controller.addError(e);
          _running = false;
        });

    return controller.stream;
  }

  Future<void> stop({String? message}) async {
    if (!_running) return;
    _running = false;
    final controller = _controller;
    _controller = null;
    try {
      await NfcManager.instance.stopSession(alertMessageIos: message);
    } on Object catch (e) {
      debugPrint('nfc: stopSession failed ($e)');
    }
    await controller?.close();
  }

  /// The identifier lives in a different place on each platform, and on iOS in
  /// a different place per tag technology.
  static String? _uidOf(NfcTag tag) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = NfcTagAndroid.from(tag);
      return android == null ? null : uidFromBytes(android.id);
    }

    final mifare = MiFareIos.from(tag);
    if (mifare != null) return uidFromBytes(mifare.identifier);

    final iso15693 = Iso15693Ios.from(tag);
    if (iso15693 != null) return uidFromBytes(iso15693.identifier);

    final iso7816 = Iso7816Ios.from(tag);
    if (iso7816 != null) return uidFromBytes(iso7816.identifier);

    final felica = FeliCaIos.from(tag);
    if (felica != null) return uidFromBytes(felica.currentIDm);

    return null;
  }
}
