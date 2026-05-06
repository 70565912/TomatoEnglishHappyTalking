import { FormEvent, ReactNode, useEffect, useMemo, useState } from 'react';
import { onNativeEvent, sendNative } from './bridge';
import type {
  Article,
  AvatarState,
  ChatState,
  FollowState,
  SettingsState,
  VoiceOption,
} from './types';
import './styles.css';

const idleAvatar: AvatarState = {
  mode: 'idle',
  emotion: 'encouraging',
  mouth: 'closed',
  volume: 0,
};

const sampleText = 'Tom is on a space trip. He sees a bright snack box. It looks like a snack box! Tom opens it slowly.';

const asset = (name: string) => `assets/ui/${name}`;

const fallbackCards = [
  'card-space-snacks.svg',
  'card-daisy-diver.svg',
  'card-rocket-race.svg',
];

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

  const parsedRoute = parseRoute(route);
  const latestArticle = articles[0];

  return (
    <div className="app-shell">
      <div className="soft-grid" aria-hidden="true" />

      <aside className="side-rail">
        <button className="brand-card" onClick={() => navigate('/')}>
          <img src={asset('tomato-wave.svg')} alt="" />
          <span>
            <b>Tomato English</b>
            <small>Happy Talking</small>
          </span>
        </button>
        <NavButton label="大厅" icon="home" active={route === '/'} onClick={() => navigate('/')} />
        <NavButton
          label="新增"
          icon="plus"
          active={route === '/article/new'}
          onClick={() => navigate('/article/new')}
        />
        <NavButton
          label="设置"
          icon="gear"
          active={route === '/settings'}
          onClick={() => navigate('/settings')}
        />
        <UserBadge />
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
            latestArticle={latestArticle}
            avatar={avatar}
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
          <SettingsPage settings={settings} onLoaded={setSettings} />
        )}
      </main>
    </div>
  );
}

function HomePage({
  articles,
  latestArticle,
  avatar,
  onNavigate,
  onDelete,
}: {
  articles: Article[];
  latestArticle?: Article;
  avatar: AvatarState;
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
    <section className="page home-page">
      <header className="home-hero">
        <div>
          <p className="eyebrow">Hi, Tommy!</p>
          <h1>今天也要快乐开口说英语！</h1>
        </div>
        <img className="hero-mascot" src={asset(mascotForAvatar(avatar, 'tomato-wave.svg'))} alt="" />
      </header>

      <div className="dashboard-grid">
        <section className="latest-card">
          <div className="section-heading">
            <span>最新任务卡</span>
          </div>
          {latestArticle ? (
            <div className="latest-content">
              <img src={asset(cardArtForArticle(latestArticle, 0))} alt="" />
              <div>
                <h2>{latestArticle.title}</h2>
                <p>{latestArticle.content}</p>
                <ProgressLine value={latestArticle.averageScore || 75} label="进度" />
                <div className="button-row">
                  <button className="primary-action" onClick={() => onNavigate(`/follow/${latestArticle.id}`)}>
                    <Icon name="mic" /> 跟读
                  </button>
                  <button className="purple-action" onClick={() => onNavigate(`/chat/${latestArticle.id}`)}>
                    <Icon name="chat" /> 对话
                  </button>
                </div>
              </div>
              <img className="card-monster" src={asset('monster-buddy.svg')} alt="" />
            </div>
          ) : (
            <EmptyMission onNavigate={onNavigate} />
          )}
        </section>

        <section className="stats-row" aria-label="learning stats">
          <StatTile label="任务卡" value={articles.length.toString()} icon="card" />
          <StatTile label="句子" value={totalSentences.toString()} icon="sentence" />
          <StatTile label="平均分" value={averageScore > 0 ? averageScore.toString() : '--'} icon="star" />
        </section>
      </div>

      <section className="mission-list-panel">
        <div className="section-heading with-action">
          <span>我的文章任务</span>
          <button onClick={() => onNavigate('/article/new')}>
            <Icon name="plus" /> 新增任务
          </button>
        </div>
        {articles.length === 0 ? (
          <EmptyMission onNavigate={onNavigate} />
        ) : (
          <div className="mission-list">
            {articles.map((article, index) => (
              <MissionRow
                key={article.id}
                article={article}
                art={cardArtForArticle(article, index)}
                onFollow={() => onNavigate(`/follow/${article.id}`)}
                onChat={() => onNavigate(`/chat/${article.id}`)}
                onDelete={() => onDelete(article.id)}
              />
            ))}
          </div>
        )}
      </section>
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
  const [title, setTitle] = useState('Space Snacks');
  const [content, setContent] = useState(sampleText);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sentences = useMemo(() => splitSentences(content), [content]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!title.trim() || !content.trim()) {
      setError('请先填写标题和英文文章');
      return;
    }

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
    <section className="page article-page">
      <TopBar title="新增文章" onBack={onCancel}>
        <button className="ghost-action">
          <Icon name="upload" /> 导入文件
        </button>
      </TopBar>

      <form className="article-editor" onSubmit={submit}>
        <div className="article-form">
          <label>
            <span>文章标题</span>
            <input value={title} maxLength={80} onChange={(event) => setTitle(event.target.value)} />
            <small>{title.length}/80</small>
          </label>
          <label>
            <span>文章内容</span>
            <textarea value={content} onChange={(event) => setContent(event.target.value)} />
            <small>{content.length}/5000</small>
          </label>
        </div>

        <aside className="article-helper-card">
          <img className="helper-tomato" src={asset('tomato-pencil.svg')} alt="" />
          <img className="helper-monster" src={asset('monster-buddy.svg')} alt="" />
        </aside>

        <section className="sentence-board">
          <div className="section-heading">
            <span>句子预览（本地分句）</span>
          </div>
          <div className="sentence-grid">
            {sentences.map((sentence, index) => (
              <div className="sentence-pill" key={`${sentence}-${index}`}>
                <b>{index + 1}</b>
                <span>{sentence}</span>
                <Icon name="drag" />
              </div>
            ))}
          </div>
        </section>

        <footer className="form-footer">
          {error && <span className="error-text">{error}</span>}
          <button type="button" className="ghost-action" onClick={onCancel}>
            取消
          </button>
          <button className="primary-action" disabled={saving}>
            <Icon name="save" /> {saving ? '保存中' : '保存任务'}
          </button>
        </footer>
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

  const step = state?.step ?? 'idle';
  const currentSentence = state?.currentSentence ?? '正在准备句子...';
  const result = state?.result;
  const currentIndex = state?.currentIndex ?? 0;
  const totalSentences = state?.totalSentences ?? 0;

  return (
    <section className="page follow-page">
      <TopBar title={state?.article?.title ?? 'Space Snacks'} onBack={() => onNavigate('/')}>
        <Pager current={currentIndex + 1} total={totalSentences || 2} />
        <button className="ghost-action" onClick={() => onNavigate('/')}>
          <Icon name="exit" /> 退出
        </button>
      </TopBar>

      <div className="follow-layout">
        <main className="follow-main">
          <StepTrack step={step} />
          <div className="sentence-card">
            <h1>
              <strong>{highlightFirstWord(currentSentence)}</strong>
              {currentSentence.replace(highlightFirstWord(currentSentence), '')}
            </h1>
            <button className="ghost-action" onClick={() => sendNative('follow.play')} disabled={isFollowBusy(step)}>
              <Icon name="play" /> 播放原音
            </button>
          </div>
          <Waveform active={['playing', 'recording', 'scoring'].includes(step)} />
          {state?.playbackError && <p className="error-text">{state.playbackError}</p>}
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="record-console">
            <button
              className={step === 'recording' ? 'record-button active' : 'record-button'}
              onClick={() => sendNative(step === 'recording' ? 'follow.recordStop' : 'follow.recordStart')}
              disabled={step !== 'recording' && isFollowBusy(step)}
            >
              <Icon name={step === 'recording' ? 'stop' : 'mic'} />
            </button>
            <span>{step === 'recording' ? '正在录音，点击停止' : '点击录音，跟读这句话'}</span>
          </div>
        </main>

        <aside className="partner-status">
          <h2>伙伴状态</h2>
          <StatusItem image="tomato-headphones.svg" text="听我读..." active />
          <StatusItem image="tomato-wave.svg" text="现在说..." />
          <StatusItem image="tomato-pencil.svg" text="我在思考..." />
          <img className="status-monster" src={asset('monster-mic.svg')} alt="" />
        </aside>

        <PhonePreview mode="follow" />
      </div>

      {result && <ScorePanel result={result} />}

      <div className="bottom-actions">
        <button className="ghost-action" onClick={() => sendNative('follow.retry')}>
          <Icon name="replay" /> 重播
        </button>
        <button className="ghost-action" onClick={() => sendNative('follow.retry')}>
          <Icon name="refresh" /> 再试一次
        </button>
        <button className="primary-action" onClick={() => sendNative('follow.next')}>
          下一句 <Icon name="arrow" />
        </button>
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

  const step = state?.step ?? 'init';
  const canTalk = step === 'userIdle' || step === 'recording';
  const messages = state?.messages ?? [];

  const sendText = async () => {
    if (!text.trim()) return;
    await sendNative('chat.sendText', { text });
    setText('');
  };

  return (
    <section className="page chat-page">
      <TopBar title={state?.articleTitle || 'Space Snacks'} onBack={() => onNavigate('/')}>
        <Pager current={state?.questionCount ?? 1} total={state?.maxQuestions ?? 8} />
        <button className="danger-light">结束对话</button>
      </TopBar>

      <div className="chat-layout">
        <main className="chat-room-card">
          <div className="chat-list">
            {messages.map((message) => (
              <div
                className={`chat-bubble ${message.isAi ? 'ai-bubble' : 'user-bubble'}`}
                key={message.id}
              >
                {message.isAi && <img src={asset('tomato-wave.svg')} alt="" />}
                <div>
                  <p>{message.text}</p>
                  {message.isAi && (
                    <button onClick={() => sendNative('chat.replay', { messageId: message.id })}>
                      <Icon name="sound" />
                    </button>
                  )}
                </div>
              </div>
            ))}
            {messages.length === 0 && (
              <div className="chat-empty">
                <img src={asset('monster-buddy.svg')} alt="" />
                <span>番茄伙伴正在准备第一个问题。</span>
              </div>
            )}
          </div>
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="chat-input">
            <Icon name="keyboard" />
            <input
              value={text}
              onChange={(event) => setText(event.target.value)}
              placeholder="输入或按住说英语"
              onKeyDown={(event) => {
                if (event.key === 'Enter') void sendText();
              }}
            />
            <button className="ghost-action" onClick={sendText} disabled={step !== 'userIdle'}>
              发送
            </button>
            <button
              className={step === 'recording' ? 'record-button mini active' : 'record-button mini'}
              disabled={!canTalk}
              onClick={() => sendNative(step === 'recording' ? 'chat.recordStop' : 'chat.recordStart')}
            >
              <Icon name={step === 'recording' ? 'stop' : 'mic'} />
            </button>
          </div>
        </main>

        <aside className="chat-side-card">
          <img src={asset('tomato-wave.svg')} alt="" />
          <div className="voice-state">
            <WaveMini />
            <span>我在和你对话...</span>
          </div>
          <ProgressLine value={12.5} label="对话进度" />
          <div className="reward-preview">
            <span>奖励预览</span>
            <img src={asset('reward-star.svg')} alt="" />
            <img src={asset('reward-brick.svg')} alt="" />
          </div>
        </aside>

        <PhonePreview mode="chat" />
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
  const [selectedVoiceId, setSelectedVoiceId] = useState(settings?.tts.speakerId ?? '');
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<string | null>(null);

  useEffect(() => {
    sendNative<SettingsState>('settings.load')
      .then((payload) => {
        setCurrent(payload);
        setSelectedVoiceId(payload.tts.speakerId);
        onLoaded(payload);
      })
      .catch((error) => setStatus(error.message));
  }, [onLoaded]);

  useEffect(() => {
    setCurrent(settings);
    if (settings) {
      setSelectedVoiceId(settings.tts.speakerId);
    }
  }, [settings]);

  if (!current) {
    return <LoadingPanel text="正在打开声音控制台" />;
  }

  const selectedVoice = current.voices.find((voice) => voice.id === selectedVoiceId);
  const spotlightVoices = pickSpotlightVoices(current.voices, selectedVoiceId);
  const unchanged = selectedVoiceId === current.tts.speakerId;

  const saveVoice = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selectedVoiceId) return;

    setSaving(true);
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('settings.saveVoice', {
        speakerId: selectedVoiceId,
      });
      setCurrent(payload);
      setSelectedVoiceId(payload.tts.speakerId);
      onLoaded(payload);
      setStatus('声音设置已保存');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '声音设置保存失败');
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="page settings-page">
      <form className="settings-shell" onSubmit={saveVoice}>
        <div className="settings-nav">
          <button className="nav-button active" type="button"><Icon name="gear" /> 设置</button>
          <button className="nav-button" type="button"><Icon name="home" /> 大厅</button>
          <button className="nav-button" type="button"><Icon name="plus" /> 新增</button>
        </div>

        <main className="settings-main">
          <div className="settings-tabs">
            <button className="active" type="button">API 与服务</button>
            <button type="button">语音设置</button>
            <button type="button">其他</button>
          </div>

          <div className="settings-grid">
            <FieldGroup title="服务状态（运行时）">
              <ServiceRow title="TTS 语音合成" status="已连接" />
              <ServiceRow title="BigASR 语音识别" status="已连接" />
              <ServiceRow title="Realtime 对话服务" status="已连接" />
            </FieldGroup>

            <FieldGroup title="连接发音人">
              <label className="voice-picker">
                <span>选择声音</span>
                <select
                  aria-label="选择声音"
                  value={selectedVoiceId}
                  onChange={(event) => {
                    setSelectedVoiceId(event.target.value);
                    setStatus(null);
                  }}
                >
                  {current.voices.map((voice) => (
                    <option key={voice.id} value={voice.id}>
                      {`${voice.name} · ${displayVoiceLanguage(voice.lang)}`}
                    </option>
                  ))}
                </select>
              </label>
              <div className="voice-list">
                {spotlightVoices.slice(0, 3).map((voice) => (
                  <button
                    className={`voice-card ${voice.id === selectedVoiceId ? 'selected' : ''}`}
                    key={voice.id}
                    type="button"
                    onClick={() => setSelectedVoiceId(voice.id)}
                  >
                    <span className="voice-avatar">{voice.name.slice(0, 1)}</span>
                    <span>
                      <b>{voice.name}</b>
                      <small>{displayVoiceLanguage(voice.lang)} · {voice.gender === 'female' ? '女声' : '男声'}</small>
                    </span>
                    <WaveMini />
                  </button>
                ))}
              </div>
            </FieldGroup>

            <FieldGroup title="TTS 资源">
              <div className="resource-card">
                <span>TTS 资源 ID</span>
                <b>{current.tts.resourceId}</b>
                {selectedVoice && <small>当前声音：{selectedVoice.name}</small>}
              </div>
            </FieldGroup>
          </div>

          <footer className="settings-footer">
            <button className="primary-action" disabled={saving || unchanged}>
              <Icon name="save" /> {saving ? '保存中' : '保存声音'}
            </button>
            {status && <span role="status">{status}</span>}
          </footer>
        </main>

        <aside className="settings-art">
          <PhonePreview mode="settings" />
          <img src={asset('tomato-secure.svg')} alt="" />
        </aside>
      </form>
    </section>
  );
}

function ScorePanel({ result }: { result: NonNullable<FollowState['result']> }) {
  return (
    <section className="score-panel">
      <div className="score-summary">
        <div className="score-meter">
          <b>{Math.round(result.overallScore)}</b>
          <span>综合得分</span>
        </div>
        <div className="stars">
          <img src={asset('reward-star.svg')} alt="" />
          <img src={asset('reward-star.svg')} alt="" />
          <img src={asset('reward-star.svg')} alt="" />
          <img src={asset('reward-star.svg')} alt="" />
          <span />
        </div>
        <strong>太棒了！继续保持！</strong>
      </div>

      <div className="score-bars">
        <ScoreBar label="Accuracy 准确度" value={result.accuracyScore} tone="green" />
        <ScoreBar label="Fluency 流利度" value={result.fluencyScore} tone="blue" />
        <ScoreBar label="Completeness 完整度" value={result.completenessScore} tone="purple" />
        <ScoreBar label="Prosody 语调语感" value={result.prosodyScore} tone="orange" />
      </div>

      <div className="recognized-box">
        <span>识别结果</span>
        <p>{result.recognizedText || 'Tom finds a bright snack box.'}</p>
        <Icon name="sound" />
      </div>

      <div className="word-score-grid">
        {result.words.map((word, index) => (
          <span className={word.score >= 80 ? 'good' : word.score >= 60 ? 'ok' : 'low'} key={`${word.word}-${index}`}>
            <b>{word.word}</b>
            <small>{Math.round(word.score)}</small>
          </span>
        ))}
      </div>

      <img className="score-tomato" src={asset('tomato-celebrate.svg')} alt="" />
      <img className="score-monster" src={asset('monster-buddy.svg')} alt="" />
    </section>
  );
}

function MissionRow({
  article,
  art,
  onFollow,
  onChat,
  onDelete,
}: {
  article: Article;
  art: string;
  onFollow: () => void;
  onChat: () => void;
  onDelete: () => void;
}) {
  const score = article.averageScore > 0 ? Math.round(article.averageScore) : 40;
  return (
    <article className="mission-row">
      <img src={asset(art)} alt="" />
      <div>
        <h3>{article.title}</h3>
        <p>{article.sentenceCount} 句子 · 最近学习 今天</p>
      </div>
      <span className="ring-score">{score}%</span>
      <button className="primary-action" onClick={onFollow}><Icon name="mic" /> 跟读</button>
      <button className="purple-action" onClick={onChat}><Icon name="chat" /> 对话</button>
      <button className="delete-action" onClick={onDelete}>删除</button>
    </article>
  );
}

function EmptyMission({ onNavigate }: { onNavigate: (path: string) => void }) {
  return (
    <div className="empty-mission">
      <img src={asset('tomato-pencil.svg')} alt="" />
      <p>先放入一篇英文短文，番茄伙伴会把它变成闯关任务。</p>
      <button className="primary-action" onClick={() => onNavigate('/article/new')}>
        <Icon name="plus" /> 创建第一张任务卡
      </button>
    </div>
  );
}

function TopBar({
  title,
  onBack,
  children,
}: {
  title: string;
  onBack: () => void;
  children?: ReactNode;
}) {
  return (
    <header className="top-bar">
      <button className="icon-button" onClick={onBack} aria-label="返回">
        <Icon name="back" />
      </button>
      <h1>{title}</h1>
      <div className="top-actions">{children}</div>
    </header>
  );
}

function UserBadge() {
  return (
    <div className="user-badge">
      <span>Tommy</span>
      <b>Lv.12 Star</b>
      <ProgressLine value={65} label="650 / 1000 XP" compact />
    </div>
  );
}

function StatusItem({ image, text, active = false }: { image: string; text: string; active?: boolean }) {
  return (
    <div className={`status-item ${active ? 'active' : ''}`}>
      <img src={asset(image)} alt="" />
      <span>{text}</span>
    </div>
  );
}

function PhonePreview({ mode }: { mode: 'follow' | 'chat' | 'settings' }) {
  return (
    <aside className={`phone-preview ${mode}`}>
      <div className="phone-screen">
        <header>
          <span>{mode === 'settings' ? '设置' : 'Space Snacks'}</span>
          <Icon name="gear" />
        </header>
        {mode === 'settings' ? (
          <div className="phone-settings">
            <ServiceRow title="TTS 语音合成" status="已连接" />
            <ServiceRow title="BigASR 语音识别" status="已连接" />
            <ServiceRow title="Realtime 对话服务" status="已连接" />
            <div className="resource-card">
              <span>TTS 资源 ID</span>
              <b>seed-tts-2.0</b>
            </div>
          </div>
        ) : (
          <>
            <Pager current={mode === 'follow' ? 1 : 1} total={mode === 'follow' ? 2 : 8} />
            <p>{mode === 'follow' ? 'Tom finds a bright snack box.' : 'What did Tom find?'}</p>
            <Waveform active />
            <img src={asset(mode === 'follow' ? 'tomato-headphones.svg' : 'tomato-wave.svg')} alt="" />
            <button className="record-button mini"><Icon name="mic" /></button>
          </>
        )}
      </div>
    </aside>
  );
}

function ServiceRow({ title, status }: { title: string; status: string }) {
  return (
    <div className="service-row">
      <span>
        <b>{title}</b>
        <small>{status}</small>
      </span>
      <i />
    </div>
  );
}

function StepTrack({ step }: { step: string }) {
  const items = [
    { id: 'play', label: '播放', active: ['loadingTts', 'playing'].includes(step) },
    { id: 'repeat', label: '跟读', active: step === 'recording' },
    { id: 'recognize', label: '识别', active: ['scoring', 'result', 'completed'].includes(step) },
  ];
  return (
    <div className="step-track">
      {items.map((item, index) => (
        <span className={item.active ? 'active' : ''} key={item.id}>
          <b>{index + 1}</b>
          {item.label}
        </span>
      ))}
    </div>
  );
}

function Waveform({ active }: { active: boolean }) {
  return (
    <div className={`waveform ${active ? 'active' : ''}`}>
      {Array.from({ length: 36 }, (_, index) => (
        <span key={index} style={{ animationDelay: `${index * 36}ms` }} />
      ))}
    </div>
  );
}

function WaveMini() {
  return (
    <span className="wave-mini">
      <i /><i /><i /><i />
    </span>
  );
}

function ScoreBar({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: 'green' | 'blue' | 'purple' | 'orange';
}) {
  return (
    <div className={`score-bar ${tone}`}>
      <span>{label}</span>
      <div><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></div>
      <b>{Math.round(value)}</b>
    </div>
  );
}

function StatTile({ label, value, icon }: { label: string; value: string; icon: string }) {
  return (
    <div className="stat-tile">
      <span className={`stat-icon ${icon}`} />
      <span>{label}</span>
      <b>{value}</b>
    </div>
  );
}

function ProgressLine({
  value,
  label,
  compact = false,
}: {
  value: number;
  label: string;
  compact?: boolean;
}) {
  return (
    <div className={`progress-line ${compact ? 'compact' : ''}`}>
      <span>{label}</span>
      <div><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></div>
    </div>
  );
}

function Pager({ current, total }: { current: number; total: number }) {
  return (
    <div className="pager">
      <Icon name="chevron" />
      <span>{current} / {total}</span>
      <Icon name="chevron" />
    </div>
  );
}

function FieldGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="field-group">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function LoadingPanel({ text }: { text: string }) {
  return (
    <div className="loading-panel">
      <img src={asset('tomato-wave.svg')} alt="" />
      <p>{text}</p>
    </div>
  );
}

function NavButton({
  label,
  icon,
  active,
  onClick,
}: {
  label: string;
  icon: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button className={`nav-button ${active ? 'active' : ''}`} onClick={onClick}>
      <Icon name={icon} />
      {label}
    </button>
  );
}

function Icon({ name }: { name: string }) {
  return <span className={`icon icon-${name}`} aria-hidden="true" />;
}

function cardArtForArticle(article: Article, index: number): string {
  const title = article.title.toLowerCase();
  if (title.includes('daisy') || title.includes('diver')) return 'card-daisy-diver.svg';
  if (title.includes('rocket') || title.includes('race')) return 'card-rocket-race.svg';
  return fallbackCards[index % fallbackCards.length];
}

function mascotForAvatar(avatar: AvatarState, fallback: string): string {
  if (avatar.mode === 'listening' || avatar.mode === 'speaking') return 'tomato-headphones.svg';
  if (avatar.mode === 'celebrating') return 'tomato-celebrate.svg';
  if (avatar.mode === 'thinking') return 'tomato-pencil.svg';
  return fallback;
}

function splitSentences(text: string): string[] {
  return text
    .split(/(?<=[.!?])\s+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 8);
}

function highlightFirstWord(sentence: string): string {
  return sentence.trim().split(/\s+/)[0] || '';
}

function displayVoiceLanguage(lang: string): string {
  return lang.replaceAll('中文', '中文/英文');
}

function pickSpotlightVoices(voices: VoiceOption[], selectedVoiceId: string): VoiceOption[] {
  const preferred = voices.filter((voice) =>
    [
      selectedVoiceId,
      'en_female_dacey_uranus_bigtts',
      'en_male_tim_uranus_bigtts',
      'zh_female_xiaoxue_uranus_bigtts',
      'zh_male_naiqimengwa_uranus_bigtts',
      'zh_female_yingyujiaoxue_uranus_bigtts',
    ].includes(voice.id),
  );
  const fallback = voices.slice(0, 6);
  return Array.from(new Map([...preferred, ...fallback].map((voice) => [voice.id, voice])).values()).slice(0, 6);
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
