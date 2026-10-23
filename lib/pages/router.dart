import 'dart:io';

class MenuRouteItem {
  const MenuRouteItem({required this.path});

  final String path;
}

class MenuRoute {
  const MenuRoute(this.menuList);

  final List<MenuRouteItem> menuList;

  String getPath(int index) => menuList[index].path;

  int indexForPath(String path) {
    final index = menuList.indexWhere(
      (item) =>
          path == '/tab${item.path}' ||
          path == '/tab${item.path}/' ||
          path.startsWith('/tab${item.path}/'),
    );
    return index < 0 ? 0 : index;
  }
}

MenuRoute menuForPlatform({required bool isWindows}) => MenuRoute([
  MenuRouteItem(path: '/popular'),
  MenuRouteItem(path: '/timeline'),
  MenuRouteItem(path: '/collect'),
  if (isWindows) MenuRouteItem(path: '/local'),
  MenuRouteItem(path: '/my'),
]);

final MenuRoute menu = menuForPlatform(isWindows: Platform.isWindows);
