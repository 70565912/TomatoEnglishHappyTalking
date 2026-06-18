import 'dart:convert';

class BookCharacter {
  const BookCharacter({
    required this.name,
    required this.description,
  });

  final String name;
  final String description;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
      };

  BookCharacter copyWith({
    String? name,
    String? description,
  }) =>
      BookCharacter(
        name: name ?? this.name,
        description: description ?? this.description,
      );

  factory BookCharacter.fromJson(Object? raw) {
    if (raw is! Map) {
      return const BookCharacter(name: '', description: '');
    }
    return BookCharacter(
      name: raw['name']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
    );
  }

  static List<BookCharacter> listFromJsonText(String? text) {
    if (text == null || text.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        return decoded
            .map(BookCharacter.fromJson)
            .where((item) =>
                item.name.trim().isNotEmpty &&
                item.description.trim().isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      return const [];
    }
    return const [];
  }

  static String listToJsonText(List<BookCharacter> characters) => jsonEncode([
        for (final character in characters)
          {
            'name': character.name,
            'description': character.description,
          },
      ]);
}

class StorySeries {
  const StorySeries({
    this.id,
    required this.title,
    this.description = '',
    this.characters = const [],
    this.coverImagePath,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String title;
  final String description;
  final List<BookCharacter> characters;
  final String? coverImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'description': description,
        'characters_json': BookCharacter.listToJsonText(characters),
        'cover_image_path': coverImagePath,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'characters': characters.map((item) => item.toJson()).toList(),
        'coverImagePath': coverImagePath,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  StorySeries copyWith({
    int? id,
    String? title,
    String? description,
    List<BookCharacter>? characters,
    String? coverImagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      StorySeries(
        id: id ?? this.id,
        title: title ?? this.title,
        description: description ?? this.description,
        characters: characters ?? this.characters,
        coverImagePath: coverImagePath ?? this.coverImagePath,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory StorySeries.fromMap(Map<String, dynamic> map) => StorySeries(
        id: (map['id'] as num?)?.toInt(),
        title: map['title'] as String,
        description: map['description'] as String? ?? '',
        characters:
            BookCharacter.listFromJsonText(map['characters_json'] as String?),
        coverImagePath: map['cover_image_path'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}

class StoryChapter {
  const StoryChapter({
    this.id,
    required this.seriesId,
    required this.articleId,
    required this.chapterOrder,
    required this.chapterTitle,
    required this.summaryJson,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final int seriesId;
  final int articleId;
  final int chapterOrder;
  final String chapterTitle;
  final String summaryJson;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'series_id': seriesId,
        'article_id': articleId,
        'chapter_order': chapterOrder,
        'chapter_title': chapterTitle,
        'summary_json': summaryJson,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  Map<String, dynamic> toJson(StorySeries? series) => {
        'id': id,
        'seriesId': seriesId,
        'articleId': articleId,
        'chapterOrder': chapterOrder,
        'chapterTitle': chapterTitle,
        'summary': _decodeJsonObject(summaryJson),
        if (series != null) 'series': series.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  StoryChapter copyWith({
    int? id,
    int? seriesId,
    int? articleId,
    int? chapterOrder,
    String? chapterTitle,
    String? summaryJson,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      StoryChapter(
        id: id ?? this.id,
        seriesId: seriesId ?? this.seriesId,
        articleId: articleId ?? this.articleId,
        chapterOrder: chapterOrder ?? this.chapterOrder,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        summaryJson: summaryJson ?? this.summaryJson,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory StoryChapter.fromMap(Map<String, dynamic> map) => StoryChapter(
        id: (map['id'] as num?)?.toInt(),
        seriesId: (map['series_id'] as num).toInt(),
        articleId: (map['article_id'] as num).toInt(),
        chapterOrder: (map['chapter_order'] as num).toInt(),
        chapterTitle: map['chapter_title'] as String,
        summaryJson: map['summary_json'] as String? ?? '{}',
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}

class PictureBookPage {
  const PictureBookPage({
    this.id,
    required this.articleId,
    this.seriesId,
    required this.pageIndex,
    required this.sentenceStartIndex,
    required this.sentenceEndIndex,
    required this.paragraphText,
    required this.promptJson,
    this.imageCacheKey,
    this.imagePath,
    required this.status,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final int articleId;
  final int? seriesId;
  final int pageIndex;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String paragraphText;
  final String promptJson;
  final String? imageCacheKey;
  final String? imagePath;
  final String status;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'article_id': articleId,
        'series_id': seriesId,
        'page_index': pageIndex,
        'sentence_start_index': sentenceStartIndex,
        'sentence_end_index': sentenceEndIndex,
        'paragraph_text': paragraphText,
        'prompt_json': promptJson,
        'image_cache_key': imageCacheKey,
        'image_path': imagePath,
        'status': status,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'articleId': articleId,
        'seriesId': seriesId,
        'pageIndex': pageIndex,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'paragraphText': paragraphText,
        'prompt': _decodeJsonObject(promptJson),
        'imagePath': imagePath,
        'status': status,
        'errorMessage': errorMessage,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  PictureBookPage copyWith({
    int? id,
    int? articleId,
    int? seriesId,
    int? pageIndex,
    int? sentenceStartIndex,
    int? sentenceEndIndex,
    String? paragraphText,
    String? promptJson,
    String? imageCacheKey,
    String? imagePath,
    String? status,
    String? errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      PictureBookPage(
        id: id ?? this.id,
        articleId: articleId ?? this.articleId,
        seriesId: seriesId ?? this.seriesId,
        pageIndex: pageIndex ?? this.pageIndex,
        sentenceStartIndex: sentenceStartIndex ?? this.sentenceStartIndex,
        sentenceEndIndex: sentenceEndIndex ?? this.sentenceEndIndex,
        paragraphText: paragraphText ?? this.paragraphText,
        promptJson: promptJson ?? this.promptJson,
        imageCacheKey: imageCacheKey ?? this.imageCacheKey,
        imagePath: imagePath ?? this.imagePath,
        status: status ?? this.status,
        errorMessage: errorMessage ?? this.errorMessage,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory PictureBookPage.fromMap(Map<String, dynamic> map) => PictureBookPage(
        id: (map['id'] as num?)?.toInt(),
        articleId: (map['article_id'] as num).toInt(),
        seriesId: (map['series_id'] as num?)?.toInt(),
        pageIndex: (map['page_index'] as num).toInt(),
        sentenceStartIndex: (map['sentence_start_index'] as num).toInt(),
        sentenceEndIndex: (map['sentence_end_index'] as num).toInt(),
        paragraphText: map['paragraph_text'] as String,
        promptJson: map['prompt_json'] as String? ?? '{}',
        imageCacheKey: map['image_cache_key'] as String?,
        imagePath: map['image_path'] as String?,
        status: map['status'] as String,
        errorMessage: map['error_message'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}

Map<String, dynamic> _decodeJsonObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    // Keep corrupted optional metadata from breaking user-facing article reads.
  }
  return <String, dynamic>{};
}
