import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Optional Android Play Integrity client.
///
/// NeonAmp deliberately returns the opaque token to the caller. The token must
/// be sent to a protected application backend for verification; it must never
/// be decoded or trusted in the APK.
class PlayIntegrityClient {
  static const MethodChannel _channel = MethodChannel('neonamp/play_integrity');

  Future<bool> prepare({required int cloudProjectNumber}) async {
    return await _channel.invokeMethod<bool>('prepare', {
          'cloudProjectNumber': cloudProjectNumber,
        }) ??
        false;
  }

  Future<String> requestToken({required String requestHash}) async {
    final token = await _channel.invokeMethod<String>('requestToken', {
      'requestHash': requestHash,
    });
    if (token == null || token.isEmpty) {
      throw StateError('Play Integrity returned an empty token.');
    }
    return token;
  }

  Future<bool> get isPrepared async {
    final state = await _channel.invokeMapMethod<Object?, Object?>('state');
    return state?['prepared'] == true;
  }

  /// Produces a stable SHA-256 request binding for a protected backend call.
  static String requestHash(String canonicalRequest) =>
      sha256.convert(utf8.encode(canonicalRequest)).toString();
}
