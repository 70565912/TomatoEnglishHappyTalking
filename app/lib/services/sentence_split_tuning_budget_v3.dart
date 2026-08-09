import 'dart:convert';

import 'text_generation_service.dart';

class SentenceSplitTuningBudgetExceededV3 implements Exception {
  const SentenceSplitTuningBudgetExceededV3(this.message);

  final String message;

  @override
  String toString() => message;
}

class SentenceSplitTuningBudgetV3 {
  SentenceSplitTuningBudgetV3({this.limitCny = 50});

  final double limitCny;
  double _settledCny = 0;
  double _reservedCny = 0;
  int _remoteCalls = 0;
  int _cachedCalls = 0;
  int _failedCalls = 0;
  int _inputTokens = 0;
  int _outputTokens = 0;

  double get settledCny => _settledCny;
  double get reservedCny => _reservedCny;
  double get remainingCny => limitCny - _settledCny - _reservedCny;

  SentenceSplitTuningReservationV3 reserve({
    required String provider,
    required String model,
    required List<TextGenerationTurn> turns,
    required int maxOutputTokens,
  }) {
    if (limitCny <= 0 || maxOutputTokens <= 0) {
      throw const SentenceSplitTuningBudgetExceededV3(
        'V3 调优预算或最大输出 token 配置无效',
      );
    }
    // UTF-8 bytes are a conservative upper bound for tokenizer pieces. Add a
    // fixed envelope per message for role and chat serialization overhead.
    final inputUpperBoundTokens = turns.fold<int>(
      0,
      (sum, turn) => sum + utf8.encode(turn.content).length + 16,
    );
    final worstCaseCost = TextGenerationService.estimateCostCny(
      provider: provider,
      model: model,
      inputTokens: inputUpperBoundTokens,
      outputTokens: maxOutputTokens,
    );
    if (worstCaseCost == null) {
      throw SentenceSplitTuningBudgetExceededV3(
        'V3 调优拒绝调用未核价模型：$provider/$model',
      );
    }
    if (_settledCny + _reservedCny + worstCaseCost > limitCny) {
      throw SentenceSplitTuningBudgetExceededV3(
        'V3 调优下一次调用的最坏费用 ${worstCaseCost.toStringAsFixed(6)} 元'
        '将超过 ${limitCny.toStringAsFixed(2)} 元总预算',
      );
    }
    _reservedCny += worstCaseCost;
    return SentenceSplitTuningReservationV3._(
      budget: this,
      worstCaseCostCny: worstCaseCost,
    );
  }

  Map<String, dynamic> report() => {
        'limitCny': limitCny,
        'settledCny': _settledCny,
        'reservedCny': _reservedCny,
        'remainingCny': remainingCny,
        'remoteCalls': _remoteCalls,
        'cachedCalls': _cachedCalls,
        'failedCalls': _failedCalls,
        'inputTokens': _inputTokens,
        'outputTokens': _outputTokens,
      };

  void _complete(
    SentenceSplitTuningReservationV3 reservation,
    TextGenerationReply reply,
  ) {
    _release(reservation);
    if (reply.source == TextGenerationReplySource.cached ||
        reply.source == TextGenerationReplySource.stored) {
      _cachedCalls += 1;
      return;
    }
    _remoteCalls += 1;
    _inputTokens += reply.usage.inputTokens;
    _outputTokens += reply.usage.outputTokens;
    _settledCny += reply.usage.estimatedCostCny ?? reservation.worstCaseCostCny;
  }

  void _fail(SentenceSplitTuningReservationV3 reservation) {
    _release(reservation);
    _failedCalls += 1;
    // A failed HTTP call can still have consumed provider tokens. Charge the
    // conservative reservation so repeated failures cannot bypass the cap.
    _settledCny += reservation.worstCaseCostCny;
  }

  void _release(SentenceSplitTuningReservationV3 reservation) {
    if (reservation._settled) {
      throw StateError('V3 调优预算预留已结算');
    }
    reservation._settled = true;
    _reservedCny -= reservation.worstCaseCostCny;
    if (_reservedCny.abs() < 1e-12) _reservedCny = 0;
  }
}

class SentenceSplitTuningReservationV3 {
  SentenceSplitTuningReservationV3._({
    required SentenceSplitTuningBudgetV3 budget,
    required this.worstCaseCostCny,
  }) : _budget = budget;

  final SentenceSplitTuningBudgetV3 _budget;
  final double worstCaseCostCny;
  bool _settled = false;

  void complete(TextGenerationReply reply) => _budget._complete(this, reply);

  void fail() => _budget._fail(this);
}
