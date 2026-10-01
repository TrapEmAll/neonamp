/// Build-time Play Integrity configuration.
///
/// The project number is intentionally supplied with --dart-define rather
/// than stored in the repository. A missing or malformed value disables the
/// optional provider warm-up for development/debug builds.
class PlayIntegrityConfig {
  static const String _rawProjectNumber = String.fromEnvironment(
    'NEONAMP_PLAY_INTEGRITY_PROJECT_NUMBER',
  );

  static int? get cloudProjectNumber {
    final value = int.tryParse(_rawProjectNumber.trim());
    return value == null || value <= 0 ? null : value;
  }

  static bool get isConfigured => cloudProjectNumber != null;
}

