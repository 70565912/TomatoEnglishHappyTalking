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
  coverImagePath?: string | null;
  coverImageUri?: string | null;
  pictureBookEnabled?: boolean;
  seriesId?: number | null;
  seriesTitle?: string;
  chapterOrder?: number | null;
}

export interface StorySeries {
  id: number;
  title: string;
  styleGuide?: Record<string, unknown>;
  bible?: Record<string, unknown>;
  coverImagePath?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface PictureBookPage {
  id?: number;
  articleId: number;
  seriesId?: number | null;
  pageIndex: number;
  sentenceStartIndex: number;
  sentenceEndIndex: number;
  paragraphText: string;
  imagePath?: string | null;
  imageUri?: string | null;
  status: 'queued' | 'prompting' | 'generating' | 'ready' | 'skipped' | 'error' | string;
  errorMessage?: string | null;
}

export interface PictureBookState {
  articleId: number;
  enabled: boolean;
  status: 'empty' | 'generating' | 'ready' | 'partial' | 'skipped' | 'error' | string;
  series?: StorySeries | null;
  chapter?: Record<string, unknown> | null;
  pages: PictureBookPage[];
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
  currentTranslation?: string;
  isLastSentence?: boolean;
  step?: string;
  playbackState?: string;
  playbackError?: string | null;
  hasRecording?: boolean;
  liveRecognizedText?: string;
  result?: PronunciationResult | null;
  error?: string | null;
  avatar?: AvatarState;
}

export type ListeningMode = 'english' | 'bilingual';

export interface ListeningItem {
  index: number;
  english: string;
  chinese: string;
}

export interface ListeningOpenPayload {
  article: Article;
  items: ListeningItem[];
}

export interface ListeningTranslationsPayload {
  articleId: number;
  translations: Array<{
    index: number;
    chinese: string;
  }>;
}

export interface ListeningPausePayload {
  paused: boolean;
}

export interface ListeningResumePayload {
  resumed: boolean;
}

export interface WordLookupPayload {
  word: string;
  phonetic: string;
  meaning: string;
  sentenceMeaning: string;
  source?: string;
}

export interface WordPlaybackPayload {
  playbackState: 'success';
}

export interface ChatMessage {
  id: string;
  isAi: boolean;
  text: string;
  translation?: string | null;
  playbackState: string;
  playbackError?: string | null;
}

export interface ChatState {
  articleTitle: string;
  step: string;
  error?: string | null;
  questionCount: number;
  maxQuestions: number;
  isChapterComplete?: boolean;
  abilityLevel?: string | null;
  practiceSummary?: string | null;
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

export interface ContentSafetyRule {
  id: number;
  sourceTerm: string;
  replacement: string;
  serviceKind: string;
  purposeScope: string;
  matchType: string;
  confidence: number;
  enabled: boolean;
  sourceFailureId?: number | null;
  createdAt: string;
  updatedAt: string;
}

export interface SettingsState {
  tts: {
    resourceId: string;
    speakerId: string;
  };
  voices: VoiceOption[];
  contentSafety?: {
    rules: ContentSafetyRule[];
  };
}

export interface GeneratedTitlePayload {
  title: string;
}

export interface EnglishArticlePayload {
  content: string;
}

export interface VoicePreviewPayload {
  playbackState: 'success';
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
