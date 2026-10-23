enum LocalVideoFolderType { disk, virtual }

class LocalVideoFolder {
  const LocalVideoFolder({
    required this.id,
    required this.name,
    required this.type,
    this.parentId,
    this.directoryPath,
    this.videoIds = const [],
  });

  final String id;
  final String name;
  final LocalVideoFolderType type;
  final String? parentId;
  final String? directoryPath;
  final List<String> videoIds;

  bool get isDisk => type == LocalVideoFolderType.disk;
  bool get isVirtual => type == LocalVideoFolderType.virtual;

  factory LocalVideoFolder.fromJson(Map<String, dynamic> json) {
    return LocalVideoFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      type: LocalVideoFolderType.values.byName(json['type'] as String),
      parentId: json['parentId'] as String?,
      directoryPath: json['directoryPath'] as String?,
      videoIds: (json['videoIds'] as List<dynamic>? ?? const []).cast<String>(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'parentId': parentId,
    'directoryPath': directoryPath,
    'videoIds': videoIds,
  };

  LocalVideoFolder copyWith({
    String? name,
    String? parentId,
    List<String>? videoIds,
  }) {
    return LocalVideoFolder(
      id: id,
      name: name ?? this.name,
      type: type,
      parentId: parentId ?? this.parentId,
      directoryPath: directoryPath,
      videoIds: videoIds ?? this.videoIds,
    );
  }
}
