import type {
  Article,
  BridgeResponse,
  ChatState,
  FollowState,
  NativeEvent,
  SettingsState,
  VoiceOption,
} from './types';

type NativeListener<T = unknown> = (payload: T) => void;

declare global {
  interface Window {
    flutter_inappwebview?: {
      callHandler: (
        handlerName: string,
        message: Record<string, unknown>,
      ) => Promise<BridgeResponse>;
    };
    __tomatoNativeEvent?: (event: NativeEvent) => void;
  }
}

const listeners = new Map<string, Set<NativeListener>>();

export function onNativeEvent<T>(
  type: string,
  listener: NativeListener<T>,
): () => void {
  const bucket = listeners.get(type) ?? new Set<NativeListener>();
  bucket.add(listener as NativeListener);
  listeners.set(type, bucket);

  return () => {
    bucket.delete(listener as NativeListener);
    if (bucket.size === 0) {
      listeners.delete(type);
    }
  };
}

export function emitNativeEvent(event: NativeEvent): void {
  const bucket = listeners.get(event.type);
  if (!bucket) {
    return;
  }
  bucket.forEach((listener) => listener(event.payload));
}

window.__tomatoNativeEvent = emitNativeEvent;

export async function sendNative<T>(
  type: string,
  payload: Record<string, unknown> = {},
): Promise<T> {
  const message = {
    id: makeRequestId(),
    type,
    payload,
  };

  const response = window.flutter_inappwebview
    ? await window.flutter_inappwebview.callHandler('tomatoBridge', message)
    : await mockNativeResponse(type, payload, message.id);

  if (!response.ok) {
    throw new Error(response.error?.message ?? `Native command failed: ${type}`);
  }
  return (response.payload ?? {}) as T;
}

function makeRequestId(): string {
  return `web_${Date.now()}_${Math.round(Math.random() * 1_000_000)}`;
}

async function mockNativeResponse(
  type: string,
  payload: Record<string, unknown>,
  id: string,
): Promise<BridgeResponse> {
  await delay(80);
  const responsePayload = mockPayload(type, payload);
  return {
    id,
    ok: true,
    type: `${type}.result`,
    payload: responsePayload,
  };
}

function mockPayload(type: string, payload: Record<string, unknown>): unknown {
  if (type === 'article.list' || type === 'app.ready') {
    return { articles: mockArticles };
  }
  if (type === 'article.create') {
    const article: Article = {
      id: 99,
      title: String(payload.title ?? 'New Quest'),
      content: String(payload.content ?? ''),
      sentences: String(payload.content ?? '').split(/[.!?]/).filter(Boolean),
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 0,
    };
    return { article, articles: [article, ...mockArticles] };
  }
  if (type === 'follow.open') {
    return mockFollow;
  }
  if (type.startsWith('follow.')) {
    return {
      ...mockFollow,
      step: type === 'follow.recordStop' ? 'result' : 'idle',
      result: type === 'follow.recordStop' ? mockResult : null,
    };
  }
  if (type === 'chat.open') {
    return mockChat;
  }
  if (type.startsWith('chat.')) {
    return mockChat;
  }
  if (type === 'settings.load') {
    return mockSettings;
  }
  if (type === 'settings.saveVoice') {
    const speakerId = String(payload.speakerId ?? mockSettings.tts.speakerId);
    const isKnownVoice = mockSettings.voices.some((voice) => voice.id === speakerId);
    mockSettings = {
      ...mockSettings,
      tts: {
        ...mockSettings.tts,
        speakerId: isKnownVoice ? speakerId : mockSettings.tts.speakerId,
      },
    };
    return mockSettings;
  }
  return {};
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms);
  });
}

const mockArticles: Article[] = [
  {
    id: 1,
    title: 'Space Snacks',
    content: 'Tom finds a bright snack box. He shares it with his team.',
    sentences: [
      'Tom finds a bright snack box.',
      'He shares it with his team.',
    ],
    sentenceCount: 2,
    createdAt: new Date().toISOString(),
    averageScore: 86,
  },
];

const mockResult = {
  overallScore: 88,
  accuracyScore: 91,
  fluencyScore: 84,
  completenessScore: 90,
  prosodyScore: 83,
  recognizedText: 'Tom finds a bright snack box.',
  isMock: true,
  words: [
    { word: 'Tom', score: 90, errorType: 'None' },
    { word: 'finds', score: 82, errorType: 'None' },
    { word: 'bright', score: 72, errorType: 'None' },
  ],
};

const mockFollow: FollowState = {
  status: 'ready',
  article: mockArticles[0],
  currentIndex: 0,
  totalSentences: 2,
  currentSentence: mockArticles[0].sentences[0],
  isLastSentence: false,
  step: 'idle',
  playbackState: 'idle',
  result: null,
  avatar: {
    mode: 'idle',
    emotion: 'encouraging',
    mouth: 'closed',
    volume: 0,
  },
};

const mockChat: ChatState = {
  articleTitle: 'Space Snacks',
  step: 'userIdle',
  questionCount: 1,
  maxQuestions: 8,
  messages: [
    {
      id: 'ai_1',
      isAi: true,
      text: 'What did Tom find?',
      playbackState: 'success',
    },
  ],
  avatar: {
    mode: 'idle',
    emotion: 'encouraging',
    mouth: 'closed',
    volume: 0,
  },
};

const mockVoiceOptions: VoiceOption[] = `
zh_female_vv_uranus_bigtts|Vivi 2.0|中文、日文、印尼、墨西哥西班牙语|通用场景
zh_female_xiaohe_uranus_bigtts|小何 2.0|中文|通用场景
zh_male_m191_uranus_bigtts|云舟 2.0|中文|通用场景
zh_male_taocheng_uranus_bigtts|小天 2.0|中文|通用场景
zh_male_liufei_uranus_bigtts|刘飞 2.0|中文|通用场景
zh_female_sophie_uranus_bigtts|魅力苏菲 2.0|中文|通用场景
zh_female_qingxinnvsheng_uranus_bigtts|清新女声 2.0|中文|通用场景
zh_female_cancan_uranus_bigtts|知性灿灿 2.0|中文|角色扮演
zh_female_sajiaoxuemei_uranus_bigtts|撒娇学妹 2.0|中文|角色扮演
zh_female_tianmeixiaoyuan_uranus_bigtts|甜美小源 2.0|中文|通用场景
zh_female_tianmeitaozi_uranus_bigtts|甜美桃子 2.0|中文|通用场景
zh_female_shuangkuaisisi_uranus_bigtts|爽快思思 2.0|中文|通用场景
zh_female_peiqi_uranus_bigtts|佩奇猪 2.0|中文|视频配音
zh_female_linjianvhai_uranus_bigtts|邻家女孩 2.0|中文|通用场景
zh_male_shaonianzixin_uranus_bigtts|少年梓辛/Brayan 2.0|中文|通用场景
zh_male_sunwukong_uranus_bigtts|猴哥 2.0|中文|视频配音
zh_female_yingyujiaoxue_uranus_bigtts|Tina老师 2.0|中文、英式英语|教育场景
zh_female_kefunvsheng_uranus_bigtts|暖阳女声 2.0|中文|客服场景
zh_female_xiaoxue_uranus_bigtts|儿童绘本 2.0|中文|有声阅读
zh_male_dayi_uranus_bigtts|大壹 2.0|中文|视频配音
zh_female_mizai_uranus_bigtts|黑猫侦探社咪仔 2.0|中文|视频配音
zh_female_jitangnv_uranus_bigtts|鸡汤女 2.0|中文|视频配音
zh_female_meilinvyou_uranus_bigtts|魅力女友 2.0|中文|通用场景
zh_female_liuchangnv_uranus_bigtts|流畅女声 2.0|中文|视频配音
zh_male_ruyayichen_uranus_bigtts|儒雅逸辰 2.0|中文|视频配音
en_male_tim_uranus_bigtts|Tim|美式英语|多语种
en_female_dacey_uranus_bigtts|Dacey|美式英语|多语种
en_female_stokie_uranus_bigtts|Stokie|美式英语|多语种
zh_female_wenroumama_uranus_bigtts|温柔妈妈 2.0|中文|通用场景
zh_male_jieshuoxiaoming_uranus_bigtts|解说小明 2.0|中文|通用场景
zh_female_tvbnv_uranus_bigtts|TVB女声 2.0|中文|通用场景
zh_male_yizhipiannan_uranus_bigtts|译制片男 2.0|中文|通用场景
zh_female_qiaopinv_uranus_bigtts|俏皮女声 2.0|中文|通用场景
zh_female_zhishuaiyingzi_uranus_bigtts|直率英子 2.0|中文|角色扮演
zh_male_linjiananhai_uranus_bigtts|邻家男孩 2.0|中文|通用场景
zh_male_silang_uranus_bigtts|四郎 2.0|中文|角色扮演
zh_male_ruyaqingnian_uranus_bigtts|儒雅青年 2.0|中文|通用场景
zh_male_qingcang_uranus_bigtts|擎苍 2.0|中文|角色扮演
zh_male_xionger_uranus_bigtts|熊二 2.0|中文|角色扮演
zh_female_yingtaowanzi_uranus_bigtts|樱桃丸子 2.0|中文|角色扮演
zh_male_wennuanahu_uranus_bigtts|温暖阿虎/Alvin 2.0|中文|通用场景
zh_male_naiqimengwa_uranus_bigtts|奶气萌娃 2.0|中文|通用场景
zh_female_popo_uranus_bigtts|婆婆 2.0|中文|通用场景
zh_female_gaolengyujie_uranus_bigtts|高冷御姐 2.0|中文|通用场景
zh_male_aojiaobazong_uranus_bigtts|傲娇霸总 2.0|中文|通用场景
zh_male_lanyinmianbao_uranus_bigtts|懒音绵宝 2.0|中文|角色扮演
zh_male_fanjuanqingnian_uranus_bigtts|反卷青年 2.0|中文|通用场景
zh_female_wenroushunv_uranus_bigtts|温柔淑女 2.0|中文|通用场景
zh_female_gufengshaoyu_uranus_bigtts|古风少御 2.0|中文|角色扮演
zh_male_huolixiaoge_uranus_bigtts|活力小哥 2.0|中文|通用场景
zh_male_baqiqingshu_uranus_bigtts|霸气青叔 2.0|中文|有声阅读
zh_male_xuanyijieshuo_uranus_bigtts|悬疑解说 2.0|中文|有声阅读
zh_female_mengyatou_uranus_bigtts|萌丫头/Cutey 2.0|中文|通用场景
zh_female_tiexinnvsheng_uranus_bigtts|贴心女声/Candy 2.0|中文|通用场景
zh_female_jitangmei_uranus_bigtts|鸡汤妹妹/Hope 2.0|中文|通用场景
zh_male_cixingjieshuonan_uranus_bigtts|磁性解说男声/Morgan 2.0|中文|通用场景
zh_male_liangsangmengzai_uranus_bigtts|亮嗓萌仔 2.0|中文|通用场景
zh_female_kailangjiejie_uranus_bigtts|开朗姐姐 2.0|中文|通用场景
zh_male_gaolengchenwen_uranus_bigtts|高冷沉稳 2.0|中文|通用场景
zh_male_shenyeboke_uranus_bigtts|深夜播客 2.0|中文|通用场景
zh_male_lubanqihao_uranus_bigtts|鲁班七号 2.0|中文|角色扮演
zh_female_jiaochuannv_uranus_bigtts|娇喘女声 2.0|中文|通用场景
zh_female_linxiao_uranus_bigtts|林潇 2.0|中文|角色扮演
zh_female_lingling_uranus_bigtts|玲玲姐姐 2.0|中文|角色扮演
zh_female_chunribu_uranus_bigtts|春日部姐姐 2.0|中文|角色扮演
zh_male_tangseng_uranus_bigtts|唐僧 2.0|中文|角色扮演
zh_male_zhuangzhou_uranus_bigtts|庄周 2.0|中文|角色扮演
zh_male_kailangdidi_uranus_bigtts|开朗弟弟 2.0|中文|通用场景
zh_male_zhubajie_uranus_bigtts|猪八戒 2.0|中文|角色扮演
zh_female_ganmaodianyin_uranus_bigtts|感冒电音姐姐 2.0|中文|角色扮演
zh_female_chanmeinv_uranus_bigtts|谄媚女声 2.0|中文|通用场景
zh_female_nvleishen_uranus_bigtts|女雷神 2.0|中文|角色扮演
zh_female_qinqienv_uranus_bigtts|亲切女声 2.0|中文|通用场景
zh_male_kuailexiaodong_uranus_bigtts|快乐小东 2.0|中文|通用场景
zh_male_kailangxuezhang_uranus_bigtts|开朗学长 2.0|中文|通用场景
zh_male_youyoujunzi_uranus_bigtts|悠悠君子 2.0|中文|通用场景
zh_female_wenjingmaomao_uranus_bigtts|文静毛毛 2.0|中文|通用场景
zh_female_zhixingnv_uranus_bigtts|知性女声 2.0|中文|通用场景
zh_male_qingshuangnanda_uranus_bigtts|清爽男大 2.0|中文|通用场景
zh_male_yuanboxiaoshu_uranus_bigtts|渊博小叔 2.0|中文|通用场景
zh_male_yangguangqingnian_uranus_bigtts|阳光青年 2.0|中文|通用场景
zh_female_qingchezizi_uranus_bigtts|清澈梓梓 2.0|中文|通用场景
zh_female_tianmeiyueyue_uranus_bigtts|甜美悦悦 2.0|中文|通用场景
zh_female_xinlingjitang_uranus_bigtts|心灵鸡汤 2.0|中文|通用场景
zh_male_wenrouxiaoge_uranus_bigtts|温柔小哥 2.0|中文|通用场景
zh_female_roumeinvyou_uranus_bigtts|柔美女友 2.0|中文|通用场景
zh_male_dongfanghaoran_uranus_bigtts|东方浩然 2.0|中文|通用场景
zh_female_wenrouxiaoya_uranus_bigtts|温柔小雅 2.0|中文|通用场景
zh_male_tiancaitongsheng_uranus_bigtts|天才童声 2.0|中文|通用场景
zh_female_wuzetian_uranus_bigtts|武则天 2.0|中文|角色扮演
zh_female_gujie_uranus_bigtts|顾姐 2.0|中文|角色扮演
zh_male_guanggaojieshuo_uranus_bigtts|广告解说 2.0|中文|通用场景
zh_female_shaoergushi_uranus_bigtts|少儿故事 2.0|中文|有声阅读
saturn_zh_female_tiaopigongzhu_tob|调皮公主|中文|角色扮演
saturn_zh_female_keainvsheng_tob|可爱女生|中文|角色扮演
saturn_zh_male_shuanglangshaonian_tob|爽朗少年|中文|角色扮演
saturn_zh_male_tiancaitongzhuo_tob|天才同桌|中文|角色扮演
saturn_zh_female_cancan_tob|知性灿灿|中文|角色扮演
saturn_zh_female_qingyingduoduo_cs_tob|轻盈朵朵 2.0|中文|客服场景
saturn_zh_female_wenwanshanshan_cs_tob|温婉珊珊 2.0|中文|客服场景
saturn_zh_female_reqingaina_cs_tob|热情艾娜 2.0|中文|客服场景
saturn_zh_male_qingxinmumu_cs_tob|清新沐沐 2.0|中文|客服场景
`
  .trim()
  .split('\n')
  .map((line) => {
    const [id, name, lang, scene] = line.split('|');
    return {
      id,
      name,
      lang,
      scene,
      gender: inferVoiceGender(id),
    };
  });

function inferVoiceGender(id: string): string {
  if (id.includes('_female_') || id.includes('female')) return 'female';
  if (id.includes('_male_') || id.includes('male')) return 'male';
  return 'unknown';
}

let mockSettings: SettingsState = {
  tts: {
    resourceId: 'seed-tts-2.0',
    speakerId: 'en_female_dacey_uranus_bigtts',
  },
  voices: mockVoiceOptions,
};
