import '../core/config/app_config.dart';
import 'aliyun_wanx_image_service.dart';
import 'volc_image_service.dart';

class PictureBookImageService {
  /// Product cap for AI sequential group generation (Wanx continuous group).
  static const int maxAiGroupSceneCount = 12;

  static String aiGroupSceneCountExceededMessage(int sceneCount) =>
      'AI 组图最多支持 $maxAiGroupSceneCount 个场景（万相连续组图上限），当前为 $sceneCount 个。请减少分镜后再确认出图；本地导入图片不受此限制。';

  static Future<List<VolcImageResult>> generatePictureBookImageGroup({
    required List<VolcImageBatchRequest> requests,
    int? articleId,
    int? seriesId,
    List<String> referenceImagePaths = const [],
    String? groupPromptOverride,
    String cachePurpose = 'picture_book_image',
    bool useSequential = false,
    bool reusePartialCache = true,
    bool cacheOnly = false,
  }) async {
    if (requests.length > maxAiGroupSceneCount) {
      throw FormatException(
        aiGroupSceneCountExceededMessage(requests.length),
      );
    }
    final provider = await AppConfig.imageProvider;
    if (provider == AppConfig.aiProviderVolcengine) {
      return VolcImageService.generatePictureBookImageGroup(
        requests: requests,
        articleId: articleId,
        seriesId: seriesId,
        referenceImagePaths: referenceImagePaths,
        groupPromptOverride: groupPromptOverride,
        cachePurpose: cachePurpose,
        useSequential: useSequential,
        reusePartialCache: reusePartialCache,
        cacheOnly: cacheOnly,
      );
    }

    return AliyunWanxImageService.generatePictureBookImageGroup(
      requests: requests,
      articleId: articleId,
      seriesId: seriesId,
      referenceImagePaths: referenceImagePaths,
      groupPromptOverride: groupPromptOverride,
      cachePurpose: cachePurpose,
      useSequential: useSequential || requests.length > 1,
      reusePartialCache: reusePartialCache,
      cacheOnly: cacheOnly,
    );
  }
}
