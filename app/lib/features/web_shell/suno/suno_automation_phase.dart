/// Explicit Suno automation phases (internal orchestration).
enum SunoPhase {
  idle,
  waitingLogin,
  fillingCreate,
  waitingConfirm,
  postCreateWaiting,
  openingCandidate,
  verifyingDetail,
  downloading,
  scanningLibrary,
  completedStandby,
  complete,
  manualAction,
  failed,
}

/// Bridge / UI status strings (kept for Web UI compatibility).
extension SunoPhaseStatus on SunoPhase {
  String get statusKey {
    switch (this) {
      case SunoPhase.idle:
        return 'idle';
      case SunoPhase.waitingLogin:
        return 'waitingLogin';
      case SunoPhase.fillingCreate:
      case SunoPhase.waitingConfirm:
        return 'waitingConfirm';
      case SunoPhase.postCreateWaiting:
      case SunoPhase.openingCandidate:
      case SunoPhase.verifyingDetail:
        return 'creating';
      case SunoPhase.downloading:
      case SunoPhase.scanningLibrary:
        return 'downloading';
      case SunoPhase.completedStandby:
      case SunoPhase.complete:
        return 'complete';
      case SunoPhase.manualAction:
        return 'manualAction';
      case SunoPhase.failed:
        return 'failed';
    }
  }

  static SunoPhase fromStatusKey(String status) {
    switch (status) {
      case 'waitingLogin':
        return SunoPhase.waitingLogin;
      case 'waitingConfirm':
        return SunoPhase.waitingConfirm;
      case 'creating':
        return SunoPhase.postCreateWaiting;
      case 'downloading':
        return SunoPhase.downloading;
      case 'complete':
        return SunoPhase.complete;
      case 'manualAction':
        return SunoPhase.manualAction;
      case 'failed':
        return SunoPhase.failed;
      default:
        return SunoPhase.idle;
    }
  }
}
