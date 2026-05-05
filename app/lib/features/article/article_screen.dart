import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../home/providers/home_provider.dart';
import 'providers/article_provider.dart';

class ArticleScreen extends ConsumerWidget {
  const ArticleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formState = ref.watch(articleFormProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('添加文章'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '粘贴英文文章，App 将自动分句并开始练习',
              style: GoogleFonts.nunito(color: Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            TextField(
              decoration: const InputDecoration(
                labelText: '文章标题 *',
                hintText: 'e.g. The Tortoise and the Hare',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
              style: GoogleFonts.nunito(),
              textInputAction: TextInputAction.next,
              onChanged: (v) =>
                  ref.read(articleFormProvider.notifier).setTitle(v),
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                labelText: '文章内容（英文）*',
                hintText: '在此粘贴英文文章...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                filled: true,
                fillColor: Colors.white,
              ),
              maxLines: 14,
              style: GoogleFonts.nunito(fontSize: 14, height: 1.6),
              onChanged: (v) =>
                  ref.read(articleFormProvider.notifier).setContent(v),
            ),
            if (formState.error != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Colors.red),
                  const SizedBox(width: 6),
                  Text(
                    formState.error!,
                    style: GoogleFonts.nunito(color: Colors.red[700]),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: formState.isSaving
                  ? null
                  : () async {
                      final ok = await ref
                          .read(articleFormProvider.notifier)
                          .save();
                      if (ok && context.mounted) {
                        // Refresh article list on home screen
                        ref.invalidate(articleListProvider);
                        context.go('/');
                      }
                    },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: formState.isSaving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      '保存文章',
                      style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
