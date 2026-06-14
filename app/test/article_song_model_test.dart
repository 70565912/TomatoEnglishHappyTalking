import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';

void main() {
  test('serializes Suno song version style grouping fields', () {
    const version = ArticleSongVersion(
      id: 'suno-v1',
      audioPath: r'F:\songs\suno-v1.mp3',
      title: 'Suno 版本 1',
      songUrl: 'https://suno.com/song/one',
      stylePrompt: 'storybook pop',
      styleKey: 'suno:storybook pop',
      lyricsHash: 'lyrics-hash',
      timelinePath: r'F:\songs\suno-v1.timeline.json',
      timelineStatus: 'ready',
      timelineConfidence: 0.92,
      isDefault: true,
    );

    final json = version.toJson();
    expect(json['stylePrompt'], 'storybook pop');
    expect(json['styleKey'], 'suno:storybook pop');
    expect(json['timelineStatus'], 'ready');
    expect(json['timelineConfidence'], 0.92);
    expect(json['isDefault'], isTrue);

    final decoded = ArticleSongVersion.fromJson(json);
    expect(decoded?.stylePrompt, 'storybook pop');
    expect(decoded?.styleKey, 'suno:storybook pop');
    expect(decoded?.lyricsHash, 'lyrics-hash');
    expect(decoded?.timelinePath, r'F:\songs\suno-v1.timeline.json');
    expect(decoded?.timelineStatus, 'ready');
    expect(decoded?.timelineConfidence, 0.92);
    expect(decoded?.isDefault, isTrue);
  });

  test('serializes Suno song state without legacy providers', () {
    const state = ArticleSongState(
      articleId: 12,
      status: 'ready',
      stylePrompt: 'storybook pop',
      source: 'suno',
      audioPath: r'F:\songs\suno-v1.mp3',
      detectedSongUrls: ['https://suno.com/song/one'],
      versions: [
        ArticleSongVersion(
          id: 'suno-v1',
          audioPath: r'F:\songs\suno-v1.mp3',
          songUrl: 'https://suno.com/song/one',
        ),
      ],
    );

    final json = state.toJson();
    expect(json['articleId'], 12);
    expect(json['source'], 'suno');
    expect(json['versions'], hasLength(1));
  });

  test('builds legacy and multi-style Suno cache groups', () {
    final legacy = SunoCachedSongGroupBuilder(
      stylePrompt: '',
      styleKey: 'suno:legacy',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'legacy',
            audioPath: r'F:\songs\legacy.mp3',
            title: 'Suno 缓存版本',
          ),
        ],
      );
    final storybook = SunoCachedSongGroupBuilder(
      stylePrompt: 'storybook pop',
      styleKey: 'suno:storybook pop',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'storybook-1',
            audioPath: r'F:\songs\storybook-1.mp3',
            songUrl: 'https://suno.com/song/storybook-1',
            stylePrompt: 'storybook pop',
            styleKey: 'suno:storybook pop',
          ),
        ],
      );
    final folk = SunoCachedSongGroupBuilder(
      stylePrompt: 'folk lullaby',
      styleKey: 'suno:folk lullaby',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'folk-1',
            audioPath: r'F:\songs\folk-1.mp3',
            songUrl: 'https://suno.com/song/folk-1',
            stylePrompt: 'folk lullaby',
            styleKey: 'suno:folk lullaby',
          ),
        ],
      );

    final groups = [legacy.build(), storybook.build(), folk.build()];

    expect(groups.map((group) => group.styleKey), [
      'suno:legacy',
      'suno:storybook pop',
      'suno:folk lullaby',
    ]);
    expect(groups.first.versions.single.id, 'legacy');
    expect(groups.first.hasKnownCompleteDownloads, isFalse);
    expect(groups[1].versions.single.stylePrompt, 'storybook pop');
    expect(groups[2].versions.single.stylePrompt, 'folk lullaby');
  });

  test('tracks detected Suno full song URLs and skips duplicate downloads', () {
    final group = SunoCachedSongGroupBuilder(
      stylePrompt: 'storybook pop',
      styleKey: 'suno:storybook pop',
    )
      ..detectedSongUrls.addAll([
        'https://suno.com/song/full-1',
        'https://suno.com/song/full-2',
      ])
      ..addVersions(
        const [
          ArticleSongVersion(
            id: 'full-1-a',
            audioPath: r'F:\songs\full-1-a.mp3',
            songUrl: 'https://suno.com/song/full-1',
          ),
          ArticleSongVersion(
            id: 'full-1-b',
            audioPath: r'F:\songs\full-1-b.mp3',
            songUrl: 'https://suno.com/song/full-1',
          ),
        ],
      );

    final partial = group.build();

    expect(partial.versions, hasLength(1));
    expect(partial.hasKnownCompleteDownloads, isFalse);
    expect(partial.missingSongUrls, ['https://suno.com/song/full-2']);

    group.addVersions(
      const [
        ArticleSongVersion(
          id: 'full-2',
          audioPath: r'F:\songs\full-2.mp3',
          songUrl: 'https://suno.com/song/full-2',
        ),
      ],
    );

    final complete = group.build();

    expect(complete.versions, hasLength(2));
    expect(complete.hasKnownCompleteDownloads, isTrue);
    expect(complete.missingSongUrls, isEmpty);
  });
}
