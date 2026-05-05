---
description: "Use when adding or refactoring a Tomato English Happy Talking cloud API service class. Follow the existing service/provider pattern, keep API configuration in AppConfig, and align with the current project scripts and settings flow."
argument-hint: "Service name and API description (e.g. 'vocabulary lookup using Free Dictionary API')"
agent: "agent"
tools: [read, edit, search]
---

为「Tomato English Happy Talking」项目新建一个云 API Service 类。

## 先对齐当前项目事实

- 服务文件目录：`app/lib/services/`
- 配置存取入口：`app/lib/core/config/app_config.dart`
- 若新增用户可配置 API Key，通常还要同步更新：`app/lib/features/profile/profile_screen.dart`
- 不要为了验证服务逻辑去改构建链；如确需运行验证，优先复用仓库根目录脚本

## 需要生成的内容

在 `app/lib/services/<service_name>_service.dart` 创建 Service 类，并在 `app/lib/core/config/app_config.dart` 中视需要添加 API Key 存储方法。

## Service 类模板

```dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';

class <ServiceName>Service {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// 主方法：[参数说明]
  /// 返回 null 表示 API Key 未配置（mock fallback）
  Future<<ReturnType>?> <methodName>(<params>) async {
    final apiKey = await AppConfig.instance.<keyGetter>;
    if (apiKey == null) return _mockResult(<params>);

    try {
      final response = await _dio.<method>(
        '<endpoint>',
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
        data: { /* request body */ },
      );
      return _parseResponse(response.data);
    } on DioException catch (e) {
      debugPrint('[<ServiceName>Service] request failed: ${e.message}');
      return null;
    }
  }

  <ReturnType> _parseResponse(dynamic data) {
    // 解析 JSON → Dart 模型
  }

  <ReturnType> _mockResult(<params>) {
    // 返回虚假数据，方便无 Key 时本地开发
  }
}
```

## Riverpod 注册

在 service 文件底部添加 Provider：

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
part '<service_name>_service.g.dart';

@Riverpod(keepAlive: true)
<ServiceName>Service <serviceName>Service(<ServiceName>ServiceRef ref) {
  return <ServiceName>Service();
}
```

## 约束

- 只用 `dio` 做 HTTP，不引入其他 HTTP 库
- API Key 必须通过 `AppConfig` 读取，绝不硬编码
- mock fallback 返回合理的假数据，结构与真实 API 一致
- 返回 Dart 模型类，不返回原始 `Map<String, dynamic>`
- 错误时打印日志（`debugPrint`）并返回 null 或 fallback，不抛给 Widget 层
- 不要修改 `pubspec.yaml` 中已有依赖版本，除非任务明确要求引入新依赖
- 若服务需要 UI 入口或配置入口，优先沿用当前项目的 Profile 设置页与 Riverpod 注入方式
