import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';

/// TTS 服务 — 直接调用火山引擎 Doubao TTS 2.0 HTTP Chunked API。
/// 未配置或云端失败时抛出 [TtsException]，由 Provider 转成可展示的 UI 状态。

class VoiceInfo {
  final String id;
  final String name;
  final String lang;
  final String scene;

  const VoiceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.scene,
  });

  String get gender {
    if (id.contains('_female_') || id.contains('female')) {
      return 'female';
    }
    if (id.contains('_male_') || id.contains('male')) {
      return 'male';
    }
    return 'unknown';
  }
}

class TtsException implements Exception {
  const TtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TtsService {
  static const defaultVoiceType = 'en_female_dacey_uranus_bigtts';

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

  static bool isPresetVoice(String voiceType) =>
      voices.any((voice) => voice.id == voiceType.trim());

  static const _v3Endpoint =
      'https://openspeech.bytedance.com/api/v3/tts/unidirectional';

  /// 合成语音，返回 MP3 字节数据
  static Future<List<int>?> synthesize({
    required String text,
    String voiceType = defaultVoiceType,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw const TtsException('TTS 文本不能为空');
    }

    final apiKey = await AppConfig.volcApiKey;
    if (apiKey.isEmpty) {
      throw const TtsException('本机加密配置未读取到火山引擎 API Key');
    }

    final ttsResourceId = await AppConfig.volcTtsResourceId;
    if (ttsResourceId.trim().isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Resource ID');
    }

    final configuredSpeakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = _resolveSpeakerId(
      configuredSpeakerId: configuredSpeakerId,
      requestedVoiceType: voiceType,
    );
    if (resolvedSpeakerId.isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Speaker');
    }

    return _synthesizeV3(
      text: trimmedText,
      speakerId: resolvedSpeakerId,
      apiKey: apiKey,
      resourceId: ttsResourceId,
    );
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
      debugPrint('[TtsService] invalid v3 audio payload: $e');
      throw const TtsException('TTS 2.0 返回格式异常');
    } on TtsException {
      rethrow;
    } catch (e) {
      debugPrint('[TtsService] v3 synthesize failed: $e');
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
    final responseData = exception.response?.data;
    String? serverMessage;

    if (responseData is Map) {
      final candidate = responseData['message'] ??
          responseData['msg'] ??
          responseData['error'];
      if (candidate != null) {
        serverMessage = candidate.toString();
      }
    } else if (responseData is String && responseData.trim().isNotEmpty) {
      serverMessage = responseData.trim();
    }

    debugPrint(
      '[TtsService] request failed: ${exception.message}; status=${exception.response?.statusCode}',
    );

    if (serverMessage != null && serverMessage.isNotEmpty) {
      return TtsException('TTS 网络请求失败：$serverMessage');
    }
    return TtsException(fallbackMessage);
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

  static String _resolveSpeakerId({
    required String configuredSpeakerId,
    required String requestedVoiceType,
  }) {
    final trimmedConfiguredSpeakerId = configuredSpeakerId.trim();
    if (trimmedConfiguredSpeakerId.isNotEmpty) {
      return trimmedConfiguredSpeakerId;
    }

    final trimmedRequestedVoiceType = requestedVoiceType.trim();
    if (trimmedRequestedVoiceType.isEmpty) {
      return '';
    }

    final isPresetSpeaker = isPresetVoice(trimmedRequestedVoiceType);
    if (!isPresetSpeaker) {
      return '';
    }

    return trimmedRequestedVoiceType;
  }

  static void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    debugPrint('[TtsTrace] $message');
  }
}
