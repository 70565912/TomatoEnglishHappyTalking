import type {
  Article,
  BridgeResponse,
  ChatState,
  FollowState,
  NativeEvent,
  SettingsState,
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

const mockSettings: SettingsState = {
  volcApi: {
    configured: false,
  },
  tts: {
    resourceId: 'seed-tts-2.0',
    speakerId: 'en_female_dacey_uranus_bigtts',
  },
  realtime: {
    appId: '',
  },
  bigAsr: {
    mode: 'BigASR 闯关评分',
  },
  voices: [
    {
      id: 'en_female_dacey_uranus_bigtts',
      name: 'Dacey',
      lang: 'en-US',
      gender: 'female',
    },
  ],
};
