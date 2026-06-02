import { FormEvent, ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { onNativeEvent, sendNative } from './bridge';
import { splitSentences } from './sentenceSplitter';
import type {
  Article,
  ChatState,
  FollowState,
  SettingsState,
} from './types';
import './styles.css';

const sampleText = 'Tom is on a space trip. He sees a bright snack box. It looks like a snack box! Tom opens it slowly.';

const asset = (name: string) => `assets/ui/${name}`;

const fallbackCards = [
  'card-space-snacks.png',
  'card-daisy-diver.png',
  'card-rocket-race.png',
];

const mascotBlinkFrames = [
  'lego/mascot-blink/frame-01.png',
  'lego/mascot-blink/frame-02.png',
  'lego/mascot-blink/frame-03.png',
  'lego/mascot-blink/frame-04.png',
  'lego/mascot-blink/frame-05.png',
  'lego/mascot-blink/frame-06.png',
  'lego/mascot-blink/frame-07.png',
];

const legoMascot = {
  idle: mascotBlinkFrames[0],
  blink: mascotBlinkFrames[3],
  blinkFrames: mascotBlinkFrames,
};

const pngAsset = {
  star: 'lego/prop-star.png',
  brick: 'lego/prop-bricks.png',
  legoLogo: 'lego/brand-tomato.png',
  legoListen: 'lego/prop-headphones.png',
  legoRecord: 'lego/prop-microphone.png',
  legoScore: 'lego/prop-shield.png',
  legoMonster: 'lego/prop-monster.png',
};

function App() {
  const [route, setRoute] = useHashRoute();
  const [articles, setArticles] = useState<Article[]>([]);
  const [followState, setFollowState] = useState<FollowState | null>(null);
  const [chatState, setChatState] = useState<ChatState | null>(null);
  const [settings, setSettings] = useState<SettingsState | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const navigate = (path: string) => {
    setNotice(null);
    setRoute(path);
    void sendNative('app.navigate', { path });
  };

  useEffect(() => {
    let isMounted = true;
    const offArticles = onNativeEvent<{ articles: Article[] }>(
      'article.state',
      (payload) => {
        if (isMounted) setArticles(payload.articles);
      },
    );
    const offFollow = onNativeEvent<FollowState>('follow.state', (payload) => {
      if (isMounted) setFollowState(payload);
    });
    const offChat = onNativeEvent<ChatState>('chat.state', (payload) => {
      if (isMounted) setChatState(payload);
    });
    const offSettings = onNativeEvent<SettingsState>('settings.state', (payload) => {
      if (isMounted) setSettings(payload);
    });

    sendNative<{ articles: Article[] }>('app.ready')
      .then((payload) => {
        if (isMounted) setArticles(payload.articles);
      })
      .catch((error) => {
        if (isMounted) setNotice(error.message);
      });

    return () => {
      isMounted = false;
      offArticles();
      offFollow();
      offChat();
      offSettings();
    };
  }, []);

  useEffect(() => {
    if (!notice) return undefined;
    const timer = window.setTimeout(() => setNotice(null), 2800);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const parsedRoute = parseRoute(route);
  const latestArticle = articles[0];

  return (
    <div className="app-shell">
      <div className="soft-grid" aria-hidden="true" />

      <aside className="side-rail">
        <button className="brand-card" onClick={() => navigate('/')}>
          <img src={asset(pngAsset.legoLogo)} alt="" />
          <span className="brand-copy">
            <b>
              <span>Tomato</span>
              <span>English</span>
            </b>
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
            <button onClick={() => setNotice(null)}>知道了</button>
          </div>
        )}

        {parsedRoute.kind === 'home' && (
          <HomePage
            articles={articles}
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
              navigate('/');
              setNotice('任务卡已加入大厅');
            }}
          />
        )}

        {parsedRoute.kind === 'follow' && (
          <FollowPage
            articleId={parsedRoute.articleId}
            state={followState}
            onNavigate={navigate}
            onLoaded={setFollowState}
          />
        )}

        {parsedRoute.kind === 'chat' && (
          <ChatPage
            articleId={parsedRoute.articleId}
            state={chatState}
            onNavigate={navigate}
            onLoaded={setChatState}
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
  onNavigate,
  onDelete,
}: {
  articles: Article[];
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
    <section className="page home-page">
      <header className="home-hero">
        <div className="hero-copy">
          <p className="eyebrow">Level 12 · Speaking Quest</p>
          <h1>今天也要快乐开口说英语！</h1>
          <p>把文章变成闯关卡：先听、再跟读、最后和番茄伙伴对话。</p>
          <div className="hero-actions">
            <button className="primary-action" onClick={() => onNavigate(latestArticle ? `/follow/${latestArticle.id}` : '/article/new')}>
              <Icon name="play" /> 开始闯关
            </button>
            <button className="ghost-action" onClick={() => onNavigate('/article/new')}>
              <Icon name="plus" /> 新建任务
            </button>
          </div>
        </div>
        <div className="hero-stage">
          <MascotBlinker className="hero-mascot" />
          <div className="xp-chip">
            <span>Next reward</span>
            <b>+350 XP</b>
          </div>
        </div>
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
                <span className="quest-tag">主线任务</span>
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

      <section className="quest-map">
        <div className="section-heading">
          <span>今日闯关路线</span>
        </div>
        <div className="map-steps">
          <MapStep number="1" title="听原音" text="番茄伙伴先示范" active />
          <MapStep number="2" title="开口读" text="录音跟读拿星星" />
          <MapStep number="3" title="AI 对话" text="用文章内容聊天" />
          <MapStep number="4" title="领奖励" text="收集番茄积木" />
        </div>
      </section>

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
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const sentences = useMemo(() => splitSentences(content), [content]);
  const canSave = Boolean(title.trim() && content.trim() && sentences.length > 0) && !saving;

  const importFile = async (file: File | undefined) => {
    if (!file) return;
    if (!file.type.startsWith('text/') && !/\.(txt|md|markdown)$/i.test(file.name)) {
      setError('请导入 txt 或 markdown 文本文件');
      return;
    }
    const text = await file.text();
    const cleaned = text.trim();
    if (!cleaned) {
      setError('这个文件没有可导入的文字内容');
      return;
    }
    setContent(cleaned.slice(0, 5000));
    if (!title.trim()) {
      setTitle(file.name.replace(/\.[^.]+$/, '').slice(0, 80));
    }
    setError(null);
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!title.trim() || !content.trim() || sentences.length === 0) {
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
        <button className="ghost-action" type="button" onClick={() => fileInputRef.current?.click()}>
          <Icon name="upload" /> 导入文件
        </button>
        <input
          ref={fileInputRef}
          className="visually-hidden"
          type="file"
          accept=".txt,.md,.markdown,text/plain,text/markdown"
          onChange={(event) => {
            void importFile(event.target.files?.[0]);
            event.target.value = '';
          }}
        />
      </TopBar>

      <form className="article-editor" onSubmit={submit}>
        <div className="article-form">
          <label>
            <span>文章标题</span>
            <input
              value={title}
              maxLength={80}
              placeholder="给这张任务卡起个名字"
              onChange={(event) => {
                setTitle(event.target.value);
                setError(null);
              }}
            />
            <small>{title.length}/80</small>
          </label>
          <label>
            <span>文章内容</span>
            <textarea
              value={content}
              maxLength={5000}
              placeholder={sampleText}
              onChange={(event) => {
                setContent(event.target.value);
                setError(null);
              }}
            />
            <small>{content.length}/5000</small>
          </label>
        </div>

        <aside className="article-helper-card">
          <MascotBlinker className="helper-tomato" />
          <div className="helper-copy">
            <b>任务编辑台</b>
            <span>短句越清楚，闯关越顺滑。</span>
          </div>
        </aside>

        <section className="sentence-board">
          <div className="section-heading">
            <span>句子预览（本地分句）</span>
          </div>
          {sentences.length > 0 ? (
            <div className="sentence-grid">
              {sentences.map((sentence, index) => (
              <div className="sentence-pill" key={`${sentence}-${index}`}>
                <b>{index + 1}</b>
                <span>{sentence}</span>
                <Icon name="drag" />
              </div>
              ))}
            </div>
          ) : (
            <p className="sentence-empty">输入英文短文后，这里会自动切成适合跟读的短句。</p>
          )}
        </section>

        <footer className="form-footer">
          {error && <span className="error-text">{error}</span>}
          <button type="button" className="ghost-action" onClick={onCancel}>
            取消
          </button>
          <button className="primary-action" disabled={!canSave}>
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
  onLoaded,
}: {
  articleId: number;
  state: FollowState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: FollowState) => void;
}) {
  const [commandBusy, setCommandBusy] = useState(false);

  useEffect(() => {
    let isMounted = true;

    setCommandBusy(false);
    onLoaded({ status: 'loading' });

    const openAndPlay = async () => {
      try {
        const payload = await sendNative<FollowState>('follow.open', { articleId });
        if (!isMounted || !payload) return;
        onLoaded(payload);

        if (payload.status === 'ready' && payload.step !== 'completed') {
          const played = await sendNative<FollowState>('follow.play');
          if (isMounted && played) onLoaded(played);
        }
      } catch (error) {
        if (!isMounted) return;
        onLoaded({
          status: 'error',
          step: 'idle',
          playbackState: 'failed',
          error: error instanceof Error ? error.message : '无法打开跟读任务',
        });
      }
    };

    void openAndPlay();
    return () => {
      isMounted = false;
    };
  }, [articleId, onLoaded]);

  const runFollowCommand = async (type: string): Promise<FollowState | null> => {
    setCommandBusy(true);
    try {
      const payload = await sendNative<FollowState>(type);
      if (payload) onLoaded(payload);
      return payload ?? null;
    } catch (error) {
      onLoaded({
        status: 'error',
        step: 'idle',
        playbackState: 'failed',
        error: error instanceof Error ? error.message : '跟读操作失败，请重试',
      });
      return null;
    } finally {
      setCommandBusy(false);
    }
  };

  const playCurrent = () => {
    void runFollowCommand('follow.play');
  };

  const replayCurrent = () => {
    void runFollowCommand('follow.replay');
  };

  const retryCurrent = () => {
    void runFollowCommand('follow.retry');
  };

  const advanceSentence = () => {
    void (async () => {
      setCommandBusy(true);
      try {
        const next = await sendNative<FollowState>('follow.next');
        if (next) onLoaded(next);
        if (next?.status === 'ready' && next.step !== 'completed') {
          const played = await sendNative<FollowState>('follow.play');
          if (played) onLoaded(played);
        }
      } catch (error) {
        onLoaded({
          status: 'error',
          step: 'idle',
          playbackState: 'failed',
          error: error instanceof Error ? error.message : '无法进入下一句，请重试',
        });
      } finally {
        setCommandBusy(false);
      }
    })();
  };

  if (!state || state.status === 'loading') {
    return (
      <section className="page follow-page">
        <TopBar title="跟读任务准备中" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <LoadingPanel text="正在准备句子、中文翻译和原音" />
      </section>
    );
  }

  if (state.status === 'error') {
    return (
      <section className="page follow-page">
        <TopBar title="跟读任务暂时打不开" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <section className="loading-panel">
          <img src={asset(legoMascot.idle)} alt="" />
          <p>{state.error ?? '跟读任务打开失败，请回到大厅后重试。'}</p>
        </section>
      </section>
    );
  }

  const step = state?.step ?? 'idle';
  const currentSentence = state?.currentSentence ?? '正在准备句子...';
  const currentTranslation = state?.currentTranslation ?? '';
  const result = state?.result;
  const currentIndex = state?.currentIndex ?? 0;
  const totalSentences = state?.totalSentences ?? 0;
  const playbackCue = followPlaybackCue(step, state?.playbackState, state?.playbackError);
  const bottomActionsDisabled = isFollowActionLocked(step) || commandBusy;
  const canReplayCurrent =
    !bottomActionsDisabled &&
    step !== 'completed' &&
    (['success', 'failed'].includes(state?.playbackState ?? '') || step === 'result' || Boolean(result));
  const canRetryCurrent =
    !bottomActionsDisabled &&
    step !== 'completed' &&
    Boolean(result || state?.error || state?.playbackError);
  const canAdvanceSentence = !bottomActionsDisabled && step !== 'completed' && totalSentences > 0;
  const advanceLabel = state?.isLastSentence ? '完成' : '下一句';
  const activePartnerStatus = followPartnerStatus(step, state?.playbackState, result);
  const canRecordCurrent =
    !commandBusy &&
    (step === 'recording' || (step === 'idle' && state?.playbackState === 'success'));

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
            <div className="sentence-copy">
              <h1>
                <strong>{highlightFirstWord(currentSentence)}</strong>
                {currentSentence.replace(highlightFirstWord(currentSentence), '')}
              </h1>
              {currentTranslation && <p className="sentence-translation">{currentTranslation}</p>}
            </div>
            <button className="ghost-action" onClick={playCurrent} disabled={isFollowBusy(step) || commandBusy}>
              <Icon name="play" /> {followPlayButtonLabel(step)}
            </button>
            <p className={`playback-cue ${state?.playbackError ? 'error' : ''}`}>{playbackCue}</p>
          </div>
          <Waveform active={['playing', 'recording', 'scoring'].includes(step)} />
          {state?.playbackError && <p className="error-text">{state.playbackError}</p>}
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="record-console">
            <div className="record-primary">
              <button
                className={step === 'recording' ? 'record-button active' : 'record-button'}
                aria-label={step === 'recording' ? '停止录音' : '开始录音'}
                onClick={() => {
                  void runFollowCommand(step === 'recording' ? 'follow.recordStop' : 'follow.recordStart');
                }}
                disabled={!canRecordCurrent}
              >
                <Icon name={step === 'recording' ? 'stop' : 'mic'} />
              </button>
              <span>{followRecordCue(step, state?.playbackState, state?.playbackError)}</span>
            </div>
            <div className="record-actions">
              <button className="ghost-action" onClick={replayCurrent} disabled={!canReplayCurrent}>
                <Icon name="replay" /> 重播
              </button>
              <button className="ghost-action" onClick={retryCurrent} disabled={!canRetryCurrent}>
                <Icon name="refresh" /> 再试一次
              </button>
              <button className="primary-action" onClick={advanceSentence} disabled={!canAdvanceSentence}>
                {advanceLabel} <Icon name="arrow" />
              </button>
            </div>
          </div>
        </main>

        <aside className="partner-status">
          <h2>伙伴状态</h2>
          <StatusItem image={pngAsset.legoListen} text="听原音" active={activePartnerStatus === 'listen'} />
          <StatusItem image={pngAsset.legoRecord} text="跟读录音" active={activePartnerStatus === 'record'} />
          <StatusItem image={pngAsset.legoScore} text="查看得分" active={activePartnerStatus === 'score'} />
          {result && <FollowScoreBadge result={result} />}
          <img className="status-monster" src={asset(pngAsset.legoMonster)} alt="" />
        </aside>
      </div>
    </section>
  );
}

function ChatPage({
  articleId,
  state,
  onNavigate,
  onLoaded,
}: {
  articleId: number;
  state: ChatState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: ChatState) => void;
}) {
  const [text, setText] = useState('');
  const [revealedTranslations, setRevealedTranslations] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    let isMounted = true;
    sendNative<ChatState>('chat.open', { articleId })
      .then((payload) => {
        if (isMounted && payload) onLoaded(payload);
      })
      .catch((error) => {
        if (!isMounted) return;
        onLoaded({
          articleTitle: 'Space Snacks',
          step: 'error',
          error: error instanceof Error ? error.message : '无法打开对话任务',
          questionCount: 0,
          maxQuestions: 8,
          messages: [],
        });
      });
    return () => {
      isMounted = false;
    };
  }, [articleId, onLoaded]);

  useEffect(() => {
    setRevealedTranslations(new Set());
  }, [articleId]);

  const step = state?.step ?? 'init';
  const canTalk = step === 'userIdle' || step === 'recording';
  const questionCount = state?.questionCount ?? 0;
  const maxQuestions = state?.maxQuestions ?? 8;
  const messages = state?.messages ?? [];
  const chatCue = chatSideCue(step);
  const chatInputPlaceholder = chatInputCue(step);
  const chatProgress = maxQuestions > 0 ? (questionCount / maxQuestions) * 100 : 0;

  const sendText = async () => {
    const draft = text.trim();
    if (!draft || step !== 'userIdle') return;
    setText('');
    try {
      await sendNative('chat.sendText', { text: draft });
    } catch {
      setText(draft);
    }
  };

  return (
    <section className="page chat-page">
      <TopBar title={state?.articleTitle || 'Space Snacks'} onBack={() => onNavigate('/')}>
        <Pager current={state?.questionCount ?? 1} total={state?.maxQuestions ?? 8} />
        <button className="danger-light" onClick={() => onNavigate('/')}>结束对话</button>
      </TopBar>

      <div className="chat-layout">
        <main className="chat-room-card">
          <div className="chat-list">
            {messages.map((message) => (
              <div
                className={`chat-bubble ${message.isAi ? 'ai-bubble' : 'user-bubble'}`}
                key={message.id}
              >
                {message.isAi && <img src={asset(legoMascot.idle)} alt="" />}
                <div>
                  <p>{message.text}</p>
                  {message.isAi && (
                    <button
                      aria-label="重播这句"
                      disabled={['waitingStart', 'playing'].includes(message.playbackState)}
                      onClick={() => sendNative('chat.replay', { messageId: message.id })}
                    >
                      <Icon name="sound" />
                    </button>
                  )}
                  {message.translation && (
                    <button
                      className={`chat-translation ${revealedTranslations.has(message.id) ? 'revealed' : ''}`}
                      type="button"
                      onClick={() => {
                        setRevealedTranslations((previous) => {
                          const next = new Set(previous);
                          next.add(message.id);
                          return next;
                        });
                      }}
                    >
                      {message.translation}
                    </button>
                  )}
                </div>
              </div>
            ))}
            {messages.length === 0 && (
              <div className="chat-empty">
                <img src={asset(pngAsset.legoMonster)} alt="" />
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
              placeholder={chatInputPlaceholder}
              disabled={step !== 'userIdle'}
              onKeyDown={(event) => {
                if (event.key === 'Enter') void sendText();
              }}
            />
            <button className="ghost-action" onClick={sendText} disabled={step !== 'userIdle' || !text.trim()}>
              发送
            </button>
            <button
              className={step === 'recording' ? 'record-button mini active' : 'record-button mini'}
              disabled={!canTalk}
              aria-label={step === 'recording' ? '停止录音' : '开始录音'}
              onClick={() => sendNative(step === 'recording' ? 'chat.recordStop' : 'chat.recordStart')}
            >
              <Icon name={step === 'recording' ? 'stop' : 'mic'} />
            </button>
          </div>
        </main>

        <aside className="chat-side-card">
          <MascotBlinker className="chat-mascot" />
          <div className="voice-state">
            <WaveMini />
            <span>{chatCue}</span>
          </div>
          <ProgressLine value={chatProgress} label={`对话进度 ${questionCount} / ${maxQuestions}`} />
          <div className="reward-preview">
            <span>奖励预览</span>
            <img src={asset(pngAsset.star)} alt="" />
            <img src={asset(pngAsset.brick)} alt="" />
          </div>
        </aside>
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
  const selectedVoiceButtonRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    let isMounted = true;
    sendNative<SettingsState>('settings.load')
      .then((payload) => {
        if (!isMounted) return;
        setCurrent(payload);
        setSelectedVoiceId(payload.tts.speakerId);
        onLoaded(payload);
      })
      .catch((error) => {
        if (isMounted) setStatus(error.message);
      });
    return () => {
      isMounted = false;
    };
  }, [onLoaded]);

  useEffect(() => {
    setCurrent(settings);
    if (settings) {
      setSelectedVoiceId(settings.tts.speakerId);
    }
  }, [settings]);

  useEffect(() => {
    selectedVoiceButtonRef.current?.scrollIntoView?.({ block: 'center', inline: 'nearest' });
  }, [selectedVoiceId]);

  if (!current) {
    return <LoadingPanel text="正在打开声音设置" />;
  }

  const selectedVoice = current.voices.find((voice) => voice.id === selectedVoiceId);
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
      <form className="settings-shell voice-settings-shell" onSubmit={saveVoice}>
        <main className="settings-main">
          <header className="settings-header">
            <p className="eyebrow">Voice</p>
            <h1>选择番茄伙伴的发音</h1>
            <p>选择一个适合孩子跟读和对话的声音，保存后会用于朗读和聊天。</p>
          </header>

          <div className="settings-grid voice-settings-grid">
            <FieldGroup title="发音人">
              <div className="voice-list-header">
                <span>可选声音</span>
                <small>{current.voices.length} 个发音人</small>
              </div>
              <div className="voice-list-scroll" role="listbox" aria-label="可选声音">
                <div className="voice-list">
                  {current.voices.map((voice) => (
                  <button
                    className={`voice-card ${voice.id === selectedVoiceId ? 'selected' : ''}`}
                    key={voice.id}
                    ref={voice.id === selectedVoiceId ? selectedVoiceButtonRef : undefined}
                    type="button"
                    role="option"
                    aria-selected={voice.id === selectedVoiceId}
                    onClick={() => {
                      setSelectedVoiceId(voice.id);
                      setStatus(null);
                    }}
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
              </div>
            </FieldGroup>

            <aside className="selected-voice-panel">
              <MascotBlinker className="settings-mascot" />
              <span>当前声音</span>
              <b>{selectedVoice?.name ?? '未选择'}</b>
              {selectedVoice && (
                <small>{displayVoiceLanguage(selectedVoice.lang)} · {selectedVoice.gender === 'female' ? '女声' : '男声'}</small>
              )}
            </aside>
          </div>

          <footer className="settings-footer">
            <button className="primary-action" disabled={saving || unchanged}>
              <Icon name="save" /> {saving ? '保存中' : '保存声音'}
            </button>
            {status && <span role="status">{status}</span>}
          </footer>
        </main>
      </form>
    </section>
  );
}

function FollowScoreBadge({ result }: { result: NonNullable<FollowState['result']> }) {
  return (
    <div className="follow-score-badge">
      <span>总体评分</span>
      <b>{Math.round(result.overallScore)}</b>
      <small>{result.isMock ? '示例评分' : '本句得分'}</small>
    </div>
  );
}

function MapStep({
  number,
  title,
  text,
  active = false,
}: {
  number: string;
  title: string;
  text: string;
  active?: boolean;
}) {
  return (
    <article className={`map-step ${active ? 'active' : ''}`}>
      <b>{number}</b>
      <span>
        <strong>{title}</strong>
        <small>{text}</small>
      </span>
    </article>
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
      <img src={asset(legoMascot.idle)} alt="" />
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

function MascotBlinker({ className }: { className: string }) {
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    let blinkTimer: number | undefined;
    let frameTimer: number | undefined;

    const scheduleBlink = () => {
      const delay = 2400 + Math.round(Math.random() * 3600);
      blinkTimer = window.setTimeout(() => {
        let nextFrame = 1;
        const playFrame = () => {
          setFrameIndex(nextFrame);
          nextFrame += 1;

          if (nextFrame < legoMascot.blinkFrames.length) {
            frameTimer = window.setTimeout(playFrame, 58);
            return;
          }

          frameTimer = window.setTimeout(() => {
            setFrameIndex(0);
            scheduleBlink();
          }, 72);
        };

        playFrame();
      }, delay);
    };

    scheduleBlink();
    return () => {
      if (blinkTimer !== undefined) window.clearTimeout(blinkTimer);
      if (frameTimer !== undefined) window.clearTimeout(frameTimer);
    };
  }, []);

  return (
    <span className={`mascot-blinker ${className}`} aria-hidden="true">
      <img className="mascot-frame" src={asset(legoMascot.blinkFrames[frameIndex])} alt="" />
    </span>
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
      <img src={asset(legoMascot.idle)} alt="" />
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
  if (title.includes('daisy') || title.includes('diver')) return 'card-daisy-diver.png';
  if (title.includes('rocket') || title.includes('race')) return 'card-rocket-race.png';
  return fallbackCards[index % fallbackCards.length];
}

function highlightFirstWord(sentence: string): string {
  return sentence.trim().split(/\s+/)[0] || '';
}

function displayVoiceLanguage(lang: string): string {
  return lang.replaceAll('中文', '中文/英文');
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

function isFollowActionLocked(step: string): boolean {
  return ['loadingTts', 'playing', 'recording', 'scoring'].includes(step);
}

function followPlayButtonLabel(step: string): string {
  if (step === 'loadingTts') return '准备原音';
  if (step === 'playing') return '播放中';
  return '播放原音';
}

function followPlaybackCue(
  step: string,
  playbackState?: string,
  playbackError?: string | null,
): string {
  if (playbackError || playbackState === 'failed') return '原音播放失败，可以点重播再试。';
  if (step === 'loadingTts' || playbackState === 'waitingStart') return '正在准备原音，请稍等一下。';
  if (step === 'playing' || playbackState === 'playing') return '正在播放原音，听完再开始跟读。';
  if (step === 'recording') return '认真读出来，番茄伙伴正在听。';
  if (step === 'scoring') return '正在识别和评分，请稍等。';
  if (step === 'result') return '看完得分后，可以重播、重试或进入下一句。';
  if (step === 'completed') return '这篇文章已经完成啦。';
  if (playbackState === 'success') return '原音播放完成，现在可以开始跟读。';
  return '先听一遍原音，再点击录音跟读。';
}

function followRecordCue(
  step: string,
  playbackState?: string,
  playbackError?: string | null,
): string {
  if (step === 'loadingTts') return '原音准备中，稍后再录音';
  if (step === 'playing') return '原音播放中，听完再录音';
  if (step === 'recording') return '正在录音，点击停止';
  if (step === 'scoring') return '正在评分，请稍等';
  if (playbackError || playbackState === 'failed') return '先重播原音，再开始跟读';
  if (playbackState === 'success') return '点击录音，跟读这句话';
  return '先听完原音，再开始录音';
}

function followPartnerStatus(
  step: string,
  playbackState?: string,
  result?: FollowState['result'],
): 'listen' | 'record' | 'score' {
  if (['recording'].includes(step)) return 'record';
  if (['scoring', 'result', 'completed'].includes(step) || result) return 'score';
  if (playbackState === 'success' && step === 'idle') return 'record';
  return 'listen';
}

function chatSideCue(step: string): string {
  if (step === 'init') return '番茄伙伴正在准备问题...';
  if (step === 'aiSpeaking') return '番茄伙伴正在说，认真听。';
  if (step === 'recording') return '正在听你说英语。';
  if (step === 'processing') return '番茄伙伴正在想答案。';
  if (step === 'completed') return '这轮对话完成啦。';
  if (step === 'error') return '对话暂时卡住了。';
  return '轮到你说英语啦。';
}

function chatInputCue(step: string): string {
  if (step === 'init') return '正在准备第一个问题';
  if (step === 'aiSpeaking') return '先听番茄伙伴说完';
  if (step === 'recording') return '正在录音';
  if (step === 'processing') return '番茄伙伴思考中';
  if (step === 'completed') return '这轮对话已经完成';
  if (step === 'error') return '可以返回后重新进入对话';
  return '输入或按住说英语';
}

export default App;
