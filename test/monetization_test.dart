import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/monetization.dart';

void main() {
  test('ads stay disabled until configured and can be removed by entitlement', () {
    expect(const MonetizationState(removeAds: false).shouldShowAds(), isFalse);
    expect(
      const MonetizationState(removeAds: false).shouldShowAds(
        adsConfigured: true,
      ),
      isTrue,
    );
    expect(
      const MonetizationState(removeAds: true).shouldShowAds(
        adsConfigured: true,
      ),
      isFalse,
    );
  });
}
