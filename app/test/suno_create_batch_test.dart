import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_create_batch.dart';

void main() {
  test('nextPending skips excluded urls', () {
    final batch = SunoCreateBatch(
      pendingUrls: {
        'https://suno.com/song/a',
        'https://suno.com/song/b',
      },
    );
    expect(
      batch.nextPending(exclude: {'https://suno.com/song/a'}),
      'https://suno.com/song/b',
    );
  });

  test('pre-create snapshot prevents pending reuse', () {
    final batch = SunoCreateBatch();
    batch.markPreCreateUrls(['https://suno.com/song/old']);
    batch.absorbCreateSidebarUrls([
      'https://suno.com/song/old',
      'https://suno.com/song/new',
    ]);
    expect(batch.pendingUrls, {'https://suno.com/song/new'});
  });
}
