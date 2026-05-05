import { FormEvent, ReactNode, useEffect, useMemo, useState } from 'react';
import { onNativeEvent, sendNative } from './bridge';
import type {
  Article,
  AvatarState,
  ChatState,
  FollowState,
  SettingsState,
} from './types';
import './styles.css';

const idleAvatar: AvatarState = {
  mode: 'idle',
  emotion: 'encouraging',
  mouth: 'closed',
  volume: 0,
};

function App() {
  const [route, setRoute] = useHashRoute();
  const [articles, setArticles] = useState<Article[]>([]);
  const [followState, setFollowState] = useState<FollowState | null>(null);
  const [chatState, setChatState] = useState<ChatState | null>(null);
  const [settings, setSettings] = useState<SettingsState | null>(null);
  const [avatar, setAvatar] = useState<AvatarState>(idleAvatar);
  const [notice, setNotice] = useState<string | null>(null);

  const navigate = (path: string) => {
    setRoute(path);
    void sendNative('app.navigate', { path });
  };

  useEffect(() => {
    const offArticles = onNativeEvent<{ articles: Article[] }>(
      'article.state',
      (payload) => setArticles(payload.articles),
    );
    const offFollow = onNativeEvent<FollowState>('follow.state', (payload) => {
      setFollowState(payload);
      if (payload.avatar) setAvatar(payload.avatar);
    });
    const offChat = onNativeEvent<ChatState>('chat.state', (payload) => {
      setChatState(payload);
      if (payload.avatar) setAvatar(payload.avatar);
    });
    const offSettings = onNativeEvent<SettingsState>('settings.state', setSettings);
    const offAvatar = onNativeEvent<AvatarState>('avatar.state', setAvatar);

    sendNative<{ articles: Article[] }>('app.ready')
      .then((payload) => setArticles(payload.articles))
      .catch((error) => setNotice(error.message));

    return () => {
      offArticles();
      offFollow();
      offChat();
      offSettings();
      offAvatar();
    };
  }, []);

  const latestArticle = articles[0];
  const parsedRoute = parseRoute(route);

  return (
    <div className="app-shell">
      <div className="bubble-layer" aria-hidden="true">
        <span className="bubble bubble-one" />
        <span className="bubble bubble-two" />
        <span className="bubble bubble-three" />
      </div>

      <aside className="side-rail">
        <button className="brand-chip" onClick={() => navigate('/')}>
          <span className="brand-mark">T</span>
          <span>Tomato Quest</span>
        </button>
        <NavButton label="大厅" active={route === '/'} onClick={() => navigate('/')} />
        <NavButton
          label="文章"
          active={route === '/article/new'}
          onClick={() => navigate('/article/new')}
        />
        <NavButton
          label="设置"
          active={route === '/settings'}
          onClick={() => navigate('/settings')}
        />
      </aside>

      <main className="main-stage">
        {notice && (
          <div className="toast" role="status">
            {notice}
            <button onClick={() => setNotice(null)}>OK</button>
          </div>
        )}

        {parsedRoute.kind === 'home' && (
          <HomePage
            articles={articles}
            avatar={avatar}
            latestArticle={latestArticle}
            onNavigate={navigate}
            onDelete={async (articleId) => {
              const payload = await sendNative<{ articles: Article[] }>(
                'article.delete',
                { articleId },
              );
              setArticles(payload.articles);
            }}
          />
        )}

        {parsedRoute.kind === 'article' && (
          <ArticlePage
            onCancel={() => navigate('/')}
            onSaved={(payload) => {
              setArticles(payload.articles);
              setNotice('任务卡已加入大厅');
              navigate('/');
            }}
          />
        )}

        {parsedRoute.kind === 'follow' && (
          <FollowPage
            articleId={parsedRoute.articleId}
            state={followState}
            onNavigate={navigate}
          />
        )}

        {parsedRoute.kind === 'chat' && (
          <ChatPage
            articleId={parsedRoute.articleId}
            state={chatState}
            onNavigate={navigate}
          />
        )}

        {parsedRoute.kind === 'settings' && (
          <SettingsPage
            settings={settings}
            onLoaded={setSettings}
          />
        )}
      </main>
    </div>
  );
}

function HomePage({
  articles,
  avatar,
  latestArticle,
  onNavigate,
  onDelete,
}: {
  articles: Article[];
  avatar: AvatarState;
  latestArticle?: Article;
  onNavigate: (path: string) => void;
  onDelete: (articleId: number) => Promise<void>;
}) {
  const totalSentences = articles.reduce((sum, article) => sum + article.sentenceCount, 0);
  const averageScore =
    articles.length === 0
      ? 0
      : Math.round(
          articles.reduce((sum, article) => sum + article.averageScore, 0) /
            articles.length,
        );

  return (
    <section className="page-grid home-grid">
      <div className="hero-panel">
        <div>
          <p className="eyebrow">今日任务大厅</p>
          <h1>开启英语能量挑战</h1>
          <p className="hero-copy">Nova 已准备好陪你听、说、闯关。</p>
          <div className="hero-actions">
            <button
              className="primary-action"
              onClick={() =>
                latestArticle
                  ? onNavigate(`/follow/${latestArticle.id}`)
                  : onNavigate('/article/new')
              }
            >
              快速开始
            </button>
            <button className="ghost-action" onClick={() => onNavigate('/article/new')}>
              添加任务卡
            </button>
          </div>
        </div>
        <AvatarStage avatar={avatar} size="large" />
      </div>

      <div className="stat-strip">
        <StatTile label="任务卡" value={articles.length.toString()} />
        <StatTile label="句子能量" value={totalSentences.toString()} />
        <StatTile label="平均分" value={averageScore > 0 ? averageScore.toString() : '--'} />
      </div>

      <div className="quest-board">
        <div className="section-title">
          <span>练习任务卡</span>
          <button onClick={() => onNavigate('/article/new')}>新增</button>
        </div>
        {articles.length === 0 ? (
          <div className="empty-zone">
            <span className="empty-orbit" />
            <h2>任务大厅还空着</h2>
            <p>先放入一篇英文短文，Nova 会把它变成闯关练习。</p>
            <button className="primary-action" onClick={() => onNavigate('/article/new')}>
              创建第一张任务卡
            </button>
          </div>
        ) : (
          <div className="article-list">
            {articles.map((article) => (
              <ArticleQuestCard
                key={article.id}
                article={article}
                onFollow={() => onNavigate(`/follow/${article.id}`)}
                onChat={() => onNavigate(`/chat/${article.id}`)}
                onDelete={() => onDelete(article.id)}
              />
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

function ArticlePage({
  onCancel,
  onSaved,
}: {
  onCancel: () => void;
  onSaved: (payload: { article: Article; articles: Article[] }) => void;
}) {
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sentenceCount = useMemo(
    () => content.split(/[.!?]+/).filter((line) => line.trim().length > 0).length,
    [content],
  );

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setSaving(true);
    setError(null);
    try {
      const payload = await sendNative<{ article: Article; articles: Article[] }>(
        'article.create',
        { title, content },
      );
      onSaved(payload);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="page-grid editor-grid">
      <div className="mission-header">
        <p className="eyebrow">任务卡工坊</p>
        <h1>把文章变成英语关卡</h1>
      </div>
      <form className="editor-panel" onSubmit={submit}>
        <label>
          <span>任务标题</span>
          <input
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="The Moon Cake Mission"
          />
        </label>
        <label>
          <span>英文文章</span>
          <textarea
            value={content}
            onChange={(event) => setContent(event.target.value)}
            placeholder="Paste your English story here..."
          />
        </label>
        <div className="editor-footer">
          <span className="energy-pill">预计 {sentenceCount} 个句子能量</span>
          {error && <span className="error-text">{error}</span>}
          <div className="button-row">
            <button type="button" className="ghost-action" onClick={onCancel}>
              返回
            </button>
            <button className="primary-action" disabled={saving}>
              {saving ? '保存中' : '生成任务卡'}
            </button>
          </div>
        </div>
      </form>
    </section>
  );
}

function FollowPage({
  articleId,
  state,
  onNavigate,
}: {
  articleId: number;
  state: FollowState | null;
  onNavigate: (path: string) => void;
}) {
  useEffect(() => {
    void sendNative('follow.open', { articleId });
  }, [articleId]);

  const avatar = state?.avatar ?? idleAvatar;
  const step = state?.step ?? 'idle';
  const result = state?.result;

  return (
    <section className="page-grid practice-grid">
      <div className="practice-top">
        <button className="back-button" onClick={() => onNavigate('/')}>
          返回大厅
        </button>
        <div className="level-chip">
          Level {(state?.currentIndex ?? 0) + 1} / {state?.totalSentences ?? '--'}
        </div>
      </div>

      <div className="practice-stage">
        <AvatarStage avatar={avatar} size="large" />
        <div className="sentence-console">
          <p className="eyebrow">{state?.article?.title ?? '跟读训练'}</p>
          <h1>{state?.currentSentence ?? '正在准备句子...'}</h1>
          <StepTrack step={step} />
          {state?.playbackError && <p className="error-text">{state.playbackError}</p>}
          {state?.error && <p className="error-text">{state.error}</p>}
        </div>
      </div>

      {result && <ScorePanel result={result} />}

      <div className="control-dock">
        {step === 'recording' ? (
          <button className="danger-action" onClick={() => sendNative('follow.recordStop')}>
            停止录音
          </button>
        ) : result ? (
          <>
            <button className="ghost-action" onClick={() => sendNative('follow.retry')}>
              再试一次
            </button>
            <button className="primary-action" onClick={() => sendNative('follow.next')}>
              下一关
            </button>
          </>
        ) : (
          <>
            <button
              className="ghost-action"
              disabled={isFollowBusy(step)}
              onClick={() => sendNative('follow.play')}
            >
              听一遍
            </button>
            <button
              className="primary-action"
              disabled={isFollowBusy(step)}
              onClick={() => sendNative('follow.recordStart')}
            >
              开始跟读
            </button>
          </>
        )}
      </div>
    </section>
  );
}

function ChatPage({
  articleId,
  state,
  onNavigate,
}: {
  articleId: number;
  state: ChatState | null;
  onNavigate: (path: string) => void;
}) {
  const [text, setText] = useState('');

  useEffect(() => {
    void sendNative('chat.open', { articleId });
  }, [articleId]);

  const avatar = state?.avatar ?? idleAvatar;
  const step = state?.step ?? 'init';
  const canTalk = step === 'userIdle' || step === 'recording';

  const sendText = async () => {
    if (!text.trim()) return;
    await sendNative('chat.sendText', { text });
    setText('');
  };

  return (
    <section className="page-grid chat-grid">
      <div className="practice-top">
        <button className="back-button" onClick={() => onNavigate('/')}>
          返回大厅
        </button>
        <div className="level-chip">
          Round {state?.questionCount ?? 0} / {state?.maxQuestions ?? 8}
        </div>
      </div>

      <div className="chat-room">
        <AvatarStage avatar={avatar} size="medium" />
        <div className="chat-panel">
          <p className="eyebrow">{state?.articleTitle || 'AI 对话训练'}</p>
          <div className="chat-list">
            {(state?.messages ?? []).map((message) => (
              <div
                className={`chat-bubble ${message.isAi ? 'ai-bubble' : 'user-bubble'}`}
                key={message.id}
              >
                <span>{message.isAi ? 'Nova' : 'You'}</span>
                <p>{message.text}</p>
                {message.isAi && (
                  <button onClick={() => sendNative('chat.replay', { messageId: message.id })}>
                    重播
                  </button>
                )}
              </div>
            ))}
            {state?.messages.length === 0 && (
              <div className="empty-chat">Nova 正在整理第一个问题。</div>
            )}
          </div>
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="chat-input">
            <input
              value={text}
              onChange={(event) => setText(event.target.value)}
              placeholder="Type your answer..."
              onKeyDown={(event) => {
                if (event.key === 'Enter') void sendText();
              }}
            />
            <button className="ghost-action" onClick={sendText} disabled={step !== 'userIdle'}>
              发送
            </button>
            <button
              className={step === 'recording' ? 'danger-action' : 'primary-action'}
              disabled={!canTalk}
              onClick={() =>
                sendNative(step === 'recording' ? 'chat.recordStop' : 'chat.recordStart')
              }
            >
              {step === 'recording' ? '停止' : '语音'}
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}

function SettingsPage({
  settings,
  onLoaded,
}: {
  settings: SettingsState | null;
  onLoaded: (settings: SettingsState) => void;
}) {
  const [current, setCurrent] = useState<SettingsState | null>(settings);

  useEffect(() => {
    sendNative<SettingsState>('settings.load').then((payload) => {
      setCurrent(payload);
      onLoaded(payload);
    });
  }, [onLoaded]);

  useEffect(() => {
    setCurrent(settings);
  }, [settings]);

  if (!current) {
    return <LoadingPanel text="正在打开装备控制台" />;
  }

  const selectedVoice = current.voices.find(
    (voice) => voice.id === current.tts.speakerId,
  );

  return (
    <section className="page-grid settings-grid">
      <div className="mission-header">
        <p className="eyebrow">装备控制台</p>
        <h1>语音和对话配置</h1>
      </div>

      <div className="settings-panel">
        <FieldGroup title="火山引擎 API Key">
          <ConfigStatus
            ready={current.volcApi.configured}
            label={current.volcApi.configured ? '统一 API Key 已读取' : '统一 API Key 未读取'}
            detail="TTS、BigASR 与 AI 对话共用这一份本机加密配置。"
          />
        </FieldGroup>

        <FieldGroup title="语音合成">
          <ReadonlyMeta label="密钥来源" value="统一火山引擎 API Key" />
          <ReadonlyMeta label="资源" value={current.tts.resourceId || 'seed-tts-2.0'} />
          <ReadonlyMeta
            label="伙伴声音"
            value={
              selectedVoice
                ? `${selectedVoice.name} (${selectedVoice.lang})`
                : current.tts.speakerId || '默认声音'
            }
          />
        </FieldGroup>

        <FieldGroup title="语音识别">
          <ReadonlyMeta label="识别模式" value={current.bigAsr.mode || 'BigASR 闯关评分'} />
          <ReadonlyMeta label="密钥来源" value="统一火山引擎 API Key" />
        </FieldGroup>

        <FieldGroup title="AI 对话">
          <ReadonlyMeta label="密钥来源" value="统一火山引擎 API Key" />
          <ReadonlyMeta label="App ID" value={current.realtime.appId || '未设置'} />
          <ReadonlyMeta label="配置方式" value="启动时自动读取" />
        </FieldGroup>
      </div>
    </section>
  );
}

function ConfigStatus({
  ready,
  label,
  detail,
}: {
  ready: boolean;
  label: string;
  detail: string;
}) {
  return (
    <div className={`config-status ${ready ? 'ready' : 'missing'}`}>
      <span className="status-dot" />
      <div>
        <b>{label}</b>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function ReadonlyMeta({ label, value }: { label: string; value: string }) {
  return (
    <div className="readonly-meta">
      <span>{label}</span>
      <b>{value}</b>
    </div>
  );
}

function AvatarStage({
  avatar,
  size,
}: {
  avatar: AvatarState;
  size: 'medium' | 'large';
}) {
  return (
    <div className={`avatar-stage ${size} ${avatar.mode}`} aria-label="Nova avatar">
      <div className="avatar-rings" />
      <div className="avatar-core">
        <div className="avatar-face">
          <span className={`eye left ${avatar.emotion}`} />
          <span className={`eye right ${avatar.emotion}`} />
          <span className={`mouth ${avatar.mouth}`} />
        </div>
        <div className="avatar-spark spark-a" />
        <div className="avatar-spark spark-b" />
      </div>
      <div className="avatar-name">Nova</div>
    </div>
  );
}

function ArticleQuestCard({
  article,
  onFollow,
  onChat,
  onDelete,
}: {
  article: Article;
  onFollow: () => void;
  onChat: () => void;
  onDelete: () => void;
}) {
  return (
    <article className="quest-card">
      <div className="quest-card-top">
        <span className="quest-token">{article.sentenceCount}</span>
        <div>
          <h3>{article.title}</h3>
          <p>{article.content}</p>
        </div>
      </div>
      <div className="quest-meta">
        <span>Score {article.averageScore > 0 ? Math.round(article.averageScore) : '--'}</span>
        <span>{new Date(article.createdAt).toLocaleDateString()}</span>
      </div>
      <div className="button-row">
        <button className="primary-action" onClick={onFollow}>
          跟读
        </button>
        <button className="ghost-action" onClick={onChat}>
          聊天
        </button>
        <button className="delete-action" onClick={onDelete}>
          删除
        </button>
      </div>
    </article>
  );
}

function ScorePanel({ result }: { result: NonNullable<FollowState['result']> }) {
  return (
    <div className="score-panel">
      <div className="score-orb">{Math.round(result.overallScore)}</div>
      <div className="score-bars">
        <ScoreBar label="准确" value={result.accuracyScore} />
        <ScoreBar label="流利" value={result.fluencyScore} />
        <ScoreBar label="完整" value={result.completenessScore} />
        <ScoreBar label="韵律" value={result.prosodyScore} />
      </div>
      <div className="word-cloud">
        {result.words.map((word, index) => (
          <span className={word.score >= 80 ? 'good' : word.score >= 60 ? 'ok' : 'low'} key={`${word.word}-${index}`}>
            {word.word}
          </span>
        ))}
      </div>
    </div>
  );
}

function StepTrack({ step }: { step: string }) {
  const items = [
    { id: 'listen', label: '听音', active: ['loadingTts', 'playing'].includes(step) },
    { id: 'record', label: '跟读', active: step === 'recording' },
    { id: 'score', label: '评分', active: ['scoring', 'result', 'completed'].includes(step) },
  ];
  return (
    <div className="step-track">
      {items.map((item) => (
        <span className={item.active ? 'active' : ''} key={item.id}>
          {item.label}
        </span>
      ))}
    </div>
  );
}

function ScoreBar({ label, value }: { label: string; value: number }) {
  return (
    <div className="score-bar">
      <span>{label}</span>
      <div>
        <i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} />
      </div>
      <b>{Math.round(value)}</b>
    </div>
  );
}

function StatTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat-tile">
      <span>{label}</span>
      <b>{value}</b>
    </div>
  );
}

function NavButton({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button className={`nav-button ${active ? 'active' : ''}`} onClick={onClick}>
      <span className="nav-dot" />
      {label}
    </button>
  );
}

function FieldGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="field-group">
      <h2>{title}</h2>
      {children}
    </div>
  );
}

function LoadingPanel({ text }: { text: string }) {
  return (
    <div className="loading-panel">
      <span className="loading-ring" />
      <p>{text}</p>
    </div>
  );
}

function useHashRoute(): [string, (path: string) => void] {
  const read = () => window.location.hash.replace(/^#/, '') || '/';
  const [route, setRouteState] = useState(read);

  useEffect(() => {
    const onHashChange = () => setRouteState(read());
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  const setRoute = (path: string) => {
    window.location.hash = path;
    setRouteState(path);
  };

  return [route, setRoute];
}

function parseRoute(route: string):
  | { kind: 'home' }
  | { kind: 'article' }
  | { kind: 'follow'; articleId: number }
  | { kind: 'chat'; articleId: number }
  | { kind: 'settings' } {
  if (route === '/article/new') return { kind: 'article' };
  if (route === '/settings' || route === '/profile') return { kind: 'settings' };

  const follow = route.match(/^\/follow\/(\d+)/);
  if (follow) return { kind: 'follow', articleId: Number(follow[1]) };

  const chat = route.match(/^\/chat\/(\d+)/);
  if (chat) return { kind: 'chat', articleId: Number(chat[1]) };

  return { kind: 'home' };
}

function isFollowBusy(step: string): boolean {
  return ['loadingTts', 'playing', 'scoring'].includes(step);
}

export default App;
