import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android background playback declares notification permission',
    () async {
      final manifest = await File('android/app/src/main/AndroidManifest.xml')
          .readAsString();
      expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));

      final activity = await File(
        'android/app/src/main/kotlin/com/neonamp/neonamp/MainActivity.kt',
      ).readAsString();
      expect(activity, contains('Manifest.permission.POST_NOTIFICATIONS'));
      expect(activity, contains('Build.VERSION_CODES.TIRAMISU'));
    },
  );
}
