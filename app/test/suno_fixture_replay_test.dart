import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_automation_state.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_completion_policy.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_create_batch.dart';

void main() {
  final fixtureDir = Directory('test/fixtures/suno');
  final fixtures = fixtureDir
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('suno replay fixtures', () {
    for (final file in fixtures) {
      test(file.uri.pathSegments.last, () {
        final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(map['schema'], 'tomato_suno_replay_fixture_v1');

        final automation = map['automation'] as Map<String, dynamic>;
        final completion = map['completion'] as Map<String, dynamic>;
        final expected = map['expected'] as Map<String, dynamic>? ?? {};

        final batch = _batchFromJson(automation['batch'] as Map<String, dynamic>);
        batch.absorbCreateSidebarUrls(
          _stringList(completion['createSidebarSongUrls']),
        );
        if ((map['pageKind'] ?? '') == 'create') {
          batch.absorbCreateSidebarUrls(
            _stringList(completion['candidateSongUrls']),
          );
        }

        if (expected.containsKey('batchPendingCount')) {
          expect(
            batch.pendingCount,
            expected['batchPendingCount'],
            reason: map['id']?.toString(),
          );
        }

        final state = SunoAutomationState()
          ..createSubmitted = automation['createSubmitted'] == true
          ..existingDownloadOnly = automation['existingDownloadOnly'] == true
          ..createBaselineVersionCount =
              (automation['createBaselineVersionCount'] as num?)?.toInt() ?? 0
          ..statusKey = (automation['statusKey'] ?? '').toString()
          ..libraryScanSettled = automation['libraryScanSettled'] == true
          ..mightHaveMoreLibraryRows =
              automation['mightHaveMoreLibraryRows'] == true
          ..createBatch = batch;
        state.detectedSongUrls.addAll(batch.downloadedUrls);
        state.downloadedSongUrls.addAll(batch.downloadedUrls);

        final versionsCount = (automation['versionsCount'] as num?)?.toInt() ?? 0;
        for (var i = 0; i < versionsCount; i++) {
          state.versions.add(
            ArticleSongVersion(
              id: 'replay_$i',
              audioPath: '/tmp/replay_$i.mp3',
              songUrl: 'https://suno.com/song/replay-$i',
            ),
          );
        }

        final policy = const SunoCompletionPolicy();
        if (expected.containsKey('completeAllowed')) {
          expect(
            policy.canComplete(state),
            expected['completeAllowed'],
            reason: map['id']?.toString(),
          );
        }
        if (expected.containsKey('completeBlockReason') &&
            expected['completeBlockReason'] != 'none') {
          final reasonName = expected['completeBlockReason'].toString();
          final reason = SunoCompleteBlockReason.values.firstWhere(
            (value) => value.name == reasonName,
            orElse: () => SunoCompleteBlockReason.none,
          );
          expect(policy.blockReason(state), reason, reason: map['id']?.toString());
        }
      });
    }
  });
}

SunoCreateBatch _batchFromJson(Map<String, dynamic> json) {
  return SunoCreateBatch(
    preCreateUrls: _stringSet(json['preCreateUrls']),
    pendingUrls: _stringSet(json['pendingUrls']),
    downloadedUrls: _stringSet(json['downloadedUrls']),
  );
}

Set<String> _stringSet(Object? value) {
  if (value is! List) {
    return {};
  }
  return value.map((item) => item.toString()).toSet();
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map((item) => item.toString()).toList();
}
