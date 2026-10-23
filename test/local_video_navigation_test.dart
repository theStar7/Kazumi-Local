import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/router.dart';

void main() {
  test('Windows inserts local videos between collect and my', () {
    final routes = menuForPlatform(isWindows: true);
    expect(routes.menuList.map((item) => item.path), [
      '/popular',
      '/timeline',
      '/collect',
      '/local',
      '/my',
    ]);
    expect(routes.indexForPath('/tab/local/'), 3);
    expect(routes.indexForPath('/tab/my/'), 4);
    expect(routes.getPath(3), '/local');
  });

  test('other platforms preserve original navigation indices', () {
    final routes = menuForPlatform(isWindows: false);
    expect(routes.menuList.map((item) => item.path), [
      '/popular',
      '/timeline',
      '/collect',
      '/my',
    ]);
    expect(routes.indexForPath('/tab/my/'), 3);
    expect(routes.indexForPath('/tab/local/'), 0);
  });
}
