import '../core/config/app_config.dart';
import 'aliyun_wanx_image_service.dart';
import 'volc_image_service.dart';

class PictureBookImageService {
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
