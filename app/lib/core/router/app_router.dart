import 'package:go_router/go_router.dart';
import '../../features/home/home_screen.dart';
import '../../features/article/article_screen.dart';
import '../../features/follow_read/follow_read_screen.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/profile/profile_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/article/new',
      builder: (context, state) => const ArticleScreen(),
    ),
    GoRoute(
      path: '/follow-read/:articleId',
      builder: (context, state) {
        final articleId = int.parse(state.pathParameters['articleId']!);
        return FollowReadScreen(articleId: articleId);
      },
    ),
    GoRoute(
      path: '/chat/:articleId',
      builder: (context, state) {
        final articleId = int.parse(state.pathParameters['articleId']!);
        return ChatScreen(articleId: articleId);
      },
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfileScreen(),
    ),
  ],
);
