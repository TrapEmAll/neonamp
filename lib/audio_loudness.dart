import 'dart:math' as math;

const defaultLoudnessTargetLufs = -14.0;
const defaultTruePeakCeilingDb = -1.0;

double gainDbToLoudnessTarget(
  double integratedLufs, {
  double targetLufs = defaultLoudnessTargetLufs,
}) {
  if (!integratedLufs.isFinite || !targetLufs.isFinite) return 0;
  return (targetLufs - integratedLufs).clamp(-24.0, 24.0).toDouble();
}

double gainDbToTruePeakCeiling(
  double measuredTruePeakDb, {
  double ceilingDb = defaultTruePeakCeilingDb,
}) {
  if (!measuredTruePeakDb.isFinite || !ceilingDb.isFinite) return 0;
  return math.min(0.0, ceilingDb - measuredTruePeakDb);
}
