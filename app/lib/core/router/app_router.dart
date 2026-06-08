import 'package:go_router/go_router.dart';
import '../../features/web_shell/web_shell_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/article/new',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/follow/:articleId',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/follow-read/:articleId',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/listen/:articleId',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/chat/:articleId',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const WebShellScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const WebShellScreen(),
    ),
  ],
);
