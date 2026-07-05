export type PictureBookPromptRefreshTarget = 'bookDescription' | 'chapterPlan';

export type BlockingOverlayConfig = {
  title: string;
  detail: string;
  timeoutSeconds: number;
};

export function pictureBookGroupSubmitOverlay(sceneCount: number): BlockingOverlayConfig {
  const count = Math.max(1, sceneCount);
  return {
    title: '正在提交绘本组图',
    detail: `正在按 ${count} 个分镜生成连续组图，请等待服务返回。`,
    timeoutSeconds: Math.min(2700, Math.max(180, count * 150)),
  };
}

export function pictureBookSinglePageSubmitOverlay(pageNumber: number): BlockingOverlayConfig {
  return {
    title: '正在提交单张绘本图',
    detail: `正在重新生成第 ${pageNumber} 页绘本图，请等待服务返回。`,
    timeoutSeconds: 180,
  };
}

export function pictureBookPromptRefreshOverlay(
  target: PictureBookPromptRefreshTarget,
): BlockingOverlayConfig {
  return {
    title: '正在刷新绘本提示词',
    detail:
      target === 'chapterPlan'
        ? 'AI 正在生成章节描述和分镜描述。'
        : 'AI 正在生成书籍简介。',
    timeoutSeconds: target === 'chapterPlan' ? 180 : 90,
  };
}
