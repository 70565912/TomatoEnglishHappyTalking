import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';

/// TTS 服务 — 直接调用火山引擎 Doubao TTS 2.0 HTTP Chunked API。
/// 未配置或云端失败时抛出 [TtsException]，由 Provider 转成可展示的 UI 状态。

class VoiceInfo {
  final String id;
  final String name;
  final String lang;
  final String scene;
  final String? genderHint;

  const VoiceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.scene,
    this.genderHint,
  });

  String get gender {
    final hintedGender = _normalizeGender(genderHint);
    if (hintedGender != null) {
      return hintedGender;
    }
    if (id.contains('_female_') || id.contains('female')) {
      return 'female';
    }
    if (id.contains('_male_') || id.contains('male')) {
      return 'male';
    }
    final lower = id.toLowerCase();
    if (lower.contains('abby') ||
        lower.contains('annie') ||
        lower.contains('anhuan')) {
      return 'female';
    }
    if (lower.contains('andy') || lower.contains('anyang')) {
      return 'male';
    }
    return 'unknown';
  }

  static String? _normalizeGender(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (normalized == 'female' || normalized == 'woman') {
      return 'female';
    }
    if (normalized == 'male' || normalized == 'man') {
      return 'male';
    }
    if (normalized == 'neutral' || normalized == 'non-binary') {
      return 'neutral';
    }
    return null;
  }
}

class TtsException implements Exception {
  const TtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef ElevenLabsTtsPostOverride = Future<List<int>> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

typedef ElevenLabsVoicesGetOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
});

class VoiceCatalogFetchResult {
  const VoiceCatalogFetchResult({
    required this.voices,
    this.errorMessage,
  });

  final List<VoiceInfo> voices;
  final String? errorMessage;
}

class TtsService {
  static const defaultVoiceType = 'en_female_dacey_uranus_bigtts';
  static const defaultAliyunVoiceType = AppConfig.defaultAliyunBailianTtsVoice;
  static const defaultElevenLabsVoiceType =
      AppConfig.defaultElevenLabsTtsVoiceId;

  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static ElevenLabsTtsPostOverride? _elevenLabsPostOverrideForTest;
  static ElevenLabsVoicesGetOverride? _elevenLabsVoicesOverrideForTest;
  static VoiceCatalogFetchResult? _elevenLabsVoiceCatalogCache;
  static String? _elevenLabsVoiceCatalogCacheKey;
  static DateTime? _elevenLabsVoiceCatalogCacheAt;
  static const _elevenLabsVoiceCatalogCacheTtl = Duration(minutes: 10);

  @visibleForTesting
  static void setElevenLabsPostOverrideForTest(
    ElevenLabsTtsPostOverride? override,
  ) {
    _elevenLabsPostOverrideForTest = override;
  }

  @visibleForTesting
  static void setElevenLabsVoicesOverrideForTest(
    ElevenLabsVoicesGetOverride? override,
  ) {
    _elevenLabsVoicesOverrideForTest = override;
  }

  @visibleForTesting
  static void clearElevenLabsVoiceCatalogCacheForTest() {
    _clearElevenLabsVoiceCatalogCache();
  }

  static const List<VoiceInfo> voices = [
    VoiceInfo(
        id: 'zh_female_vv_uranus_bigtts',
        name: 'Vivi 2.0',
        lang: '中文、日文、印尼、墨西哥西班牙语',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_xiaohe_uranus_bigtts',
        name: '小何 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_m191_uranus_bigtts',
        name: '云舟 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_taocheng_uranus_bigtts',
        name: '小天 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_liufei_uranus_bigtts',
        name: '刘飞 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_sophie_uranus_bigtts',
        name: '魅力苏菲 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_qingxinnvsheng_uranus_bigtts',
        name: '清新女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_cancan_uranus_bigtts',
        name: '知性灿灿 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_sajiaoxuemei_uranus_bigtts',
        name: '撒娇学妹 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_tianmeixiaoyuan_uranus_bigtts',
        name: '甜美小源 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_tianmeitaozi_uranus_bigtts',
        name: '甜美桃子 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_shuangkuaisisi_uranus_bigtts',
        name: '爽快思思 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_peiqi_uranus_bigtts',
        name: '佩奇猪 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_female_linjianvhai_uranus_bigtts',
        name: '邻家女孩 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_shaonianzixin_uranus_bigtts',
        name: '少年梓辛/Brayan 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_sunwukong_uranus_bigtts',
        name: '猴哥 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_female_yingyujiaoxue_uranus_bigtts',
        name: 'Tina老师 2.0',
        lang: '中文、英式英语',
        scene: '教育场景'),
    VoiceInfo(
        id: 'zh_female_kefunvsheng_uranus_bigtts',
        name: '暖阳女声 2.0',
        lang: '中文',
        scene: '客服场景'),
    VoiceInfo(
        id: 'zh_female_xiaoxue_uranus_bigtts',
        name: '儿童绘本 2.0',
        lang: '中文',
        scene: '有声阅读'),
    VoiceInfo(
        id: 'zh_male_dayi_uranus_bigtts',
        name: '大壹 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_female_mizai_uranus_bigtts',
        name: '黑猫侦探社咪仔 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_female_jitangnv_uranus_bigtts',
        name: '鸡汤女 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_female_meilinvyou_uranus_bigtts',
        name: '魅力女友 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_liuchangnv_uranus_bigtts',
        name: '流畅女声 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'zh_male_ruyayichen_uranus_bigtts',
        name: '儒雅逸辰 2.0',
        lang: '中文',
        scene: '视频配音'),
    VoiceInfo(
        id: 'en_male_tim_uranus_bigtts',
        name: 'Tim',
        lang: '美式英语',
        scene: '多语种'),
    VoiceInfo(
        id: 'en_female_dacey_uranus_bigtts',
        name: 'Dacey',
        lang: '美式英语',
        scene: '多语种'),
    VoiceInfo(
        id: 'en_female_stokie_uranus_bigtts',
        name: 'Stokie',
        lang: '美式英语',
        scene: '多语种'),
    VoiceInfo(
        id: 'zh_female_wenroumama_uranus_bigtts',
        name: '温柔妈妈 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_jieshuoxiaoming_uranus_bigtts',
        name: '解说小明 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_tvbnv_uranus_bigtts',
        name: 'TVB女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_yizhipiannan_uranus_bigtts',
        name: '译制片男 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_qiaopinv_uranus_bigtts',
        name: '俏皮女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_zhishuaiyingzi_uranus_bigtts',
        name: '直率英子 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_linjiananhai_uranus_bigtts',
        name: '邻家男孩 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_silang_uranus_bigtts',
        name: '四郎 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_ruyaqingnian_uranus_bigtts',
        name: '儒雅青年 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_qingcang_uranus_bigtts',
        name: '擎苍 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_xionger_uranus_bigtts',
        name: '熊二 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_yingtaowanzi_uranus_bigtts',
        name: '樱桃丸子 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_wennuanahu_uranus_bigtts',
        name: '温暖阿虎/Alvin 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_naiqimengwa_uranus_bigtts',
        name: '奶气萌娃 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_popo_uranus_bigtts',
        name: '婆婆 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_gaolengyujie_uranus_bigtts',
        name: '高冷御姐 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_aojiaobazong_uranus_bigtts',
        name: '傲娇霸总 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_lanyinmianbao_uranus_bigtts',
        name: '懒音绵宝 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_fanjuanqingnian_uranus_bigtts',
        name: '反卷青年 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_wenroushunv_uranus_bigtts',
        name: '温柔淑女 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_gufengshaoyu_uranus_bigtts',
        name: '古风少御 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_huolixiaoge_uranus_bigtts',
        name: '活力小哥 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_baqiqingshu_uranus_bigtts',
        name: '霸气青叔 2.0',
        lang: '中文',
        scene: '有声阅读'),
    VoiceInfo(
        id: 'zh_male_xuanyijieshuo_uranus_bigtts',
        name: '悬疑解说 2.0',
        lang: '中文',
        scene: '有声阅读'),
    VoiceInfo(
        id: 'zh_female_mengyatou_uranus_bigtts',
        name: '萌丫头/Cutey 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_tiexinnvsheng_uranus_bigtts',
        name: '贴心女声/Candy 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_jitangmei_uranus_bigtts',
        name: '鸡汤妹妹/Hope 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_cixingjieshuonan_uranus_bigtts',
        name: '磁性解说男声/Morgan 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_liangsangmengzai_uranus_bigtts',
        name: '亮嗓萌仔 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_kailangjiejie_uranus_bigtts',
        name: '开朗姐姐 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_gaolengchenwen_uranus_bigtts',
        name: '高冷沉稳 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_shenyeboke_uranus_bigtts',
        name: '深夜播客 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_lubanqihao_uranus_bigtts',
        name: '鲁班七号 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_jiaochuannv_uranus_bigtts',
        name: '娇喘女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_linxiao_uranus_bigtts',
        name: '林潇 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_lingling_uranus_bigtts',
        name: '玲玲姐姐 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_chunribu_uranus_bigtts',
        name: '春日部姐姐 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_tangseng_uranus_bigtts',
        name: '唐僧 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_zhuangzhou_uranus_bigtts',
        name: '庄周 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_kailangdidi_uranus_bigtts',
        name: '开朗弟弟 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_zhubajie_uranus_bigtts',
        name: '猪八戒 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_ganmaodianyin_uranus_bigtts',
        name: '感冒电音姐姐 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_chanmeinv_uranus_bigtts',
        name: '谄媚女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_nvleishen_uranus_bigtts',
        name: '女雷神 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_qinqienv_uranus_bigtts',
        name: '亲切女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_kuailexiaodong_uranus_bigtts',
        name: '快乐小东 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_kailangxuezhang_uranus_bigtts',
        name: '开朗学长 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_youyoujunzi_uranus_bigtts',
        name: '悠悠君子 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_wenjingmaomao_uranus_bigtts',
        name: '文静毛毛 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_zhixingnv_uranus_bigtts',
        name: '知性女声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_qingshuangnanda_uranus_bigtts',
        name: '清爽男大 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_yuanboxiaoshu_uranus_bigtts',
        name: '渊博小叔 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_yangguangqingnian_uranus_bigtts',
        name: '阳光青年 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_qingchezizi_uranus_bigtts',
        name: '清澈梓梓 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_tianmeiyueyue_uranus_bigtts',
        name: '甜美悦悦 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_xinlingjitang_uranus_bigtts',
        name: '心灵鸡汤 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_wenrouxiaoge_uranus_bigtts',
        name: '温柔小哥 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_roumeinvyou_uranus_bigtts',
        name: '柔美女友 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_dongfanghaoran_uranus_bigtts',
        name: '东方浩然 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_wenrouxiaoya_uranus_bigtts',
        name: '温柔小雅 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_male_tiancaitongsheng_uranus_bigtts',
        name: '天才童声 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_wuzetian_uranus_bigtts',
        name: '武则天 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_female_gujie_uranus_bigtts',
        name: '顾姐 2.0',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'zh_male_guanggaojieshuo_uranus_bigtts',
        name: '广告解说 2.0',
        lang: '中文',
        scene: '通用场景'),
    VoiceInfo(
        id: 'zh_female_shaoergushi_uranus_bigtts',
        name: '少儿故事 2.0',
        lang: '中文',
        scene: '有声阅读'),
    VoiceInfo(
        id: 'saturn_zh_female_tiaopigongzhu_tob',
        name: '调皮公主',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'saturn_zh_female_keainvsheng_tob',
        name: '可爱女生',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'saturn_zh_male_shuanglangshaonian_tob',
        name: '爽朗少年',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'saturn_zh_male_tiancaitongzhuo_tob',
        name: '天才同桌',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'saturn_zh_female_cancan_tob',
        name: '知性灿灿',
        lang: '中文',
        scene: '角色扮演'),
    VoiceInfo(
        id: 'saturn_zh_female_qingyingduoduo_cs_tob',
        name: '轻盈朵朵 2.0',
        lang: '中文',
        scene: '客服场景'),
    VoiceInfo(
        id: 'saturn_zh_female_wenwanshanshan_cs_tob',
        name: '温婉珊珊 2.0',
        lang: '中文',
        scene: '客服场景'),
    VoiceInfo(
        id: 'saturn_zh_female_reqingaina_cs_tob',
        name: '热情艾娜 2.0',
        lang: '中文',
        scene: '客服场景'),
    VoiceInfo(
        id: 'saturn_zh_male_qingxinmumu_cs_tob',
        name: '清新沐沐 2.0',
        lang: '中文',
        scene: '客服场景'),
  ];

  static VoiceInfo get defaultVoice => voices.firstWhere(
        (voice) => voice.id == defaultVoiceType,
        orElse: () => voices.first,
      );

  static const List<VoiceInfo> aliyunVoices = [
    VoiceInfo(
      id: 'loongabby_v3',
      name: 'Abby',
      lang: '中文、英文',
      scene: '通用朗读',
    ),
    VoiceInfo(
      id: 'loongandy_v3',
      name: 'Andy',
      lang: '中文、英文',
      scene: '通用朗读',
    ),
    VoiceInfo(
      id: 'loongannie_v3',
      name: 'Annie',
      lang: '中文、英文',
      scene: '儿童/故事',
    ),
    VoiceInfo(
      id: 'longanyang',
      name: 'An Yang',
      lang: '中文、英文',
      scene: '通用朗读',
    ),
    VoiceInfo(
      id: 'longanhuan',
      name: 'An Huan',
      lang: '中文、英文',
      scene: '通用朗读',
    ),
  ];

  static bool isAliyunPresetVoice(String voiceType) =>
      aliyunVoices.any((voice) => voice.id == voiceType.trim());

  static bool isPresetVoice(String voiceType) =>
      voices.any((voice) => voice.id == voiceType.trim());

  static Future<List<VoiceInfo>> elevenLabsVoices() async {
    final result = await elevenLabsVoiceCatalog();
    return result.voices;
  }

  static Future<VoiceCatalogFetchResult> elevenLabsVoiceCatalog() async {
    final apiKey = await AppConfig.elevenLabsApiKey;
    if (apiKey.isEmpty) {
      _clearElevenLabsVoiceCatalogCache();
      return const VoiceCatalogFetchResult(
        voices: <VoiceInfo>[],
        errorMessage: '未配置 ElevenLabs API Key',
      );
    }
    final baseUrl = await AppConfig.elevenLabsBaseUrl;
    final cacheKey = _elevenLabsVoiceCatalogKey(
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
    final cached = _cachedElevenLabsVoiceCatalog(cacheKey);
    if (cached != null) {
      return cached;
    }
    final endpoint = '$baseUrl/v2/voices';
    final headers = {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
    };
    try {
      final override = _elevenLabsVoicesOverrideForTest;
      Response<Object?>? response;
      Object? payload;
      if (override == null) {
        response = await _dio.get<Object?>(
          endpoint,
          options: Options(
            headers: headers,
            responseType: ResponseType.json,
            validateStatus: (_) => true,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
          ),
        );
        payload = response.data;
      } else {
        payload = await override(endpoint: endpoint, headers: headers);
      }
      final statusCode = response?.statusCode;
      if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
        final serverMessage = _serverMessageFromPayload(payload);
        final detail = serverMessage == null || serverMessage.isEmpty
            ? '请检查网络或 API Key'
            : serverMessage;
        throw TtsException('ElevenLabs 声音列表加载失败 HTTP $statusCode：$detail');
      }
      final rawVoices = _elevenLabsVoicesFromPayload(payload);
      if (rawVoices is! List) {
        final serverMessage = _serverMessageFromPayload(payload);
        final cachedOnFailure =
            _cachedElevenLabsVoiceCatalog(cacheKey, allowExpired: true);
        if (cachedOnFailure != null) {
          return VoiceCatalogFetchResult(
            voices: cachedOnFailure.voices,
            errorMessage: serverMessage == null || serverMessage.isEmpty
                ? 'ElevenLabs 声音列表响应格式不可识别，已保留上次列表'
                : 'ElevenLabs 声音列表加载失败：$serverMessage',
          );
        }
        return VoiceCatalogFetchResult(
          voices: <VoiceInfo>[],
          errorMessage: serverMessage == null || serverMessage.isEmpty
              ? 'ElevenLabs 声音列表响应格式不可识别'
              : 'ElevenLabs 声音列表加载失败：$serverMessage',
        );
      }
      final result = VoiceCatalogFetchResult(
        voices: rawVoices
            .whereType<Map>()
            .map((raw) => _elevenLabsVoiceFromJson(raw))
            .whereType<VoiceInfo>()
            .toList(growable: false),
      );
      if (result.voices.isNotEmpty) {
        _rememberElevenLabsVoiceCatalog(cacheKey, result);
      }
      return result;
    } catch (error) {
      final message = _catalogErrorSummary(error);
      TomatoLogger.warn(
        category: 'tts',
        event: 'elevenlabs.voices.failed',
        message: message,
        error: error,
      );
      final cachedOnFailure =
          _cachedElevenLabsVoiceCatalog(cacheKey, allowExpired: true);
      if (cachedOnFailure != null) {
        return VoiceCatalogFetchResult(
          voices: cachedOnFailure.voices,
          errorMessage: '$message，已保留上次列表',
        );
      }
      return VoiceCatalogFetchResult(
        voices: const <VoiceInfo>[],
        errorMessage: message,
      );
    }
  }

  static String _catalogErrorSummary(Object error) {
    if (error is DioException) {
      return _mapDioException(
        error,
        fallbackMessage: 'ElevenLabs 声音列表加载失败，请检查网络或 API Key',
      ).message;
    }
    if (error is TtsException) {
      return error.message;
    }
    return 'ElevenLabs 声音列表加载失败：${error.toString().split('\n').first}';
  }

  static String _elevenLabsVoiceCatalogKey({
    required String baseUrl,
    required String apiKey,
  }) =>
      '$baseUrl|${apiKey.length}|${apiKey.hashCode}';

  static VoiceCatalogFetchResult? _cachedElevenLabsVoiceCatalog(
    String cacheKey, {
    bool allowExpired = false,
  }) {
    final cached = _elevenLabsVoiceCatalogCache;
    final cachedAt = _elevenLabsVoiceCatalogCacheAt;
    if (cached == null ||
        cached.voices.isEmpty ||
        cachedAt == null ||
        _elevenLabsVoiceCatalogCacheKey != cacheKey) {
      return null;
    }
    final isFresh =
        DateTime.now().difference(cachedAt) <= _elevenLabsVoiceCatalogCacheTtl;
    if (!allowExpired && !isFresh) {
      return null;
    }
    return VoiceCatalogFetchResult(
      voices: cached.voices,
      errorMessage: allowExpired ? cached.errorMessage : null,
    );
  }

  static void _rememberElevenLabsVoiceCatalog(
    String cacheKey,
    VoiceCatalogFetchResult result,
  ) {
    _elevenLabsVoiceCatalogCacheKey = cacheKey;
    _elevenLabsVoiceCatalogCache = result;
    _elevenLabsVoiceCatalogCacheAt = DateTime.now();
  }

  static void _clearElevenLabsVoiceCatalogCache() {
    _elevenLabsVoiceCatalogCacheKey = null;
    _elevenLabsVoiceCatalogCache = null;
    _elevenLabsVoiceCatalogCacheAt = null;
  }

  static List? _elevenLabsVoicesFromPayload(Object? payload) {
    final map = _mapValue(payload);
    final voices = map['voices'];
    if (voices is List) {
      return voices;
    }
    final data = map['data'];
    if (data is List) {
      return data;
    }
    if (data is Map) {
      final dataVoices = data['voices'];
      if (dataVoices is List) {
        return dataVoices;
      }
    }
    final items = map['items'];
    if (items is List) {
      return items;
    }
    return null;
  }

  static VoiceInfo? _elevenLabsVoiceFromJson(Map raw) {
    final id = raw['voice_id']?.toString().trim() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      return null;
    }
    final labels = _mapValue(raw['labels']);
    final gender = labels['gender']?.toString().trim();
    final accent = labels['accent']?.toString().trim();
    final category = raw['category']?.toString().trim();
    return VoiceInfo(
      id: id,
      name: name,
      lang: accent?.isNotEmpty == true ? accent! : 'ElevenLabs',
      scene: category?.isNotEmpty == true ? category! : (gender ?? 'voice'),
      genderHint: gender,
    );
  }

  static const _v3Endpoint =
      'https://openspeech.bytedance.com/api/v3/tts/unidirectional';

  /// 合成语音，返回 MP3 字节数据
  static Future<List<int>?> synthesize({
    required String text,
    String voiceType = defaultVoiceType,
    bool preferRequestedVoice = false,
    int? articleId,
    String cachePurpose = 'tts',
    bool forceRefresh = false,
    String? aiProviderOverride,
  }) async {
    final path = await synthesizeToCachedFile(
      text: text,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      articleId: articleId,
      cachePurpose: cachePurpose,
      forceRefresh: forceRefresh,
      aiProviderOverride: aiProviderOverride,
    );
    return await File(path).readAsBytes();
  }

  static Future<String> synthesizeToCachedFile({
    required String text,
    String voiceType = defaultVoiceType,
    bool preferRequestedVoice = false,
    int? articleId,
    String cachePurpose = 'tts',
    bool forceRefresh = false,
    String? aiProviderOverride,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw const TtsException('TTS 文本不能为空');
    }
    final requestText = (await ContentSafetyService.prepareTextForApi(
      trimmedText,
      serviceKind: ContentSafetyService.serviceTts,
      purpose: cachePurpose,
    ))
        .trim();
    final safeText = requestText.isEmpty ? trimmedText : requestText;

    final provider = await _providerForRequest(aiProviderOverride);
    if (provider == AppConfig.aiProviderElevenLabs) {
      return _synthesizeElevenLabsToCachedFile(
        text: safeText,
        requestedVoiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
        articleId: articleId,
        cachePurpose: cachePurpose,
        forceRefresh: forceRefresh,
      );
    }
    if (provider == AppConfig.aiProviderAliyunBailian) {
      return _synthesizeAliyunToCachedFile(
        text: safeText,
        requestedVoiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
        articleId: articleId,
        cachePurpose: cachePurpose,
        forceRefresh: forceRefresh,
      );
    }

    final ttsResourceId = await AppConfig.volcTtsResourceId;
    if (ttsResourceId.trim().isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Resource ID');
    }

    final configuredSpeakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = _resolveSpeakerId(
      configuredSpeakerId: configuredSpeakerId,
      requestedVoiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
    );
    if (resolvedSpeakerId.isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Speaker');
    }

    final textCandidates = await Future.wait(
      _synthesisTextCandidates(safeText).map((candidate) async {
        final request = _cacheRequest(
          text: candidate,
          speakerId: resolvedSpeakerId,
          resourceId: ttsResourceId,
        );
        final cacheKey = await ApiCacheService.keyForJson('tts', request);
        return _TtsCacheCandidate(
          text: candidate,
          cacheKey: cacheKey,
          request: request,
        );
      }),
    );

    if (!forceRefresh) {
      for (final candidate in textCandidates) {
        final cachedPath = await ApiCacheService.getFilePath(
          candidate.cacheKey,
          articleId: articleId,
          purpose: cachePurpose,
        );
        if (cachedPath != null) {
          _trace('cache hit key=${candidate.cacheKey} path=$cachedPath');
          return cachedPath;
        }
      }
    }

    final apiKey = await AppConfig.volcTtsApiKey;
    if (apiKey.isEmpty) {
      throw const TtsException('未配置火山语音 API Key，请在设置的云服务中配置。');
    }

    TtsException? firstError;
    for (var i = 0; i < textCandidates.length; i++) {
      final candidate = textCandidates[i];
      try {
        if (i > 0) {
          _trace(
            'v3 retry with readable fallback textLen=${candidate.text.length}',
          );
        }
        final bytes = await _synthesizeV3(
          text: candidate.text,
          speakerId: resolvedSpeakerId,
          apiKey: apiKey,
          resourceId: ttsResourceId,
        );
        final filePath = await ApiCacheService.putFileBytes(
          cacheKey: candidate.cacheKey,
          kind: 'tts',
          purpose: cachePurpose,
          request: candidate.request,
          bytes: bytes,
          subdirectory: 'tts',
          extension: 'mp3',
          contentType: 'audio/mpeg',
          articleId: articleId,
        );
        await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
          serviceKind: ContentSafetyService.serviceTts,
          purpose: cachePurpose,
          articleId: articleId,
          successfulText: candidate.text,
        );
        return filePath;
      } on TtsException catch (error) {
        firstError ??= error;
        final canRetry = i == 0 &&
            textCandidates.length > 1 &&
            _shouldRetryWithReadableFallback(error);
        if (!canRetry) {
          final safety = ContentSafetyService.classifyFailure(error);
          if (safety.suspectedSafetyBlock) {
            await ContentSafetyService.recordFailure(
              serviceKind: ContentSafetyService.serviceTts,
              purpose: cachePurpose,
              articleId: articleId,
              failedText: trimmedText,
              errorCode: safety.errorCode,
              errorMessage: safety.message,
            );
          }
          rethrow;
        }
        TomatoLogger.warn(
          category: 'tts',
          event: 'retry_readable_text',
          message: error.message,
          articleId: articleId,
          data: {
            'cachePurpose': cachePurpose,
            'voiceType': voiceType,
          },
        );
      }
    }

    throw firstError ?? const TtsException('TTS 2.0 合成失败');
  }

  static Future<String> _providerForRequest(String? override) async {
    final value = override?.trim();
    if (value == AppConfig.aiProviderAliyunBailian ||
        value == AppConfig.aiProviderVolcengine ||
        value == AppConfig.aiProviderElevenLabs) {
      return value!;
    }
    return AppConfig.ttsProvider;
  }

  static Future<String> _synthesizeElevenLabsToCachedFile({
    required String text,
    required String requestedVoiceType,
    required bool preferRequestedVoice,
    required int? articleId,
    required String cachePurpose,
    required bool forceRefresh,
  }) async {
    final baseUrl = await AppConfig.elevenLabsBaseUrl;
    final model = await AppConfig.elevenLabsTtsModel;
    final configuredVoice = await AppConfig.elevenLabsTtsVoiceId;
    final resolvedVoice = _resolveElevenLabsVoice(
      configuredVoice: configuredVoice,
      requestedVoiceType: requestedVoiceType,
      preferRequestedVoice: preferRequestedVoice,
    );
    final outputFormat = await AppConfig.elevenLabsTtsOutputFormat;
    final endpoint = _elevenLabsTtsEndpoint(
      baseUrl: baseUrl,
      voiceId: resolvedVoice,
      outputFormat: outputFormat,
    );
    final candidates = await Future.wait(
      _synthesisTextCandidates(text).map((candidate) async {
        final request = _elevenLabsCacheRequest(
          endpoint: endpoint,
          model: model,
          voiceId: resolvedVoice,
          outputFormat: outputFormat,
          text: candidate,
        );
        final cacheKey = await ApiCacheService.keyForJson('tts', request);
        return _TtsCacheCandidate(
          text: candidate,
          cacheKey: cacheKey,
          request: request,
        );
      }),
    );

    if (!forceRefresh) {
      for (final candidate in candidates) {
        final cachedPath = await ApiCacheService.getFilePath(
          candidate.cacheKey,
          articleId: articleId,
          purpose: cachePurpose,
        );
        if (cachedPath != null) {
          _trace(
            'elevenlabs cache hit key=${candidate.cacheKey} path=$cachedPath',
          );
          return cachedPath;
        }
      }
    }

    final apiKey = await AppConfig.elevenLabsApiKey;
    if (apiKey.isEmpty) {
      throw const TtsException('未配置 ElevenLabs API Key，请在设置的云服务中配置。');
    }

    TtsException? firstError;
    for (var i = 0; i < candidates.length; i += 1) {
      final candidate = candidates[i];
      try {
        final bytes = await _synthesizeElevenLabs(
          apiKey: apiKey,
          endpoint: endpoint,
          model: model,
          text: candidate.text,
        );
        final filePath = await ApiCacheService.putFileBytes(
          cacheKey: candidate.cacheKey,
          kind: 'tts',
          purpose: cachePurpose,
          request: candidate.request,
          bytes: bytes,
          subdirectory: 'tts',
          extension: _extensionForElevenLabsOutput(outputFormat),
          contentType: _contentTypeForElevenLabsOutput(outputFormat),
          articleId: articleId,
        );
        await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
          serviceKind: ContentSafetyService.serviceTts,
          purpose: cachePurpose,
          articleId: articleId,
          successfulText: candidate.text,
        );
        return filePath;
      } on TtsException catch (error) {
        firstError ??= error;
        final canRetry = i == 0 &&
            candidates.length > 1 &&
            _shouldRetryWithReadableFallback(error);
        if (!canRetry) {
          final safety = ContentSafetyService.classifyFailure(error);
          if (safety.suspectedSafetyBlock) {
            await ContentSafetyService.recordFailure(
              serviceKind: ContentSafetyService.serviceTts,
              purpose: cachePurpose,
              articleId: articleId,
              failedText: text,
              errorCode: safety.errorCode,
              errorMessage: safety.message,
            );
          }
          rethrow;
        }
      }
    }

    throw firstError ?? const TtsException('ElevenLabs 语音合成失败');
  }

  static Future<String> _synthesizeAliyunToCachedFile({
    required String text,
    required String requestedVoiceType,
    required bool preferRequestedVoice,
    required int? articleId,
    required String cachePurpose,
    required bool forceRefresh,
  }) async {
    final endpoint = await AppConfig.aliyunCosyVoiceEndpoint;
    final model = await AppConfig.aliyunBailianTtsModel;
    final configuredVoice = await AppConfig.aliyunBailianTtsVoice;
    final resolvedVoice = _resolveAliyunVoice(
      configuredVoice: configuredVoice,
      requestedVoiceType: requestedVoiceType,
      preferRequestedVoice: preferRequestedVoice,
    );
    if (resolvedVoice.isEmpty) {
      throw const TtsException('本机配置未读取到阿里云 CosyVoice 音色');
    }
    final sampleRate = await AppConfig.aliyunBailianTtsSampleRate;
    final candidates = await Future.wait(
      _synthesisTextCandidates(text).map((candidate) async {
        final request = _aliyunCacheRequest(
          endpoint: endpoint,
          model: model,
          voice: resolvedVoice,
          sampleRate: sampleRate,
          text: candidate,
        );
        final cacheKey = await ApiCacheService.keyForJson('tts', request);
        return _TtsCacheCandidate(
          text: candidate,
          cacheKey: cacheKey,
          request: request,
        );
      }),
    );

    if (!forceRefresh) {
      for (final candidate in candidates) {
        final cachedPath = await ApiCacheService.getFilePath(
          candidate.cacheKey,
          articleId: articleId,
          purpose: cachePurpose,
        );
        if (cachedPath != null) {
          _trace('aliyun cache hit key=${candidate.cacheKey} path=$cachedPath');
          return cachedPath;
        }
      }
    }

    final apiKey = await AppConfig.aliyunBailianApiKey;
    if (apiKey.isEmpty) {
      throw const TtsException('未配置阿里云百炼 API Key，请在设置的云服务中配置。');
    }

    TtsException? firstError;
    for (var i = 0; i < candidates.length; i += 1) {
      final candidate = candidates[i];
      try {
        final bytes = await _synthesizeAliyunCosyVoice(
          apiKey: apiKey,
          endpoint: endpoint,
          model: model,
          voice: resolvedVoice,
          sampleRate: sampleRate,
          text: candidate.text,
        );
        final filePath = await ApiCacheService.putFileBytes(
          cacheKey: candidate.cacheKey,
          kind: 'tts',
          purpose: cachePurpose,
          request: candidate.request,
          bytes: bytes,
          subdirectory: 'tts',
          extension: 'mp3',
          contentType: 'audio/mpeg',
          articleId: articleId,
        );
        await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
          serviceKind: ContentSafetyService.serviceTts,
          purpose: cachePurpose,
          articleId: articleId,
          successfulText: candidate.text,
        );
        return filePath;
      } on TtsException catch (error) {
        firstError ??= error;
        final canRetry = i == 0 &&
            candidates.length > 1 &&
            _shouldRetryWithReadableFallback(error);
        if (!canRetry) {
          final safety = ContentSafetyService.classifyFailure(error);
          if (safety.suspectedSafetyBlock) {
            await ContentSafetyService.recordFailure(
              serviceKind: ContentSafetyService.serviceTts,
              purpose: cachePurpose,
              articleId: articleId,
              failedText: text,
              errorCode: safety.errorCode,
              errorMessage: safety.message,
            );
          }
          rethrow;
        }
      }
    }

    throw firstError ?? const TtsException('阿里云 CosyVoice 合成失败');
  }

  static Future<Set<String>> cacheKeysForText({
    required String text,
    String voiceType = defaultVoiceType,
    bool preferRequestedVoice = false,
    String cachePurpose = 'tts',
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      return <String>{};
    }
    final requestText = (await ContentSafetyService.prepareTextForApi(
      trimmedText,
      serviceKind: ContentSafetyService.serviceTts,
      purpose: cachePurpose,
    ))
        .trim();
    final safeText = requestText.isEmpty ? trimmedText : requestText;

    final provider = await AppConfig.ttsProvider;
    if (provider == AppConfig.aiProviderElevenLabs) {
      final baseUrl = await AppConfig.elevenLabsBaseUrl;
      final model = await AppConfig.elevenLabsTtsModel;
      final voice = _resolveElevenLabsVoice(
        configuredVoice: await AppConfig.elevenLabsTtsVoiceId,
        requestedVoiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
      );
      final outputFormat = await AppConfig.elevenLabsTtsOutputFormat;
      final endpoint = _elevenLabsTtsEndpoint(
        baseUrl: baseUrl,
        voiceId: voice,
        outputFormat: outputFormat,
      );
      return {
        for (final candidate in _synthesisTextCandidates(safeText))
          await ApiCacheService.keyForJson(
            'tts',
            _elevenLabsCacheRequest(
              endpoint: endpoint,
              model: model,
              voiceId: voice,
              outputFormat: outputFormat,
              text: candidate,
            ),
          ),
      };
    }

    if (provider == AppConfig.aiProviderAliyunBailian) {
      final endpoint = await AppConfig.aliyunCosyVoiceEndpoint;
      final model = await AppConfig.aliyunBailianTtsModel;
      final configuredVoice = await AppConfig.aliyunBailianTtsVoice;
      final voice = _resolveAliyunVoice(
        configuredVoice: configuredVoice,
        requestedVoiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
      );
      final sampleRate = await AppConfig.aliyunBailianTtsSampleRate;
      if (voice.isEmpty) {
        return <String>{};
      }
      return {
        for (final candidate in _synthesisTextCandidates(safeText))
          await ApiCacheService.keyForJson(
            'tts',
            _aliyunCacheRequest(
              endpoint: endpoint,
              model: model,
              voice: voice,
              sampleRate: sampleRate,
              text: candidate,
            ),
          ),
      };
    }

    final ttsResourceId = await AppConfig.volcTtsResourceId;
    final configuredSpeakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = _resolveSpeakerId(
      configuredSpeakerId: configuredSpeakerId,
      requestedVoiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
    );
    if (ttsResourceId.trim().isEmpty || resolvedSpeakerId.isEmpty) {
      return <String>{};
    }

    final keys = <String>{};
    for (final candidate in _synthesisTextCandidates(safeText)) {
      final request = _cacheRequest(
        text: candidate,
        speakerId: resolvedSpeakerId,
        resourceId: ttsResourceId,
      );
      keys.add(await ApiCacheService.keyForJson('tts', request));
    }
    return keys;
  }

  static Map<String, dynamic> _cacheRequest({
    required String text,
    required String speakerId,
    required String resourceId,
  }) =>
      {
        'service': 'doubao_tts_2',
        'endpoint': _v3Endpoint,
        'resourceId': resourceId,
        'speaker': speakerId,
        'text': text,
        'audio': {
          'format': 'mp3',
          'sampleRate': 24000,
        },
      };

  static Map<String, dynamic> _aliyunCacheRequest({
    required String endpoint,
    required String model,
    required String voice,
    required int sampleRate,
    required String text,
  }) =>
      {
        'service': 'aliyun_cosyvoice',
        'endpoint': endpoint,
        'model': model,
        'voice': voice,
        'text': text,
        'audio': {
          'format': 'mp3',
          'sampleRate': sampleRate,
          'languageHints': ['en'],
        },
      };

  static Map<String, dynamic> _elevenLabsCacheRequest({
    required String endpoint,
    required String model,
    required String voiceId,
    required String outputFormat,
    required String text,
  }) =>
      {
        'service': 'elevenlabs_tts',
        'provider': AppConfig.aiProviderElevenLabs,
        'endpoint': endpoint,
        'model': model,
        'voiceId': voiceId,
        'outputFormat': outputFormat,
        'text': text,
      };

  static String _resolveElevenLabsVoice({
    required String configuredVoice,
    required String requestedVoiceType,
    required bool preferRequestedVoice,
  }) {
    if (preferRequestedVoice && requestedVoiceType.trim().isNotEmpty) {
      return requestedVoiceType.trim();
    }
    final configured = configuredVoice.trim();
    return configured.isNotEmpty
        ? configured
        : AppConfig.defaultElevenLabsTtsVoiceId;
  }

  static String _elevenLabsTtsEndpoint({
    required String baseUrl,
    required String voiceId,
    required String outputFormat,
  }) {
    final encodedVoiceId = Uri.encodeComponent(voiceId.trim());
    final encodedOutputFormat = Uri.encodeQueryComponent(outputFormat.trim());
    return '$baseUrl/v1/text-to-speech/$encodedVoiceId'
        '?output_format=$encodedOutputFormat';
  }

  static String _extensionForElevenLabsOutput(String outputFormat) {
    final normalized = outputFormat.trim().toLowerCase();
    if (normalized.startsWith('wav')) {
      return 'wav';
    }
    if (normalized.startsWith('pcm')) {
      return 'pcm';
    }
    return 'mp3';
  }

  static String _contentTypeForElevenLabsOutput(String outputFormat) {
    final extension = _extensionForElevenLabsOutput(outputFormat);
    if (extension == 'wav') {
      return 'audio/wav';
    }
    if (extension == 'pcm') {
      return 'audio/L16';
    }
    return 'audio/mpeg';
  }

  @visibleForTesting
  static List<String> synthesisTextCandidatesForTest(String text) =>
      _synthesisTextCandidates(text.trim());

  static List<String> _synthesisTextCandidates(String text) {
    final normalized = _normalizeTtsText(text);
    final candidates = <String>[normalized];
    final readableFallback = _englishReadableFallback(normalized);
    if (readableFallback.isNotEmpty && readableFallback != normalized) {
      candidates.add(readableFallback);
    }
    return candidates;
  }

  static String _normalizeTtsText(String text) => text
      .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
      .replaceAllMapped(
        RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
        (match) => '${match.group(1)!}-${match.group(2)!}',
      )
      .replaceAllMapped(RegExp(r'\s+([,.!?;:])'), (match) => match.group(1)!)
      .trim();

  static bool _shouldRetryWithReadableFallback(TtsException error) {
    final message = error.message;
    return message.contains('未返回音频数据') || message.contains('响应为空');
  }

  static String _englishReadableFallback(String text) {
    if (!RegExp(r'[\u3400-\u9FFF]').hasMatch(text) ||
        !RegExp(r'[A-Za-z]').hasMatch(text)) {
      return text;
    }

    var readable = text
        .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
        .replaceAll(RegExp(r'[（）《》【】]'), ' ')
        .replaceAll(RegExp(r'\b(?:E|EP)\s*\d+\b', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'\bEpisod(?:e)?\s*\d+\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+[-–—]\s+'), ' ')
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .trim();

    final quoteIndex = readable.indexOf('"');
    if (quoteIndex > 0) {
      final leading = readable.substring(0, quoteIndex).trim();
      if (_looksLikeImportedTitle(leading)) {
        readable = readable.substring(quoteIndex).trim();
      }
    }

    return readable
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .replaceAllMapped(
          RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
          (match) => '${match.group(1)!}-${match.group(2)!}',
        )
        .replaceAllMapped(RegExp(r'\s+([,.!?;:])'), (match) => match.group(1)!)
        .trim();
  }

  static bool _looksLikeImportedTitle(String text) {
    final words = text
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .length;
    return words <= 8 ||
        RegExp(r'\bAdventures\b|\bWonderland\b|\bChapter\b',
                caseSensitive: false)
            .hasMatch(text);
  }

  static Future<List<int>> _synthesizeAliyunCosyVoice({
    required String apiKey,
    required String endpoint,
    required String model,
    required String voice,
    required int sampleRate,
    required String text,
  }) async {
    try {
      _trace(
        'aliyun request start model=$model voice=$voice textLen=${text.length}',
      );
      final response = await _dio.post<Object?>(
        endpoint,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        data: {
          'model': model,
          'input': {
            'text': text,
            'voice': voice,
            'format': 'mp3',
            'sample_rate': sampleRate,
            'language_hints': ['en'],
          },
        },
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode < 200 || statusCode >= 300) {
        throw TtsException(
          '阿里云 CosyVoice 请求失败 HTTP $statusCode：${_remoteErrorMessage(response.data)}',
        );
      }
      final bytes = await _cosyVoiceAudioBytes(response.data);
      if (bytes.isEmpty) {
        throw const TtsException('阿里云 CosyVoice 未返回音频数据');
      }
      return bytes;
    } on DioException catch (e) {
      throw _mapDioException(
        e,
        fallbackMessage: '阿里云 CosyVoice 网络请求失败，请检查网络或百炼配置',
      );
    } on TtsException {
      rethrow;
    } catch (e) {
      TomatoLogger.error(
        category: 'tts',
        event: 'aliyun_synthesize.failed',
        error: e,
      );
      throw TtsException('阿里云 CosyVoice 合成失败：$e');
    }
  }

  static Future<List<int>> _synthesizeElevenLabs({
    required String apiKey,
    required String endpoint,
    required String model,
    required String text,
  }) async {
    final headers = {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
    };
    final body = {
      'text': text,
      'model_id': model,
    };
    try {
      _trace(
        'elevenlabs request start model=$model textLen=${text.length}',
      );
      final override = _elevenLabsPostOverrideForTest;
      if (override != null) {
        return await override(
          endpoint: endpoint,
          headers: headers,
          body: body,
        );
      }
      final response = await _dio.post<List<int>>(
        endpoint,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
        ),
        data: body,
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode < 200 || statusCode >= 300) {
        throw TtsException(
          'ElevenLabs 请求失败 HTTP $statusCode：${_remoteErrorMessage(response.data)}',
        );
      }
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) {
        throw const TtsException('ElevenLabs 未返回音频数据');
      }
      return bytes;
    } on DioException catch (e) {
      throw _mapDioException(
        e,
        fallbackMessage: 'ElevenLabs 网络请求失败，请检查网络或 API Key',
      );
    } on TtsException {
      rethrow;
    } catch (e) {
      TomatoLogger.error(
        category: 'tts',
        event: 'elevenlabs_synthesize.failed',
        error: e,
      );
      throw TtsException('ElevenLabs 语音合成失败：$e');
    }
  }

  static Future<List<int>> _cosyVoiceAudioBytes(Object? payload) async {
    final map = _mapValue(payload);
    final output = _mapValue(map['output']);
    final audio = _mapValue(output['audio']);
    final data = audio['data']?.toString().trim() ?? '';
    if (data.isNotEmpty) {
      return base64.decode(data);
    }
    final url = audio['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      return const <int>[];
    }
    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const <int>[];
  }

  static Future<List<int>> _synthesizeV3({
    required String text,
    required String speakerId,
    required String apiKey,
    required String resourceId,
  }) async {
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();

    try {
      _trace(
        'v3 request start id=$requestId speaker=$speakerId textLen=${text.length} resourceId=$resourceId',
      );
      final response = await _dio.post<ResponseBody>(
        _v3Endpoint,
        options: Options(
          headers: {
            'X-Api-Key': apiKey,
            'X-Api-Resource-Id': resourceId,
            'X-Api-Request-Id': requestId,
          },
          responseType: ResponseType.stream,
        ),
        data: {
          'req_params': {
            'text': text,
            'speaker': speakerId,
            'audio_params': {
              'format': 'mp3',
              'sample_rate': 24000,
            },
          },
        },
      );

      final responseBody = response.data;
      if (responseBody == null) {
        throw const TtsException('TTS 2.0 未返回音频流');
      }

      final audioBytes = await _collectChunkedAudio(responseBody);
      if (audioBytes.isEmpty) {
        throw const TtsException('TTS 2.0 未返回音频数据');
      }

      _trace('v3 request success id=$requestId bytes=${audioBytes.length}');

      return audioBytes;
    } on DioException catch (e) {
      _trace('v3 request dioError id=$requestId error=${e.message}');
      throw _mapDioException(
        e,
        fallbackMessage: 'TTS 2.0 网络请求失败，请检查网络或本机语音配置',
      );
    } on FormatException catch (e) {
      TomatoLogger.error(
        category: 'tts',
        event: 'invalid_audio_payload',
        error: e,
      );
      throw const TtsException('TTS 2.0 返回格式异常');
    } on TtsException {
      rethrow;
    } catch (e) {
      TomatoLogger.error(
        category: 'tts',
        event: 'synthesize.failed',
        error: e,
      );
      throw TtsException('TTS 2.0 合成失败：$e');
    }
  }

  static Future<List<int>> _collectChunkedAudio(
      ResponseBody responseBody) async {
    final audioBytes = <int>[];
    var sawTerminalSuccess = false;
    var packetCount = 0;
    var audioPacketCount = 0;

    await for (final line in utf8.decoder.bind(responseBody.stream).transform(
          const LineSplitter(),
        )) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) {
        continue;
      }

      final decoded = jsonDecode(trimmedLine);
      if (decoded is! Map) {
        continue;
      }

      packetCount += 1;
      final packet = Map<String, dynamic>.from(decoded);
      final audioBase64 = packet['data'] as String?;
      if (audioBase64 != null && audioBase64.isNotEmpty) {
        audioPacketCount += 1;
        audioBytes.addAll(base64.decode(audioBase64));
      }

      final code = _parsePacketCode(packet['code']);
      if (code == 20000000) {
        sawTerminalSuccess = true;
        continue;
      }

      final errorMessage =
          packet['message'] ?? packet['msg'] ?? packet['error'];
      if (audioBase64 == null &&
          errorMessage != null &&
          errorMessage.toString().isNotEmpty) {
        final codeLabel = code != null
            ? '（code=$code，${errorMessage.toString()}）'
            : '：${errorMessage.toString()}';
        throw TtsException('TTS 2.0 请求失败$codeLabel');
      }
    }

    if (audioBytes.isEmpty && !sawTerminalSuccess) {
      throw const TtsException('TTS 2.0 响应为空');
    }

    _trace(
      'v3 stream packets=$packetCount audioPackets=$audioPacketCount '
      'bytes=${audioBytes.length} terminalSuccess=$sawTerminalSuccess',
    );

    return audioBytes;
  }

  static TtsException _mapDioException(
    DioException exception, {
    required String fallbackMessage,
  }) {
    final serverMessage = _serverMessageFromPayload(exception.response?.data);

    TomatoLogger.warn(
      category: 'tts',
      event: 'request.failed',
      message: exception.message,
      data: {
        'statusCode': exception.response?.statusCode,
      },
    );

    final status = exception.response?.statusCode;
    final statusPart = status == null ? '' : ' HTTP $status';
    if (serverMessage != null && serverMessage.isNotEmpty) {
      return TtsException('TTS 网络请求失败$statusPart：$serverMessage');
    }
    return TtsException(
      statusPart.isEmpty ? fallbackMessage : '$fallbackMessage$statusPart',
    );
  }

  static String? _serverMessageFromPayload(Object? payload) {
    if (payload is String && payload.trim().isNotEmpty) {
      return payload.trim();
    }
    final map = _mapValue(payload);
    for (final key in const ['message', 'msg', 'error', 'detail', 'code']) {
      final message = _serverMessageFromValue(map[key]);
      if (message != null && message.isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  static String? _serverMessageFromValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value is Map) {
      final map = _mapValue(value);
      final status = _serverMessageFromValue(map['status']);
      final message = _serverMessageFromValue(map['message']) ??
          _serverMessageFromValue(map['error']) ??
          _serverMessageFromValue(map['detail']);
      if (status != null && message != null) {
        return '$status: $message';
      }
      return message ?? status;
    }
    return value.toString().trim();
  }

  static int? _parsePacketCode(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static String _resolveAliyunVoice({
    required String configuredVoice,
    required String requestedVoiceType,
    bool preferRequestedVoice = false,
  }) {
    final trimmedRequestedVoiceType = requestedVoiceType.trim();
    if (preferRequestedVoice &&
        isAliyunPresetVoice(trimmedRequestedVoiceType)) {
      return trimmedRequestedVoiceType;
    }
    final trimmedConfiguredVoice = configuredVoice.trim();
    if (trimmedConfiguredVoice.isNotEmpty) {
      return trimmedConfiguredVoice;
    }
    if (isAliyunPresetVoice(trimmedRequestedVoiceType)) {
      return trimmedRequestedVoiceType;
    }
    return defaultAliyunVoiceType;
  }

  static String _resolveSpeakerId({
    required String configuredSpeakerId,
    required String requestedVoiceType,
    bool preferRequestedVoice = false,
  }) {
    final trimmedRequestedVoiceType = requestedVoiceType.trim();
    if (preferRequestedVoice && isPresetVoice(trimmedRequestedVoiceType)) {
      return trimmedRequestedVoiceType;
    }

    final trimmedConfiguredSpeakerId = configuredSpeakerId.trim();
    if (trimmedConfiguredSpeakerId.isNotEmpty) {
      return trimmedConfiguredSpeakerId;
    }

    if (trimmedRequestedVoiceType.isEmpty) {
      return '';
    }

    final isPresetSpeaker = isPresetVoice(trimmedRequestedVoiceType);
    if (!isPresetSpeaker) {
      return '';
    }

    return trimmedRequestedVoiceType;
  }

  static Map<String, dynamic> _mapValue(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  static String _remoteErrorMessage(Object? payload) {
    final map = _mapValue(payload);
    final message = map['message'] ?? map['msg'] ?? map['error'] ?? map['code'];
    if (message != null && message.toString().trim().isNotEmpty) {
      return message.toString().trim();
    }
    return payload?.toString() ?? '未知错误';
  }

  static void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    TomatoLogger.trace(
      category: 'tts',
      event: 'trace',
      message: message,
      data: {'tag': 'TtsTrace'},
      force: true,
    );
  }
}

class _TtsCacheCandidate {
  const _TtsCacheCandidate({
    required this.text,
    required this.cacheKey,
    required this.request,
  });

  final String text;
  final String cacheKey;
  final Map<String, dynamic> request;
}
