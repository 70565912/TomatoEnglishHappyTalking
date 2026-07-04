export type SunoPageKind = 'create' | 'song' | 'profile' | 'library' | 'home' | 'login' | 'external' | 'unknown';

export interface SunoControlFixture {
  label?: string;
  text?: string;
  context?: string;
  href?: string;
  songUrl?: string;
  title?: string;
  role?: string;
  type?: string;
  className?: string;
  disabled?: boolean;
  interactive?: boolean;
  visible?: boolean;
  hitTestVisible?: boolean;
  rect?: {
    x?: number;
    y?: number;
    width?: number;
    height?: number;
  };
  active?: boolean;
  selected?: boolean;
  pressed?: boolean;
  expanded?: boolean;
  inOpenMenu?: boolean;
  expectedScore?: number;
}

export interface SunoCreateFieldFixture extends SunoControlFixture {
  placeholder?: string;
  value?: string;
}

export interface SunoDownloadDecision {
  action: 'download' | 'openMenu' | 'none';
  reason?: string;
  candidate?: SunoControlFixture;
}

export interface SunoReloadDecision {
  reload: boolean;
  reason: 'target' | 'already-tried' | 'profile-redirect' | 'not-suno-song' | 'missing-target';
}

export interface SunoCreateFieldSelection {
  lyricsField?: SunoCreateFieldFixture;
  styleField?: SunoCreateFieldFixture;
}

export interface SunoCreateFillDecision {
  action:
    | 'acceptCookies'
    | 'switchAdvanced'
    | 'expandStyles'
    | 'clickStyleMagic'
    | 'waitStyleMagic'
    | 'readyToConfirm'
    | 'manualAction';
  missing: string[];
  advancedActive: boolean;
  stylePrompt?: string;
  styleSource?: 'sunoMagic';
  lyricsField?: SunoCreateFieldFixture;
  styleField?: SunoCreateFieldFixture;
  magicControl?: SunoControlFixture;
  styleExpandControl?: SunoControlFixture;
  message?: string;
}

const normalize = (value: unknown): string => String(value ?? '').replace(/\s+/g, ' ').trim();

export function isSunoLoginFlowUrl(url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname.toLowerCase();
  const isSunoHost = host === 'suno.com' || host === 'www.suno.com';
  if (isSunoHost && /\/(?:login|log-in|signin|sign-in|signup|sign-up|auth|oauth|sso)(?:\/|$)/i.test(path)) {
    return true;
  }
  const sunoRelatedAuthHost = host.endsWith('.suno.com') && /auth|account|login|clerk/i.test(host);
  const externalAuthHost =
    /accounts\.google\.com|discord(?:app)?\.com|appleid\.apple\.com|clerk|oauth|auth|login|sso|identity/i.test(host);
  return !isSunoHost && (sunoRelatedAuthHost || externalAuthHost);
}

export function detectSunoPageKind(url: string): SunoPageKind {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return 'unknown';
  }
  if (isSunoLoginFlowUrl(url)) return 'login';
  const host = parsed.hostname.toLowerCase();
  if (host !== 'suno.com' && host !== 'www.suno.com') return 'external';
  const path = parsed.pathname;
  if (/^\/@[^/]+/i.test(path)) return 'profile';
  if (/\/song\//i.test(path)) return 'song';
  if (/\/create(?:\/|$)/i.test(path)) return 'create';
  if (/\/(?:library|me)(?:\/|$)/i.test(path)) return 'library';
  return path === '/' ? 'home' : 'unknown';
}

export function shouldReloadExistingSunoSong(params: {
  currentUrl: string;
  targetSongUrl?: string | null;
  pendingSongUrl?: string | null;
}): SunoReloadDecision {
  const target = normalize(params.targetSongUrl);
  if (!target) return { reload: false, reason: 'missing-target' };
  if (normalize(params.currentUrl).startsWith(target)) return { reload: false, reason: 'target' };
  if (detectSunoPageKind(params.currentUrl) === 'profile') {
    return { reload: false, reason: 'profile-redirect' };
  }
  if (normalize(params.pendingSongUrl) === target) {
    return { reload: false, reason: 'already-tried' };
  }
  return { reload: true, reason: 'not-suno-song' };
}

export function shouldOpenLibraryForExistingDownload(params: {
  currentUrl: string;
  triedLibrary: boolean;
  targetSongUrl?: string | null;
}): boolean {
  if (params.triedLibrary) return false;
  if (!normalize(params.targetSongUrl)) return false;
  return detectSunoPageKind(params.currentUrl) !== 'library';
}

export function looksLikeSunoGeneratedStyle(value: string): boolean {
  const text = normalize(value);
  if (text.length < 8 || text.length > 1000) return false;
  if (/style of music|song description|describe|enter|type|optional|风格描述|曲风描述|输入|填写/i.test(text)) {
    return false;
  }
  return /[,，]|\bbpm\b|vocals?|guitar|drum|bass|piano|synth|folk|pop|rock|rap|house|ambient|trance|beats?|minor|major|music|melody|rhythm|voice|vocal|和声|鼓|吉他|钢琴|贝斯|旋律|节奏|人声|民谣|流行|摇滚|说唱|电子/i.test(text);
}

function isRejectedStyleMagicControl(control: SunoControlFixture): boolean {
  const label = normalize(control.label || control.text);
  const context = normalize(control.context);
  if (/view saved style prompts?|saved style prompts?|refresh recommended styles|recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|lyrics?|create song|download|delete|remove|upload|advanced|simple|sign in|log in|credits|instrumental|extend|cover|\bpersona\b|查看已保存|已保存风格|刷新推荐|推荐风格|添加风格|保存提示|撤销|清空|歌词|创建|下载|删除|上传|登录/i.test(label)) {
    return true;
  }
  return /view saved style prompts?|saved style prompts?|refresh recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|查看已保存|已保存风格|刷新推荐|添加风格|保存提示|撤销|清空/i.test(`${label} ${context}`);
}

export function selectSunoCreateFields(fields: SunoCreateFieldFixture[]): SunoCreateFieldSelection {
  const isUtilityField = (field: SunoCreateFieldFixture) =>
    /\bsearch\b|current page|song title|enhance lyrics|搜索|页码|标题|增强歌词/i.test(
      normalize([field.label, field.placeholder, field.type].join(' ')),
    );
  const scored = fields
    .filter((field) => !field.disabled)
    .filter((field) => field.visible !== false && field.hitTestVisible !== false)
    .map((field) => {
      const context = normalize([field.label, field.text, field.placeholder, field.context, field.value].join(' '));
      const height = field.rect?.height ?? 0;
      let lyricScore = 0;
      let styleScore = 0;
      if (/lyrics?|歌词|歌詞/i.test(context)) lyricScore += 14;
      if (/lyrics?|歌词|歌詞/i.test(normalize([field.label, field.text, field.placeholder].join(' ')))) lyricScore += 8;
      if (height >= 120) lyricScore += 3;
      if (/style|styles|genre|music|describe|description|风格|曲风/i.test(context)) styleScore += 14;
      if (/style|styles|genre|music|describe|description|风格|曲风/i.test(normalize([field.label, field.text, field.placeholder].join(' ')))) {
        styleScore += 8;
      }
      if (height > 0 && height < 180) styleScore += 2;
      if (/prompt|song description/i.test(context)) styleScore += 3;
      if (isUtilityField(field)) {
        lyricScore -= 30;
        styleScore -= 30;
      }
      return { field, lyricScore, styleScore, height };
    });

  const formScored = scored.filter((item) => !isUtilityField(item.field));
  const hasLyricEvidence = (item: { field: SunoCreateFieldFixture; lyricScore: number }) =>
    item.lyricScore >= 8 ||
    /lyrics?|歌词|歌詞/i.test(
      normalize([item.field.label, item.field.text, item.field.placeholder, item.field.context].join(' ')),
    );
  const hasStyleEvidence = (item: { field: SunoCreateFieldFixture; styleScore: number }) => {
    const labeledText = normalize([item.field.label, item.field.text, item.field.context].join(' '));
    const valueText = normalize([item.field.value, item.field.placeholder].join(' '));
    return (
      item.styleScore >= 8 ||
      /style|styles|genre|music|describe|description|风格|曲风/i.test(labeledText) ||
      looksLikeSunoGeneratedStyle(valueText)
    );
  };
  const choose = (scoreName: 'lyricScore' | 'styleScore', exclude?: SunoCreateFieldFixture) =>
    [...formScored]
      .filter((item) => item.field !== exclude)
      .filter((item) => scoreName !== 'lyricScore' || hasLyricEvidence(item))
      .filter((item) => scoreName !== 'styleScore' || hasStyleEvidence(item))
      .sort((left, right) => {
        const scoreDiff = right[scoreName] - left[scoreName];
        if (scoreDiff !== 0) return scoreDiff;
        return scoreName === 'lyricScore' ? right.height - left.height : left.height - right.height;
      })[0]?.field;

  let lyricsField: SunoCreateFieldFixture | undefined = choose('lyricScore');
  let styleField: SunoCreateFieldFixture | undefined = choose('styleScore', lyricsField);
  if (lyricsField && lyricsField.rect?.y != null) {
    const selectedLyricsField = lyricsField;
    const lyricsY = selectedLyricsField.rect?.y ?? 0;
    const lyricsX = selectedLyricsField.rect?.x ?? 0;
    const lyricsWidth = selectedLyricsField.rect?.width ?? 0;
    const lyricsRight = lyricsX + lyricsWidth;
    const styleBelowLyrics = formScored
      .filter((item) => item.field !== selectedLyricsField)
      .filter(hasStyleEvidence)
      .filter((item) => (item.field.rect?.y ?? Number.NEGATIVE_INFINITY) > lyricsY + 20)
      .filter((item) => (item.field.rect?.height ?? 0) >= 60)
      .filter((item) => {
        const x = item.field.rect?.x ?? 0;
        const width = item.field.rect?.width ?? 0;
        const overlap = Math.min(x + width, lyricsRight) - Math.max(x, lyricsX);
        return overlap > Math.min(width, lyricsWidth) * 0.35;
      })
      .sort((left, right) => (left.field.rect?.y ?? 0) - (right.field.rect?.y ?? 0))[0]?.field;
    if (styleBelowLyrics) styleField = styleBelowLyrics;
  }
  if (formScored.length >= 2 && (!lyricsField || !styleField || lyricsField === styleField)) {
    const byHeight = [...formScored].sort((left, right) => right.height - left.height);
    lyricsField = byHeight.find(hasLyricEvidence)?.field;
    styleField = byHeight.find((item) => item.field !== lyricsField && hasStyleEvidence(item))?.field;
  }
  return { lyricsField, styleField };
}

export function simulateSunoCreateFill(params: {
  currentUrl: string;
  controls: SunoControlFixture[];
  fields: SunoCreateFieldFixture[];
  lyrics: string;
  ignoredStyle?: string;
  magicAlreadyRequested?: boolean;
  allowMagicClick?: boolean;
}): SunoCreateFillDecision {
  if (detectSunoPageKind(params.currentUrl) !== 'create') {
    return {
      action: 'manualAction',
      missing: ['createPage'],
      advancedActive: false,
      message: 'not-create-page',
    };
  }

  const cookieControl = params.controls.find((control) => {
    const label = normalize(control.label || control.text);
    const context = normalize(control.context);
    return /cookie|cookies|privacy|consent|tracking|隐私|隱私/i.test(context) &&
      /accept all|accept cookies|accept|agree|i agree|allow all|allow|got it|ok|okay|同意|接受|全部接受|允许全部|允許全部|知道了/i.test(label);
  });
  if (cookieControl) {
    return { action: 'acceptCookies', missing: [], advancedActive: false, magicControl: cookieControl };
  }

  const advancedControls = params.controls.filter((control) => /\badvanced\b/i.test(normalize(control.label || control.text)));
  const advancedActive = advancedControls.some((control) => Boolean(control.active || control.selected || control.pressed));
  if (!advancedActive && advancedControls.length > 0) {
    return {
      action: 'switchAdvanced',
      missing: [],
      advancedActive: false,
      magicControl: advancedControls[0],
    };
  }

  const { lyricsField, styleField } = selectSunoCreateFields(params.fields);
  const missing: string[] = [];
  if (!lyricsField || !normalize(params.lyrics)) missing.push('lyrics');

  const styleExpandControl = params.controls
    .map((control) => {
      const label = normalize(control.label || control.text);
      const context = normalize(control.context);
      const className = normalize(control.className);
      const text = normalize(`${label} ${context}`);
      const styleText = /\bstyles?\b|style of music|style prompt|music style|genre|风格|曲风/i.test(text);
      const collapsed = control.expanded === false || /closed|collapsed|折叠|收起/i.test(`${context} ${className}`);
      if (control.disabled) return null;
      if (control.visible === false || control.hitTestVisible === false) return null;
      if (!styleText) return null;
      if (/more options|additional options|options|更多选项|更多设置/i.test(label)) return null;
      if (/advanced|simple|create song|lyrics?|download|login|sign in|credits|refresh recommended|add style|save prompt|clear all|instrumental|创建|歌词|下载|登录|推荐风格|添加风格/i.test(label)) return null;
      if (!collapsed && styleField) return null;
      let score = 0;
      if (styleText) score += 24;
      if (collapsed) score += 10;
      if (/chevron|accordion|collapse|expand/i.test(className)) score += 4;
      return { control, score };
    })
    .filter((item): item is { control: SunoControlFixture; score: number } => Boolean(item))
    .sort((left, right) => right.score - left.score)[0]?.control;

  if (!styleField) {
    if (missing.length === 0 && styleExpandControl) {
      return {
        action: 'expandStyles',
        missing: [],
        advancedActive,
        lyricsField,
        styleField,
        styleExpandControl,
        message: 'expand-collapsed-styles',
      };
    }
    missing.push('style');
  }
  if (missing.length > 0) {
    return { action: 'manualAction', missing, advancedActive, lyricsField, styleField, styleExpandControl };
  }

  const styleValue = normalize(styleField?.value);
  const ignoredStyle = normalize(params.ignoredStyle);
  if (params.magicAlreadyRequested && styleValue.length >= 6 && styleValue !== ignoredStyle) {
    return {
      action: 'readyToConfirm',
      missing: [],
      advancedActive,
      stylePrompt: styleValue,
      styleSource: 'sunoMagic',
      lyricsField,
      styleField,
    };
  }

  const magicControl = params.controls
    .map((control) => {
      const label = normalize(control.label || control.text);
      const context = normalize(control.context);
      const className = normalize(control.className);
      const positive = /personalize style prompt|magic wand|magic|wand|spark|auto.*style|style.*auto|generate.*style|style.*generate|inspire|style prompt|风格.*魔法|魔法.*风格|自动.*风格|风格.*自动|生成.*风格|风格.*生成|曲风.*生成|生成.*曲风/i;
      const strongMagic = /personalize style prompt|magic wand|magic|wand|spark|魔法|自动.*风格|生成.*风格|曲风.*生成|inspire/i;
      const hasAccent = /accent|aura|magic|wand|spark|blue/i.test(className);
      if (control.disabled || isRejectedStyleMagicControl(control)) return null;
      if (control.visible === false || control.hitTestVisible === false) return null;
      if (!positive.test(label) && !positive.test(context) && !hasAccent) return null;
      let score = 0;
      if (strongMagic.test(label)) score += 18;
      if (strongMagic.test(context)) score += 10;
      if (/style|music|genre|风格|曲风/i.test(label)) score += 8;
      if (/style|music|genre|风格|曲风/i.test(context)) score += 5;
      if (hasAccent) score += 8;
      return { control, score };
    })
    .filter((item): item is { control: SunoControlFixture; score: number } => Boolean(item))
      .sort((left, right) => right.score - left.score)[0]?.control;

  if (!magicControl && styleExpandControl) {
    return {
      action: 'expandStyles',
      missing: [],
      advancedActive,
      lyricsField,
      styleField,
      styleExpandControl,
      message: 'expand-collapsed-styles',
    };
  }

  if (magicControl && params.allowMagicClick && !params.magicAlreadyRequested) {
    return {
      action: 'clickStyleMagic',
      missing: [],
      advancedActive,
      styleSource: 'sunoMagic',
      lyricsField,
      styleField,
      magicControl,
    };
  }
  if (magicControl || params.magicAlreadyRequested) {
    return {
      action: 'waitStyleMagic',
      missing: [],
      advancedActive,
      styleSource: 'sunoMagic',
      lyricsField,
      styleField,
      magicControl,
    };
  }

  return {
    action: 'manualAction',
    missing: ['styleMagic'],
    advancedActive,
    lyricsField,
    styleField,
  };
}

export function selectSunoDownloadCandidate(params: {
  currentUrl: string;
  controls: SunoControlFixture[];
  allowedSongUrls?: string[];
  downloadedSongUrls?: string[];
  pendingSongUrl?: string | null;
  requireExpectedMatch?: boolean;
  currentPageExpectedScore?: number;
  expectedMatchThreshold?: number;
}): SunoDownloadDecision {
  const allowed = new Set((params.allowedSongUrls ?? []).map(normalize).filter(Boolean));
  const downloaded = new Set((params.downloadedSongUrls ?? []).map(normalize).filter(Boolean));
  const pendingSongUrl = normalize(params.pendingSongUrl);
  const currentPageExpectedScore = params.currentPageExpectedScore ?? 0;
  const expectedMatchThreshold = params.expectedMatchThreshold ?? 1;
  const isExpectedMatch = (score: number | undefined) =>
    !params.requireExpectedMatch || (score ?? 0) >= expectedMatchThreshold;
  const onSongDetail = detectSunoPageKind(params.currentUrl) === 'song';
  const openMenuText = normalize(
    params.controls
      .filter((candidate) => candidate.inOpenMenu || /menuitem/i.test(candidate.role ?? ''))
      .map((candidate) => `${candidate.label ?? ''} ${candidate.text ?? ''} ${candidate.context ?? ''}`)
      .join(' '),
  );
  const nonDownloadSongMenuOpen =
    /restore to library|delete permanently|report|恢复到资料库|永久删除|举报/i.test(openMenuText) &&
    !/download|audio|mp3|下载|下載|音频|音頻/i.test(openMenuText);
  if (onSongDetail && nonDownloadSongMenuOpen) {
    return { action: 'none', reason: 'non-download-menu' };
  }

  const scored = params.controls
    .map((candidate) => {
      if (candidate.disabled) return null;
      if (candidate.interactive === false) return null;
      const label = normalize(candidate.label || candidate.text);
      const context = normalize(candidate.context);
      const href = normalize(candidate.href);
      const songUrl = normalize(candidate.songUrl);
      const inOpenMenu = Boolean(candidate.inOpenMenu || /menuitem/i.test(candidate.role ?? ''));
      if (/suno\.com\/@|\/@/i.test(href)) return null;
      if (/\/style\//i.test(href)) return null;
      if (href && !/\/song\//i.test(href) && !/download|audio|mp3/i.test(href)) return null;
      if (allowed.size > 0 && !songUrl && !onSongDetail && !pendingSongUrl) return null;
      if (allowed.size > 0 && songUrl && !allowed.has(songUrl)) return null;
      if (pendingSongUrl && songUrl && songUrl !== pendingSongUrl) return null;
      if (songUrl && downloaded.has(songUrl)) return null;
      if (!songUrl && pendingSongUrl && downloaded.has(pendingSongUrl)) return null;
      if (params.requireExpectedMatch && songUrl && !isExpectedMatch(candidate.expectedScore)) {
        const trustedSongDetail = onSongDetail && params.currentUrl.startsWith(songUrl) && isExpectedMatch(currentPageExpectedScore);
        if (!trustedSongDetail) return null;
      }
      if (params.requireExpectedMatch && pendingSongUrl && !songUrl) {
        const currentUrlMatchesPending = params.currentUrl.startsWith(pendingSongUrl);
        const trustedPendingDetail = onSongDetail && currentUrlMatchesPending && isExpectedMatch(currentPageExpectedScore);
        const trustedLibraryContext = !onSongDetail && isExpectedMatch(candidate.expectedScore);
        const trustedOpenMenu = inOpenMenu && !onSongDetail && isExpectedMatch(currentPageExpectedScore);
        if (!trustedPendingDetail && !trustedLibraryContext && !trustedOpenMenu) return null;
      }

      const audioPattern = /\bmp3\b|\baudio\b|download audio|下载音频|音频下载|音频|聲音/i;
      const downloadPattern = /download|save|export|下载|下載|保存/i;
      const menuPattern = /more|options|menu|actions|ellipsis|更多|菜单|選單|操作/i;
      const hasDownloadIntent =
        audioPattern.test(label) ||
        downloadPattern.test(label) ||
        /download|audio|mp3/i.test(href) ||
        (inOpenMenu && (audioPattern.test(context) || downloadPattern.test(context)));
      const hasMenuIntent =
        menuPattern.test(label) ||
        /more menu contents|more options/i.test(label) ||
        (inOpenMenu && menuPattern.test(context));
      if (!hasDownloadIntent && !hasMenuIntent) return null;
      const previewReject = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
      const incompleteReject = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
      const reject = /video|mp4|wav|midi|stems?|instrumental|share|copy|remix|extend|cover|image|artwork|delete|report|play|like|dislike|publish|创建|create|视频|影片|分享|复制|删除|举报|播放|喜欢|不喜欢|發布|发布|封面|图片|圖片/i;
      const profileReject = /profile|subscription|account|followers|following|upgrade|sign out|signout|log out|logout|my taste|个人主页|账户|账号|订阅|退出/i;
      const sidebarReject = /home|explore|create|studio|library|notifications|labs|terms|policies|upgrade|首页|探索|工作室|资料库|通知|条款/i;
      const globalMenuReject = /earn credits|invite friends|what'?s new|help|about|blog|careers|feedback|instagram|discord|twitter|\bx\b|积分|邀请|帮助|关于|博客|职业|反馈/i;
      const createFormReject = /add audio|browse|upload|record audio|save prompt|clear all form|save lyrics|clear lyrics|generate lyrics|enhance lyrics|saved styles|recommended styles|添加音频|上传|录音|保存歌词|清空歌词|生成歌词|推荐风格/i;
      const openMenuContext = /remix|edit|publish|share|download|manage|queue|playlist|song radio|trash|audio|mp3/i.test(context);
      if (previewReject.test(label) || previewReject.test(context)) return null;
      if (incompleteReject.test(context)) return null;
      if (profileReject.test(label) && !audioPattern.test(label)) return null;
      if (menuPattern.test(label) && (candidate.rect?.x ?? 9999) < 220 && (candidate.rect?.width ?? 0) >= 80) return null;
      if (globalMenuReject.test(label) || /listen-and-rank|release-notes|help\.suno|\/about|\/blog|ashbyhq|x\.com|instagram|discord/i.test(href)) {
        return null;
      }
      if (menuPattern.test(label) && sidebarReject.test(context) && !/download|audio|mp3|remix|edit|publish|share/i.test(context)) {
        return null;
      }
      if (detectSunoPageKind(params.currentUrl) === 'create' && createFormReject.test(label)) return null;
      if (reject.test(label) && !audioPattern.test(label)) return null;
      if (allowed.size > 0 && !songUrl && !onSongDetail && pendingSongUrl && !openMenuContext && (candidate.expectedScore ?? 0) <= 0) {
        return null;
      }
      if (params.requireExpectedMatch && !pendingSongUrl && !isExpectedMatch(candidate.expectedScore)) return null;

      let score = 0;
      if (audioPattern.test(label)) score += 35;
      if (audioPattern.test(context)) score += 12;
      if (downloadPattern.test(label)) score += 24;
      if (downloadPattern.test(context)) score += 8;
      if (menuPattern.test(label)) score += 9;
      if (inOpenMenu && audioPattern.test(label)) score += 28;
      if (inOpenMenu && downloadPattern.test(label)) score += 18;
      if (/more menu contents/i.test(label)) score += 18;
      if (isExpectedMatch(candidate.expectedScore)) score += Math.min(18, 6 + (candidate.expectedScore ?? 0) * 2);
      if (/download|audio|mp3/i.test(href)) score += 20;
      if (href) score += 6;
      if (songUrl) score += 8;
      score -= Math.max(0, label.length - 80) / 30;
      const directDownload =
        audioPattern.test(label) || /download audio|audio download|mp3/i.test(label) || /download|audio|mp3/i.test(href);
      return { candidate, score, directDownload, inOpenMenu };
    })
    .filter((item): item is { candidate: SunoControlFixture; score: number; directDownload: boolean; inOpenMenu: boolean } =>
      Boolean(item),
    )
    .sort((left, right) => right.score - left.score);

  const direct = scored.find((item) => item.directDownload && item.score >= 28);
  if (direct) return { action: 'download', candidate: direct.candidate };
  // 新版 Suno 歌曲详情 More 菜单不带 role="menu"/radix 标记，打开后的
  // “Download”菜单项 inOpenMenu 探测不到；在已核对歌词的详情页上把纯
  // Download 标签按钮当作下一步推进项，避免反复点 More 触发器开关菜单。
  const downloadAdvance =
    onSongDetail && isExpectedMatch(currentPageExpectedScore)
      ? scored.find((item) =>
          /^(?:download\s*)+$/i.test(normalize(item.candidate.label || item.candidate.text)) ||
          /mp3|audio/i.test(normalize(item.candidate.label || item.candidate.text)))
      : undefined;
  if (downloadAdvance) return { action: 'openMenu', candidate: downloadAdvance.candidate };
  const hasDownloadAdvanceStep = scored.some(
    (item) =>
      /^(?:download\s*)+$/i.test(normalize(item.candidate.label || item.candidate.text)) ||
      /mp3|audio/i.test(normalize(item.candidate.label || item.candidate.text)),
  );
  const menu =
    scored.find((item) => item.inOpenMenu && item.score >= 10 && !/more menu contents/i.test(normalize(item.candidate.label || item.candidate.text))) ??
    (!hasDownloadAdvanceStep
        ? scored.find((item) => item.score >= 10)
        : undefined);
  if (menu) return { action: 'openMenu', candidate: menu.candidate };
  return { action: 'none', reason: 'no-safe-candidate' };
}
