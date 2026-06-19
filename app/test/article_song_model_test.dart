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
      submittedLyrics: 'hello\nsong',
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
    expect(decoded?.submittedLyrics, 'hello\nsong');
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
      lyricsCompressed: true,
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
    expect(json['lyricsCompressed'], isTrue);
    expect(json['versions'], hasLength(1));
  });

  test('preserves external audio song source', () {
    const version = ArticleSongVersion(
      id: 'external_audio_hash',
      audioPath: r'F:\songs\imported.mp3',
      title: 'imported',
      source: 'external_audio',
      submittedLyrics: 'hello song',
      timelineStatus: 'missing',
      isDefault: true,
    );

    final json = version.toJson();
    expect(json['source'], 'external_audio');
    expect(json['timelineStatus'], 'missing');

    final decoded = ArticleSongVersion.fromJson(json);
    expect(decoded?.source, 'external_audio');
    expect(decoded?.title, 'imported');
    expect(decoded?.submittedLyrics, 'hello song');
    expect(decoded?.isDefault, isTrue);
  });

  test('builds lyrics-based Suno cache groups', () {
    final legacy = SunoCachedSongGroupBuilder(
      lyricsHash: 'lyrics-a',
      stylePrompt: '',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'legacy',
            audioPath: r'F:\songs\legacy.mp3',
            title: 'Suno 缓存版本',
            lyricsHash: 'lyrics-a',
          ),
        ],
      );
    final storybook = SunoCachedSongGroupBuilder(
      lyricsHash: 'lyrics-a',
      stylePrompt: 'storybook pop',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'storybook-1',
            audioPath: r'F:\songs\storybook-1.mp3',
            songUrl: 'https://suno.com/song/storybook-1',
            stylePrompt: 'storybook pop',
            lyricsHash: 'lyrics-a',
          ),
        ],
      );
    final folk = SunoCachedSongGroupBuilder(
      lyricsHash: 'lyrics-b',
      stylePrompt: 'folk lullaby',
    )..addVersions(
        const [
          ArticleSongVersion(
            id: 'folk-1',
            audioPath: r'F:\songs\folk-1.mp3',
            songUrl: 'https://suno.com/song/folk-1',
            stylePrompt: 'folk lullaby',
            lyricsHash: 'lyrics-b',
          ),
        ],
      );

    final groups = [legacy.build(), storybook.build(), folk.build()];

    expect(groups.map((group) => group.lyricsHash), [
      'lyrics-a',
      'lyrics-a',
      'lyrics-b',
    ]);
    expect(groups.first.versions.single.id, 'legacy');
    expect(groups.first.hasKnownCompleteDownloads, isFalse);
    expect(groups[1].versions.single.stylePrompt, 'storybook pop');
    expect(groups[2].versions.single.stylePrompt, 'folk lullaby');
  });

  test('tracks detected Suno full song URLs and skips duplicate downloads', () {
    final group = SunoCachedSongGroupBuilder(
      lyricsHash: 'lyrics-a',
      stylePrompt: 'storybook pop',
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
