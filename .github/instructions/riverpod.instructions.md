---
description: "Use when writing Riverpod providers, state classes, or AsyncNotifiers. Covers @riverpod annotation style, AsyncValue handling, provider scoping, and state update patterns for this project."
applyTo: "app/lib/**/providers/**/*.dart"
---

# Riverpod 状态管理规范

## Provider 定义风格

本项目使用 **代码生成风格**（`riverpod_annotation`），统一用 `@riverpod` 注解：

```dart
// ✅ 好：代码生成风格
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'article_provider.g.dart';

@riverpod
class ArticleNotifier extends _$ArticleNotifier {
  @override
  Future<List<Article>> build() async {
    return ref.read(databaseServiceProvider).getArticles();
  }

  Future<void> addArticle(Article article) async {
    await ref.read(databaseServiceProvider).saveArticle(article);
    ref.invalidateSelf();  // 触发重新加载
  }
}

// ❌ 避免：手写 Provider（老风格）
final articleProvider = StateNotifierProvider<ArticleNotifier, List<Article>>(
  (ref) => ArticleNotifier(),
);
```

## AsyncValue 处理

UI 中始终处理三种状态：

```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  final articlesAsync = ref.watch(articleNotifierProvider);

  return articlesAsync.when(
    data: (articles) => ArticleList(articles: articles),
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, stack) => ErrorView(message: error.toString()),
  );
}
```

## Provider 粒度

| 场景 | 推荐 Provider 类型 |
|------|-------------------|
| 只读数据（列表、详情）| `@riverpod Future<T> build()` |
| 有增删改操作 | `@riverpod class XxxNotifier extends _$XxxNotifier` |
| 全局服务（Service 实例）| `@Riverpod(keepAlive: true)` |
| 页面级临时状态 | `@riverpod`（AutoDispose，默认）|

## Service 注入

Services 通过 Provider 注入，不要在 Notifier 内 `new` Service：

```dart
@Riverpod(keepAlive: true)
TtsService ttsService(TtsServiceRef ref) => TtsService();

// 在 Notifier 中使用
final tts = ref.read(ttsServiceProvider);
```

## 跟读模式 Provider 示例

```dart
@riverpod
class FollowReadNotifier extends _$FollowReadNotifier {
  @override
  FollowReadState build(int articleId) => const FollowReadState.initial();

  Future<void> playSentence(String text) async {
    state = state.copyWith(isLoading: true);
    final tts = ref.read(ttsServiceProvider);
    final audio = await tts.synthesize(text);
    state = state.copyWith(isLoading: false, audioBytes: audio);
  }

  Future<void> submitRecording(Uint8List wav, String refText) async {
    final scorer = ref.read(scoringServiceProvider);
    final result = await scorer.assess(wav, refText);
    state = state.copyWith(lastScore: result);
  }
}
```

## 注意事项

- `ref.read()` 用于**事件处理**（点击、提交），`ref.watch()` 用于 **build 方法**中监听
- 避免在 Provider 的 `build()` 外做副作用
- 跨页面共享状态用 `keepAlive: true`，页面独占状态用默认 AutoDispose
