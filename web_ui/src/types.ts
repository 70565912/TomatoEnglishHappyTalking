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
  visibleSentenceCount?: number;
  createdAt: string;
  averageScore: number;
  coverImagePath?: string | null;
  coverImageUri?: string | null;
  pictureBookEnabled?: boolean;
  seriesId?: number | null;
  seriesTitle?: string;
  seriesDescription?: string;
  chapterDescription?: string;
  chapterOrder?: number | null;
}

export interface BookCharacter {
  name: string;
  description: string;
}

export interface StorySeries {
  id: number;
  title: string;
  description?: string;
  characters?: BookCharacter[];
  coverImagePath?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface BookTransferPayload {
  cancelled?: boolean;
  seriesId?: number;
  title?: string;
  outputPath?: string;
  articleIds?: number[];
  articleCount?: number;
  assetCount?: number;
  warnings?: string[];
  articles?: Article[];
  series?: StorySeries[];
}

export interface PreloadState {
  articleId: number;
  mode: 'listening' | 'follow' | 'chat' | string;
  scope?: 'english' | 'chinese' | string;
  runId?: string;
  status: 'loading' | 'complete' | 'partial' | 'error' | string;
  completed: number;
  total: number;
  failed: number;
}

export interface PictureBookPage {
  id?: number;
  articleId: number;
  seriesId?: number | null;
  pageIndex: number;
  sentenceStartIndex: number;
  sentenceEndIndex: number;
  paragraphText: string;
  prompt?: Record<string, unknown> | null;
  imagePath?: string | null;
  imageUri?: string | null;
  imageVariant?: 'full' | 'display' | 'thumbnail' | string;
  status: 'queued' | 'prompting' | 'generating' | 'ready' | 'skipped' | 'error' | string;
  errorMessage?: string | null;
}

export interface PictureBookState {
  articleId: number;
  enabled: boolean;
  status: 'loading' | 'empty' | 'queued' | 'generating' | 'ready' | 'partial' | 'skipped' | 'error' | string;
  series?: StorySeries | null;
  chapter?: Record<string, unknown> | null;
  pages: PictureBookPage[];
}

export interface PictureBookPageImagePayload {
  articleId: number;
  pageIndex: number;
  variant?: 'full' | 'display' | 'thumbnail' | string;
  imageUri?: string | null;
  missing?: boolean;
  errorMessage?: string | null;
}

export interface PictureBookPromptReviewScene {
  pageIndex: number;
  sentenceStartIndex: number;
  sentenceEndIndex: number;
  paragraphText: string;
  sceneDescription: string;
}

export interface PictureBookPromptReview {
  reviewId: string;
  articleId: number;
  chapterId?: number | null;
  seriesId?: number | null;
  bookTitle?: string;
  mode?: 'group' | 'singlePage' | string;
  targetPageIndex?: number | null;
  referencePageIndex?: number | null;
  referencePageIndexes?: number[];
  referenceOptions?: number[];
  regenerate: boolean;
  bookDescription: string;
  bookCharacters?: BookCharacter[];
  relevantCharacters?: BookCharacter[];
  newCharacters?: BookCharacter[];
  chapterDescription: string;
  groupPrompt: string;
  scenes: PictureBookPromptReviewScene[];
  refreshedTarget?: 'bookDescription' | 'chapterPlan' | string;
  createdAt?: string;
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
  visibleSentenceCount?: number;
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
  hidden?: boolean;
}

export interface ListeningOpenPayload {
  article: Article;
  items: ListeningItem[];
}

export interface ArticleFullTextPayload {
  article: Article;
  bookTitle?: string;
  items: ListeningItem[];
}

export interface ListeningPlaybackPayload {
  articleId: number;
  index: number;
  part: 'english' | 'chinese' | null;
  state: 'partStart' | 'completed' | 'stopped' | 'error';
  error?: string | null;
}

export interface ListeningTranslationsPayload {
  articleId: number;
  translations: Array<{
    index: number;
    chinese: string;
  }>;
}

export interface ListeningSynthesisPayload {
  status: 'ready' | 'error' | string;
  english?: 'ready' | 'error' | 'pending' | 'unchanged' | string;
  chinese?: 'ready' | 'error' | 'pending' | 'unchanged' | string;
  error?: string | null;
}

export interface ListeningAudioMaterialStatus {
  articleId: number;
  total: number;
  ready: number;
  missing: number[];
  failed: number;
  status: 'empty' | 'missing' | 'partial' | 'partial_error' | 'ready' | string;
  requested?: number;
  overwrite?: boolean;
}

export interface ListeningAudioMaterialProgress {
  articleId: number;
  status: 'loading' | 'complete' | 'partial' | 'ready' | string;
  completed: number;
  total: number;
  failed: number;
  overwrite?: boolean;
  ready?: number;
  missing?: number[];
  requested?: number;
}

export type SongSource = 'suno' | 'bailian_fun_music' | 'external_audio';
export type AiProvider = 'aliyun_bailian' | 'volcengine';

export interface ListeningSongStatePayload {
  articleId: number;
  status: 'empty' | 'generating' | 'ready' | 'error' | 'playing' | string;
  stylePrompt?: string;
  audioPath?: string | null;
  errorMessage?: string | null;
  durationMs?: number | null;
  source?: SongSource | string;
  lyricsCompressed?: boolean;
  songUrl?: string | null;
  metadataPath?: string | null;
  manualActionMessage?: string | null;
  automationStatus?: string | null;
  creditsRemaining?: number | null;
  downloadComplete?: boolean | null;
  importCancelled?: boolean | null;
  detectedSongUrls?: string[];
  versions?: Array<{
    id: string;
    audioPath: string;
    title?: string | null;
    songUrl?: string | null;
    durationMs?: number | null;
    createdAt?: string | null;
    stylePrompt?: string | null;
    styleKey?: string | null;
    lyricsHash?: string | null;
    submittedLyrics?: string | null;
    source?: SongSource | string;
    timelinePath?: string | null;
    timelineStatus?: 'missing' | 'generating' | 'ready' | 'error' | string | null;
    timelineConfidence?: number | null;
    timelineError?: string | null;
    isDefault?: boolean;
  }>;
}

export interface ListeningSongCuePayload {
  lineIndex: number;
  startMs: number;
  endMs: number;
  english: string;
  chinese?: string | null;
  confidence: number;
  method: 'matched' | 'interpolated' | 'estimated' | 'fallback' | string;
}

export interface ListeningSongPositionPayload {
  articleId: number;
  versionId?: string | null;
  positionMs: number;
  durationMs?: number | null;
  cue?: ListeningSongCuePayload | null;
}

export interface ListeningSongAudioExportPayload {
  articleId: number;
  versionId: string;
  sourcePath: string;
  outputPath: string;
  outputDirectory: string;
}

export interface ListeningSentenceUpdatePayload {
  article?: Article;
  item: ListeningItem;
  items?: ListeningItem[];
  synthesis: ListeningSynthesisPayload;
  articles?: Article[];
  series?: StorySeries[];
}

export interface ListeningFullscreenReadyPayload {
  ready: boolean;
  reasons: string[];
  requiredEnglish: number;
  readyEnglish: number;
  requiredChinese: number;
  readyChinese: number;
  missingEnglish: number[];
  missingChinese: number[];
  failed: number;
}

export type RecordingCodec = 'h264' | 'h265';
export type RecordingResolution = '2560x1440' | '1920x1080' | '1280x720';
export type RecordingPageTransition = 'none' | 'crossFade' | 'panZoomFade' | 'slide' | 'pageCurl';
export type RecordingSubtitleMode = 'srt' | 'burnedIn' | 'both';

export interface RecordingSettings {
  codec: RecordingCodec;
  resolution: RecordingResolution;
  pageTransition: RecordingPageTransition;
  subtitleMode: RecordingSubtitleMode;
  outputDirectory: string;
  ffmpegPath?: string;
  fps: number;
  quality: 'high' | string;
  hardwareBackend: 'auto' | string;
}

export interface ListeningRecordingReadyPayload {
  ready: boolean;
  reasons: string[];
  encoderName: string;
  codec: RecordingCodec | string;
  resolution: RecordingResolution | string;
  pageTransition: RecordingPageTransition | string;
  subtitleMode?: RecordingSubtitleMode | string;
  outputDirectory: string;
  requiredEnglish: number;
  readyEnglish: number;
  requiredChinese: number;
  readyChinese: number;
  picturePageCount: number;
}

export interface ListeningRecordingProgressPayload {
  articleId: number;
  phase: 'rendering' | 'encoding' | 'completed' | string;
  progress: number;
  completedFrames: number;
  totalFrames: number;
  message?: string;
}

export interface ListeningRecordingResultPayload {
  articleId: number;
  videoPath: string;
  subtitlePath: string;
  videoVariants?: Array<{
    kind: 'srt' | 'subtitled' | string;
    videoPath: string;
    subtitlePath?: string | null;
  }>;
  durationMs: number;
  frameCount: number;
  droppedFrameCount: number;
  encoderName: string;
  codec: RecordingCodec | string;
  resolution: RecordingResolution | string;
  pageTransition: RecordingPageTransition | string;
  warnings: string[];
}

export interface RecordingVideoVersion {
  id: string;
  articleId: number;
  videoPath: string;
  subtitlePath?: string | null;
  createdAt?: string | null;
  source?: 'listening' | 'song' | 'scanned' | string;
  title?: string | null;
  isDefault?: boolean;
  durationMs?: number | null;
  frameCount?: number | null;
  droppedFrameCount?: number | null;
  encoderName?: string | null;
  codec?: RecordingCodec | string | null;
  resolution?: RecordingResolution | string | null;
  pageTransition?: RecordingPageTransition | string | null;
  sizeBytes?: number | null;
}

export interface RecordingVideoLibraryPayload {
  articleId: number;
  outputDirectory: string;
  versions: RecordingVideoVersion[];
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
  cloud?: {
    aiProvider: AiProvider | string;
    aliyunBailian: {
      apiKeyConfigured: boolean;
      apiKeyMask?: string;
      baseUrl: string;
      apiBaseUrl?: string;
      textModel: string;
      musicModel: string;
      imageModel?: string;
      imageSize?: string;
      ttsModel?: string;
      ttsVoice?: string;
      ttsSampleRate?: number | string;
      asrModel?: string;
      realtimeAsrModel?: string;
      realtimeAsrUrl?: string;
    };
    volcengine: {
      arkApiKeyConfigured: boolean;
      arkApiKeyMask?: string;
      arkBaseUrl: string;
      arkTextModel: string;
      arkImageModel: string;
      speechApiKeyConfigured: boolean;
      speechApiKeyMask?: string;
      ttsResourceId: string;
      ttsSpeakerId: string;
    };
  };
  song?: {
    sunoOutputDirectory: string;
    sunoTimeoutMinutes: number;
    songProvider?: SongSource | string;
  };
  voices: VoiceOption[];
  voiceCatalog?: {
    aliyunBailian?: VoiceOption[];
    volcengine?: VoiceOption[];
  };
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

export interface DiagnosticLogEntry {
  ts: string;
  level: 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal' | string;
  category: string;
  event: string;
  message?: string | null;
  flowId?: string | null;
  articleId?: number | null;
  route?: string | null;
  stage?: string | null;
  status?: string | null;
  durationMs?: number | null;
  data?: unknown;
  error?: string | null;
  stack?: string | null;
}

export interface DiagnosticLogQuery {
  limit?: number;
  level?: string;
  category?: string;
  since?: string;
}

export interface DiagnosticLogExportPayload {
  path: string;
  files: string[];
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
