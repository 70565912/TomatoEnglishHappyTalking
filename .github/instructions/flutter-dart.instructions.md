---
description: "Use when writing Flutter widgets, screens, or Dart classes. Covers null safety, widget patterns, theming, naming conventions, and common Flutter anti-patterns to avoid."
applyTo: "app/lib/**/*.dart"
---

# Flutter / Dart 编码规范

## Null Safety

- 禁止 `!` 强制解包，除非变量在逻辑上**确实不可为 null**（且注释说明原因）
- 优先用 `??`、`?.`、`if (x != null)` 守卫
- 函数参数能用 named + required 就用，避免位置参数歧义

```dart
// ✅ 好
final title = article?.title ?? '未命名';

// ❌ 避免
final title = article!.title;
```

## 异步代码

- 所有异步函数用 `async/await`，禁止裸 `.then().catchError()`
- 错误处理用 `try/catch`，在 catch 块中记录日志或返回 fallback

```dart
// ✅ 好
Future<String?> fetchData() async {
  try {
    final response = await dio.get('/endpoint');
    return response.data['text'] as String;
  } catch (e) {
    debugPrint('fetchData failed: $e');
    return null;
  }
}
```

## Widget 规范

- `StatelessWidget` 优先，只有需要本地 UI 状态时用 `ConsumerStatefulWidget`
- 用 `ConsumerWidget` 替代 `StatelessWidget` 当需要读取 Riverpod 状态
- Widget 不直接 `await` API——通过 Provider/AsyncValue 桥接

```dart
// ✅ 好
class ArticleCard extends ConsumerWidget {
  const ArticleCard({required this.articleId, super.key});
  final int articleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final article = ref.watch(articleProvider(articleId));
    return article.when(
      data: (a) => Text(a.title),
      loading: () => const CircularProgressIndicator(),
      error: (e, _) => Text('加载失败'),
    );
  }
}
```

## 命名规范

| 类型 | 风格 | 示例 |
|------|------|------|
| 类 / Widget | `UpperCamelCase` | `FollowReadScreen` |
| 文件 | `snake_case` | `follow_read_screen.dart` |
| 变量 / 函数 | `lowerCamelCase` | `fetchArticle()` |
| 常量 | `lowerCamelCase` | `const maxSentences = 20` |
| Screen 文件 | `xxx_screen.dart` | `chat_screen.dart` |

## 主题与样式

- 颜色始终从 `AppTheme` 取，**不要**硬编码颜色值
- 字体始终用 `GoogleFonts.nunito()`
- 间距用 `8` 的倍数（8, 16, 24, 32）

```dart
// ✅ 好
color: AppTheme.primary       // #FF6B35
color: AppTheme.darkBlue      // #1A237E
style: GoogleFonts.nunito(fontSize: 16)

// ❌ 避免
color: const Color(0xFFFF6B35)  // 硬编码
```

## 文件组织

每个 feature 目录结构：
```
features/follow_read/
├── follow_read_screen.dart       # 主屏 UI
├── providers/
│   └── follow_read_provider.dart # Riverpod providers
└── widgets/
    └── sentence_card.dart        # 局部 widget
```
