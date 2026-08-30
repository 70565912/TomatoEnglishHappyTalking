import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/recording_export_service.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';

void main() {
  test('maps lyric line indexes to post-split sentence slots', () {
    const sentences = [
      'A.',
      'B.',
      'C.',
      'D.',
      'E.',
      'F.',
      'G.',
      'H.',
    ];
    final timeline = SongSubtitleTimeline(
      version: 1,
      articleId: 49,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 8000,
      source: 'suno',
      cues: [
        SongSubtitleCue(
          lineIndex: 0,
          startMs: 0,
          endMs: 1000,
          english: 'A.',
        ),
        SongSubtitleCue(
          lineIndex: 1,
          startMs: 1000,
          endMs: 2000,
          english: 'B.',
        ),
        SongSubtitleCue(
          lineIndex: 2,
          startMs: 2000,
          endMs: 3000,
          english: 'C.',
        ),
        SongSubtitleCue(
          lineIndex: 3,
          startMs: 3000,
          endMs: 4000,
          english: 'D.',
        ),
        SongSubtitleCue(
          lineIndex: 4,
          startMs: 4000,
          endMs: 5000,
          english: 'E.',
        ),
      ],
    );
    final pages = [
      _page(pageIndex: 0, start: 0, end: 2),
      _page(pageIndex: 1, start: 3, end: 4),
      _page(pageIndex: 2, start: 5, end: 7),
    ];

    final assignments = RecordingExportService.songPageAssignmentsForTest(
      sentences: sentences,
      pages: pages,
      timeline: timeline,
    );

    expect(
      assignments.map((row) => row['pageIndex']),
      [0, 0, 0, 1, 2],
    );
  });

  test('uses trailing pages when old lyric lines stop before last page', () {
    final sentences = [
      for (var i = 0; i < 55; i += 1) 'Sentence $i.',
    ];
    final cues = <SongSubtitleCue>[
      for (var i = 0; i < 49; i += 1)
        SongSubtitleCue(
          lineIndex: i,
          startMs: i * 1000,
          endMs: (i + 1) * 1000,
          english: 'Sentence $i.',
        ),
    ];
    final timeline = SongSubtitleTimeline(
      version: 1,
      articleId: 49,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 49000,
      source: 'suno',
      cues: cues,
    );
    final pages = [
      _page(pageIndex: 0, start: 0, end: 10),
      _page(pageIndex: 1, start: 11, end: 20),
      _page(pageIndex: 2, start: 21, end: 30),
      _page(pageIndex: 3, start: 31, end: 40),
      _page(pageIndex: 4, start: 41, end: 48),
      _page(pageIndex: 5, start: 49, end: 52),
      _page(pageIndex: 6, start: 53, end: 54),
    ];

    final assignments = RecordingExportService.songPageAssignmentsForTest(
      sentences: sentences,
      pages: pages,
      timeline: timeline,
    );

    expect(assignments.last['pageIndex'], 6);
    expect(
      assignments.map((row) => row['pageIndex']).toSet(),
      {0, 1, 2, 3, 4, 5, 6},
    );
  });

  test('preserves hidden sentence slot coordinates when mapping lyrics', () {
    const sentences = ['Alpha.', '', 'Gamma.', 'Delta.'];
    final timeline = SongSubtitleTimeline(
      version: 1,
      articleId: 1,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 4000,
      source: 'suno',
      cues: [
        SongSubtitleCue(
          lineIndex: 0,
          startMs: 0,
          endMs: 1000,
          english: 'Alpha.',
        ),
        SongSubtitleCue(
          lineIndex: 1,
          startMs: 1000,
          endMs: 2000,
          english: 'Gamma.',
        ),
        SongSubtitleCue(
          lineIndex: 2,
          startMs: 2000,
          endMs: 3000,
          english: 'Delta.',
        ),
      ],
    );
    final pages = [
      _page(pageIndex: 0, start: 0, end: 0),
      _page(pageIndex: 1, start: 2, end: 3),
    ];

    final indexes = RecordingExportService.sentenceIndexesForSongCuesForTest(
      sentences: sentences,
      timeline: timeline,
    );

    expect(indexes, [0, 2, 3]);
    final assignments = RecordingExportService.songPageAssignmentsForTest(
      sentences: sentences,
      pages: pages,
      timeline: timeline,
    );
    expect(assignments.map((row) => row['pageIndex']), [0, 1, 1]);
  });
}

PictureBookPage _page({
  required int pageIndex,
  required int start,
  required int end,
}) {
  final now = DateTime.utc(2026, 8, 18);
  return PictureBookPage(
    articleId: 1,
    pageIndex: pageIndex,
    sentenceStartIndex: start,
    sentenceEndIndex: end,
    paragraphText: 'scene',
    promptJson: '{}',
    status: 'ready',
    createdAt: now,
    updatedAt: now,
  );
}
