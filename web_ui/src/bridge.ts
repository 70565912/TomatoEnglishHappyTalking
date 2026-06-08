import type {
  Article,
  BridgeResponse,
  ChatState,
  FollowState,
  ListeningOpenPayload,
  NativeEvent,
  PictureBookState,
  SettingsState,
  StorySeries,
  VoiceOption,
} from './types';
import { splitSentences } from './sentenceSplitter';

type NativeListener<T = unknown> = (payload: T) => void;

declare global {
  interface Window {
    flutter_inappwebview?: {
      callHandler: (
        handlerName: string,
        message: Record<string, unknown>,
      ) => Promise<BridgeResponse>;
    };
    chrome?: {
      webview?: unknown;
    };
    __tomatoNativeEvent?: (event: NativeEvent) => void;
  }
}

const listeners = new Map<string, Set<NativeListener>>();
const FLUTTER_BRIDGE_WAIT_MS = 1800;
const FLUTTER_BRIDGE_POLL_MS = 50;

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

  const flutterBridge = await resolveFlutterBridge();
  const response = flutterBridge
    ? await flutterBridge.callHandler('tomatoBridge', message)
    : await mockNativeResponse(type, payload, message.id);

  if (!response.ok) {
    throw new Error(response.error?.message ?? `Native command failed: ${type}`);
  }
  return (response.payload ?? {}) as T;
}

async function resolveFlutterBridge(): Promise<Window['flutter_inappwebview']> {
  if (window.flutter_inappwebview) {
    return window.flutter_inappwebview;
  }

  if (!isLikelyEmbeddedWebView()) {
    return undefined;
  }

  return waitForFlutterBridge(FLUTTER_BRIDGE_WAIT_MS);
}

function isLikelyEmbeddedWebView(): boolean {
  return Boolean(window.flutter_inappwebview || window.chrome?.webview);
}

function waitForFlutterBridge(timeoutMs: number): Promise<Window['flutter_inappwebview']> {
  if (window.flutter_inappwebview) {
    return Promise.resolve(window.flutter_inappwebview);
  }

  return new Promise((resolve) => {
    let settled = false;
    let pollTimer: number | undefined;

    const finish = () => {
      if (settled) {
        return;
      }
      settled = true;
      window.removeEventListener('flutterInAppWebViewPlatformReady', finish);
      if (pollTimer !== undefined) {
        window.clearInterval(pollTimer);
      }
      resolve(window.flutter_inappwebview);
    };

    pollTimer = window.setInterval(() => {
      if (window.flutter_inappwebview) {
        finish();
      }
    }, FLUTTER_BRIDGE_POLL_MS);

    window.addEventListener('flutterInAppWebViewPlatformReady', finish, {
      once: true,
    });
    window.setTimeout(finish, timeoutMs);
  });
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
    return { articles: mockArticles, series: mockSeries };
  }
  if (type === 'article.create') {
    const content = normalizePracticeContent(String(payload.content ?? ''));
    const sentences = splitSentences(content);
    const pictureBookEnabled = payload.pictureBookEnabled !== false;
    const requestedTitle = String(payload.title ?? '').trim();
    const resolvedTitle = requestedTitle || mockSuggestTitle(content);
    const seriesTitle = String(payload.seriesTitle ?? '').trim() || resolvedTitle || 'Space Story Series';
    const seriesId = Number(payload.seriesId ?? mockSeries[0].id);
    const article: Article = {
      id: 99,
      title: resolvedTitle || 'New Quest',
      content,
      sentences,
      sentenceCount: sentences.length,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled,
      seriesId: pictureBookEnabled ? seriesId : null,
      seriesTitle: pictureBookEnabled ? seriesTitle : '',
      chapterOrder: pictureBookEnabled ? 2 : null,
    };
    return { article, articles: [article, ...mockArticles], series: mockSeries };
  }
  if (type === 'article.suggestTitle') {
    return { title: mockSuggestTitle(String(payload.content ?? '')) };
  }
  if (type === 'article.translateToEnglish') {
    return {
      content: normalizePracticeContent(
        mockTranslateToEnglish(String(payload.content ?? '')),
      ),
    };
  }
  if (type === 'follow.open') {
    return mockFollow;
  }
  if (type === 'series.list') {
    return { series: mockSeries };
  }
  if (type === 'series.create') {
    const series: StorySeries = {
      id: 12,
      title: String(payload.title ?? 'New Story Series'),
      styleGuide: {},
      bible: {},
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    return { series: [series, ...mockSeries] };
  }
  if (type === 'series.attachArticle') {
    const articleId = Number(payload.articleId ?? mockArticles[0].id);
    const seriesId = Number(payload.seriesId ?? mockSeries[0].id);
    const seriesTitle = String(payload.seriesTitle ?? mockSeries[0].title);
    const article = {
      ...(mockArticles.find((item) => item.id === articleId) ??
        mockArticles[0]),
      pictureBookEnabled: true,
      seriesId,
      seriesTitle,
      chapterOrder: 1,
    };
    return {
      article,
      chapter: {
        articleId,
        seriesId,
        chapterOrder: 1,
        chapterTitle: article.title,
      },
      articles: mockArticles.map((item) =>
        item.id === articleId ? article : item,
      ),
      series: mockSeries,
    };
  }
  if (type === 'pictureBook.state') {
    return mockPictureBook(Number(payload.articleId ?? 1));
  }
  if (type === 'pictureBook.generate' || type === 'pictureBook.retryPage') {
    return mockPictureBook(Number(payload.articleId ?? 1), 'generating');
  }
  if (type === 'listening.open') {
    return mockListening;
  }
  if (type === 'listening.prepare') {
    return { prepared: true };
  }
  if (type === 'listening.play') {
    return { playbackState: 'success' };
  }
  if (type === 'listening.stop') {
    return { stopped: true };
  }
  if (type === 'listening.pause') {
    return { paused: true };
  }
  if (type === 'listening.resume') {
    return { resumed: true };
  }
  if (type === 'word.lookup') {
    return mockWordLookup(String(payload.word ?? ''), String(payload.sentence ?? ''));
  }
  if (type === 'word.play') {
    return { playbackState: 'success' };
  }
  if (type === 'word.stop') {
    return { stopped: true };
  }
  if (type === 'follow.play' || type === 'follow.replay' || type === 'follow.recordReplay') {
    return {
      ...mockFollow,
      step: 'idle',
      playbackState: 'success',
      result: type === 'follow.recordReplay' ? mockResult : null,
      hasRecording: type === 'follow.recordReplay',
    };
  }
  if (type === 'follow.next') {
    return {
      ...mockFollow,
      currentIndex: 1,
      currentSentence: mockArticles[0].sentences[1],
      currentTranslation: '他把它分享给自己的队友。',
      isLastSentence: true,
      step: 'idle',
      playbackState: 'idle',
      result: null,
    };
  }
  if (type === 'follow.pause') {
    return { paused: true };
  }
  if (type === 'follow.resume') {
    return { resumed: true };
  }
  if (type === 'follow.retry') {
    return {
      ...mockFollow,
      step: 'idle',
      playbackState: 'idle',
      result: null,
    };
  }
  if (type.startsWith('follow.')) {
    if (type === 'follow.recordStart') {
      return {
        ...mockFollow,
        step: 'recording',
        playbackState: 'idle',
        result: null,
        hasRecording: false,
        liveRecognizedText: 'Tom finds...',
      };
    }
    if (type === 'follow.recordStop') {
      return {
        ...mockFollow,
        step: 'result',
        playbackState: 'success',
        result: mockResult,
        hasRecording: true,
        liveRecognizedText: mockResult.recognizedText,
      };
    }
    return {
      ...mockFollow,
      step: 'idle',
      result: null,
      hasRecording: false,
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
  if (type === 'settings.previewVoice') {
    return { playbackState: 'success' };
  }
  if (type === 'contentSafety.setRuleEnabled') {
    const id = Number(payload.id ?? 0);
    const enabled = Boolean(payload.enabled);
    mockSettings = {
      ...mockSettings,
      contentSafety: {
        rules: (mockSettings.contentSafety?.rules ?? []).map((rule) =>
          rule.id === id ? { ...rule, enabled } : rule,
        ),
      },
    };
    return mockSettings;
  }
  if (type === 'contentSafety.deleteRule') {
    const id = Number(payload.id ?? 0);
    mockSettings = {
      ...mockSettings,
      contentSafety: {
        rules: (mockSettings.contentSafety?.rules ?? []).filter((rule) => rule.id !== id),
      },
    };
    return mockSettings;
  }
  return {};
}

function mockSuggestTitle(content: string): string {
  if (/[\u3400-\u9FFF]/.test(content)) {
    if (content.includes('母') || content.includes('妈')) return "A Mother's Choice";
    return 'English Practice';
  }
  const lowerContent = content.toLowerCase();
  if (lowerContent.includes('mother') && lowerContent.includes('choice')) {
    return "A Mother's Choice";
  }
  const words = content
    .toLowerCase()
    .replace(/[^a-z\s]/g, ' ')
    .split(/\s+/)
    .filter((word) => word.length > 3 && !mockTitleStopWords.has(word));
  const uniqueWords = Array.from(new Set(words)).slice(0, 3);
  if (uniqueWords.length === 0) return 'English Practice';
  return uniqueWords.map((word) => word[0].toUpperCase() + word.slice(1)).join(' ');
}

function mockTranslateToEnglish(content: string): string {
  if (/[\u3400-\u9FFF]/.test(content) && /[A-Za-z]/.test(content)) {
    return mockExtractEnglishStory(content);
  }
  if (content.includes('母') || content.includes('妈') || content.includes('选择')) {
    return 'A mother makes a choice for her child. She thinks about love, family, and the future.';
  }
  if (/[\u3400-\u9FFF]/.test(content)) {
    return 'This is a short English practice story. The people make a choice and learn something important.';
  }
  return content;
}

function normalizePracticeContent(content: string): string {
  const normalized = content.replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2').trim();
  if (/[\u3400-\u9FFF]/.test(normalized) && /[A-Za-z]/.test(normalized)) {
    return mockExtractEnglishStory(normalized);
  }
  if (/[\u3400-\u9FFF]/.test(normalized)) {
    return mockTranslateToEnglish(normalized).replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2').trim();
  }
  return normalized;
}

function mockExtractEnglishStory(content: string): string {
  const lines = content
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .split(/\r?\n|(?<=[。！？；;])\s*/);
  const kept = lines
    .map((line) => line.trim())
    .filter((line) => {
      const englishWords = line.match(/[A-Za-z][A-Za-z'-]*/g) ?? [];
      const chineseChars = line.match(/[\u3400-\u9FFF]/g) ?? [];
      if (englishWords.length < 3) return false;
      if (/^(title|标题|中文|翻译|词汇|vocabulary|notes?|注释|讲解)\s*[:：]/i.test(line)) return false;
      return chineseChars.length <= englishWords.length;
    })
    .map((line) => line.replace(/[\u3400-\u9FFF]+/g, ' ').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  return kept.join(' ').trim() || content.replace(/[\u3400-\u9FFF]+/g, ' ').replace(/\s+/g, ' ').trim();
}

function mockWordLookup(word: string, sentence: string): Record<string, string> {
  const normalized = word.trim() || 'word';
  const lower = normalized.toLowerCase();
  const dictionary: Record<string, { phonetic: string; meaning: string; sentenceMeaning: string }> = {
    bright: {
      phonetic: '/brait/',
      meaning: '明亮的；聪明的；鲜艳的',
      sentenceMeaning: '在本句中表示“明亮的”。',
    },
    snack: {
      phonetic: '/snak/',
      meaning: '零食；小吃',
      sentenceMeaning: '在本句中表示“零食”。',
    },
    finds: {
      phonetic: '/faindz/',
      meaning: '找到；发现',
      sentenceMeaning: '在本句中表示“发现”。',
    },
    shares: {
      phonetic: '/sherz/',
      meaning: '分享；分给',
      sentenceMeaning: '在本句中表示“分享”。',
    },
  };
  const fallback = dictionary[lower] ?? {
    phonetic: '/.../',
    meaning: '这个单词的中文含义暂不可用。',
    sentenceMeaning: sentence.trim()
      ? '请结合本句理解这个单词。'
      : '请结合原句理解这个单词。',
  };

  return {
    word: normalized,
    phonetic: fallback.phonetic,
    meaning: fallback.meaning,
    sentenceMeaning: fallback.sentenceMeaning,
    source: 'mock',
  };
}

const mockTitleStopWords = new Set([
  'about',
  'after',
  'again',
  'bright',
  'little',
  'looks',
  'slowly',
  'that',
  'their',
  'there',
  'this',
  'with',
]);

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
    coverImageUri: assetUrl('card-space-snacks.png'),
    coverImagePath: null,
    pictureBookEnabled: true,
    seriesId: 1,
    seriesTitle: 'Space Story Series',
    chapterOrder: 1,
  },
];

const mockSeries: StorySeries[] = [
  {
    id: 1,
    title: 'Space Story Series',
    styleGuide: {},
    bible: {},
    coverImagePath: null,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  },
];

function mockPictureBook(
  articleId: number,
  status: PictureBookState['status'] = 'ready',
): PictureBookState {
  return {
    articleId,
    enabled: true,
    status,
    series: mockSeries[0],
    chapter: {
      articleId,
      seriesId: mockSeries[0].id,
      chapterOrder: 1,
      chapterTitle: 'Space Snacks',
    },
    pages: [
      {
        articleId,
        seriesId: mockSeries[0].id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 1,
        paragraphText: mockArticles[0].content,
        imageUri: assetUrl('card-space-snacks.png'),
        imagePath: assetUrl('card-space-snacks.png'),
        status: status === 'generating' ? 'generating' : 'ready',
        errorMessage: null,
      },
    ],
  };
}

function assetUrl(name: string): string {
  return `assets/ui/${name}`;
}

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
  currentTranslation: '汤姆发现了一个明亮的零食盒。',
  isLastSentence: false,
  step: 'idle',
  playbackState: 'idle',
  hasRecording: false,
  liveRecognizedText: '',
  result: null,
  avatar: {
    mode: 'idle',
    emotion: 'encouraging',
    mouth: 'closed',
    volume: 0,
  },
};

const mockListening: ListeningOpenPayload = {
  article: mockArticles[0],
  items: [
    {
      index: 0,
      english: mockArticles[0].sentences[0],
      chinese: '汤姆发现了一个明亮的零食盒。',
    },
    {
      index: 1,
      english: mockArticles[0].sentences[1],
      chinese: '他把它分享给自己的队友。',
    },
  ],
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
      translation: '汤姆发现了什么？',
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
  contentSafety: {
    rules: [
      {
        id: 1,
        sourceTerm: 'heads',
        replacement: 'he-ads',
        serviceKind: '*',
        purposeScope: '*',
        matchType: 'word',
        confidence: 0.55,
        enabled: true,
        sourceFailureId: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
      {
        id: 2,
        sourceTerm: 'beheaded',
        replacement: 'be-headed',
        serviceKind: '*',
        purposeScope: '*',
        matchType: 'word',
        confidence: 0.55,
        enabled: true,
        sourceFailureId: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ],
  },
};
