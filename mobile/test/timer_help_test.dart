import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timers_screen.dart';

void main() {
  test('Bluetooth failure text gives actionable permission, power and timeout steps', () {
    expect(
      timerErrorMessage(
        Exception('SecurityException: BLUETOOTH_SCAN permission'),
      ),
      contains('разрешения'),
    );
    expect(
      timerErrorMessage(Exception('Bluetooth adapter is off')),
      contains('выключен'),
    );
    expect(
      timerErrorMessage(Exception('connect timed out')),
      contains('другого приложения'),
    );
  });
  test(
    'unrecognized failures remain errors rather than successful connection',
    () {
      expect(
        timerErrorMessage(Exception('Gatt error 133')),
        contains('Не удалось'),
      );
      expect(
        timerErrorMessage(Exception('Gatt error 133')),
        contains('подробностях'),
      );
    },
  );
}
