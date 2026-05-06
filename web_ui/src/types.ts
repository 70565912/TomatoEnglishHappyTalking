export type AvatarMode =
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'celebrating'
  | 'error';

export type AvatarEmotion =
  | 'happy'
  | 'focused'
  | 'encouraging'
  | 'surprised'
  | 'sad';

export type AvatarMouth = 'closed' | 'small' | 'medium' | 'wide';

export interface AvatarState {
  mode: AvatarMode;
  emotion: AvatarEmotion;
  mouth: AvatarMouth;
  volume: number;
}

export interface Article {
  id: number;
  title: string;
  content: string;
  sentences: string[];
  sentenceCount: number;
  createdAt: string;
  averageScore: number;
}

export interface WordScore {
  word: string;
  score: number;
  errorType: string;
}

export interface PronunciationResult {
  overallScore: number;
  accuracyScore: number;
  fluencyScore: number;
  completenessScore: number;
  prosodyScore: number;
  recognizedText: string;
  isMock: boolean;
  words: WordScore[];
}

export interface FollowState {
  status: 'loading' | 'ready' | 'error';
  article?: Article;
  currentIndex?: number;
  totalSentences?: number;
  currentSentence?: string;
  isLastSentence?: boolean;
  step?: string;
  playbackState?: string;
  playbackError?: string | null;
  result?: PronunciationResult | null;
  error?: string | null;
  avatar?: AvatarState;
}

export interface ChatMessage {
  id: string;
  isAi: boolean;
  text: string;
  playbackState: string;
  playbackError?: string | null;
}

export interface ChatState {
  articleTitle: string;
  step: string;
  error?: string | null;
  questionCount: number;
  maxQuestions: number;
  messages: ChatMessage[];
  avatar?: AvatarState;
}

export interface VoiceOption {
  id: string;
  name: string;
  lang: string;
  gender: string;
  scene: string;
}

export interface SettingsState {
  tts: {
    resourceId: string;
    speakerId: string;
  };
  voices: VoiceOption[];
}

export interface NativeEvent<T = unknown> {
  type: string;
  payload: T;
}

export interface BridgeResponse<T = unknown> {
  id: string;
  ok: boolean;
  type: string;
  payload?: T;
  error?: {
    message: string;
  };
}
