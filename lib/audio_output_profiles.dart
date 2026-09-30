/// Stable keys for settings associated with a physical or virtual output.
String audioOutputProfileKey({String? routeName, String? routeType}) {
  final name = routeName?.trim().toLowerCase() ?? '';
  final type = routeType?.trim().toLowerCase() ?? '';
  if (name.isEmpty && type.isEmpty) return 'default';
  return '${type.isEmpty ? 'route' : type}|${name.isEmpty ? 'unnamed' : name}';
}
