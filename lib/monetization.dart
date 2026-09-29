import 'package:shared_preferences/shared_preferences.dart';

/// Commercial configuration kept separate from playback and library state.
///
/// Ads remain disabled until a production ad provider, privacy consent flow,
/// and Play Billing product are configured. This prevents an unsigned/debug
/// build from accidentally showing test or unconfigured ads while preserving
/// a stable entitlement boundary for a future ad-supported release.
class MonetizationState {
  const MonetizationState({required this.removeAds});

  final bool removeAds;

  bool shouldShowAds({bool adsConfigured = false}) =>
      adsConfigured && !removeAds;
}

class MonetizationStore {
  static const _removeAdsKey = 'monetization.removeAds';

  Future<MonetizationState> load() async {
    final preferences = await SharedPreferences.getInstance();
    return MonetizationState(
      removeAds: preferences.getBool(_removeAdsKey) ?? false,
    );
  }

  Future<void> saveRemoveAds(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_removeAdsKey, enabled);
  }
}
