#!/usr/bin/env python3
"""Budget consumption predictor for workqueue tasks.

Estimates how much 5h and 7d budget a task will consume before launching.
Uses historical data when available, falls back to heuristics when sparse.

Usage:
    from _budget_predictor import predict_budget
    prediction = predict_budget(task_dict)
    # Returns: {"five_hour_pct": 12.5, "seven_day_pct": 3.2, "confidence": "low", "method": "heuristic"}

CLI:
    python3 _budget_predictor.py '{"duration_min": 120, "description": "build feature"}'
    python3 _budget_predictor.py --stats   # Show model accuracy stats
"""

import json
import os
import sys
from pathlib import Path

HISTORY_FILE = Path.home() / ".claude/daemon/budget_consumption_history.jsonl"
MIN_SAMPLES_FOR_REGRESSION = 10


def load_history() -> list[dict]:
    """Load budget consumption history."""
    entries = []
    try:
        if HISTORY_FILE.exists():
            for line in HISTORY_FILE.read_text().splitlines():
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except OSError:
        pass
    return entries


def heuristic_predict(task: dict) -> dict:
    """Simple heuristic prediction when historical data is sparse.

    Base rate: ~0.5% of 5h per minute of planned duration.
    This translates to: a 60-min session uses ~30% of 5h window.

    Adjustments:
    - Playwright tasks: +30% (browser automation is token-heavy)
    - Codex review tasks: +20% (cross-model calls have overhead)
    - Parallel agent tasks: +50% (multiple agents burn tokens fast)
    - Pure research/reading: -20% (less output tokens)
    """
    duration = task.get("duration_min", 60)
    description = (task.get("description", "") + " " + task.get("contract", "")).lower()

    # Base rate: 0.5% per minute for 5h
    base_rate_per_min = 0.5
    five_hour_pct = duration * base_rate_per_min

    # Adjustment multipliers
    multiplier = 1.0

    if "playwright" in description or "browser" in description:
        multiplier += 0.3

    if "codex" in description or "cross-model" in description or "review" in description:
        multiplier += 0.2

    if "parallel" in description or "swarm" in description or "team" in description:
        multiplier += 0.5

    if "research" in description or "read" in description or "distill" in description:
        multiplier -= 0.2

    # Apply multiplier (minimum 0.3)
    multiplier = max(0.3, multiplier)
    five_hour_pct *= multiplier

    # 7d is roughly 5h / 33.6 (7 days / 5 hours = 33.6 windows)
    # But it depends on usage pattern. Approximate: 7d impact is ~1/10 of 5h impact
    # since we spread across the week.
    seven_day_pct = five_hour_pct * 0.1

    return {
        "five_hour_pct": round(five_hour_pct, 1),
        "seven_day_pct": round(seven_day_pct, 1),
        "confidence": "low",
        "method": "heuristic",
        "multiplier": round(multiplier, 2),
    }


def regression_predict(task: dict, history: list[dict]) -> dict:
    """Data-driven prediction using historical consumption data.

    Simple weighted average based on similar tasks (by duration bucket).
    """
    duration = task.get("duration_min", 60)

    # Filter to entries with valid budget data
    valid = [
        h for h in history
        if h.get("five_hour_delta") is not None
        and h.get("five_hour_delta", 0) > 0
    ]

    if len(valid) < MIN_SAMPLES_FOR_REGRESSION:
        return heuristic_predict(task)

    # Group by duration bucket (30-min windows)
    bucket_size = 30
    target_bucket = (duration // bucket_size) * bucket_size

    # Find entries in nearby buckets (target ± 1 bucket)
    nearby = [
        h for h in valid
        if abs((h.get("duration_planned_min", 60) or 60) - duration) <= bucket_size
    ]

    if len(nearby) < 3:
        # Not enough nearby data, use all data scaled by duration ratio
        nearby = valid

    # Compute weighted average (more recent = higher weight)
    total_weight = 0
    weighted_five = 0
    weighted_seven = 0

    for i, h in enumerate(nearby):
        weight = 1.0 + (i / len(nearby))  # More recent entries weighted higher
        h_duration = h.get("duration_planned_min", 60) or 60
        scale = duration / max(h_duration, 1)  # Scale by duration ratio

        five_delta = h.get("five_hour_delta", 0) * scale
        seven_delta = h.get("seven_day_delta", 0) * scale

        weighted_five += five_delta * weight
        weighted_seven += seven_delta * weight
        total_weight += weight

    if total_weight == 0:
        return heuristic_predict(task)

    five_pred = weighted_five / total_weight
    seven_pred = weighted_seven / total_weight

    # Confidence based on sample size and variance
    if len(nearby) >= 10:
        confidence = "high"
    elif len(nearby) >= 5:
        confidence = "medium"
    else:
        confidence = "low"

    return {
        "five_hour_pct": round(five_pred, 1),
        "seven_day_pct": round(seven_pred, 1),
        "confidence": confidence,
        "method": "regression",
        "sample_size": len(nearby),
    }


def predict_budget(task: dict) -> dict:
    """Main prediction entry point. Uses best available method."""
    history = load_history()

    if len(history) >= MIN_SAMPLES_FOR_REGRESSION:
        return regression_predict(task, history)
    else:
        result = heuristic_predict(task)
        result["note"] = (
            f"Using heuristics ({len(history)}/{MIN_SAMPLES_FOR_REGRESSION} "
            f"samples collected). Accuracy improves with more data."
        )
        return result


def get_accuracy_stats() -> dict:
    """Compute prediction accuracy from historical data (where predictions were recorded)."""
    history = load_history()

    if not history:
        return {"message": "No data yet. Predictions will improve as sessions complete."}

    entries_with_budget = [
        h for h in history
        if h.get("five_hour_delta") is not None
    ]

    if not entries_with_budget:
        return {
            "total_sessions": len(history),
            "sessions_with_budget_data": 0,
            "message": "Budget data not yet available. Run more sessions.",
        }

    five_deltas = [h["five_hour_delta"] for h in entries_with_budget]
    avg_five = sum(five_deltas) / len(five_deltas)
    max_five = max(five_deltas)
    min_five = min(five_deltas)

    return {
        "total_sessions": len(history),
        "sessions_with_budget_data": len(entries_with_budget),
        "avg_five_hour_consumption": round(avg_five, 1),
        "max_five_hour_consumption": round(max_five, 1),
        "min_five_hour_consumption": round(min_five, 1),
        "model_ready": len(entries_with_budget) >= MIN_SAMPLES_FOR_REGRESSION,
    }


def predict_queue() -> list[dict]:
    """Predict budget for all pending tasks in the workqueue."""
    try:
        import yaml
    except ImportError:
        return [{"error": "pyyaml not installed"}]

    queue_file = Path.home() / ".claude/daemon/workqueue.yaml"
    if not queue_file.exists():
        return []

    with open(queue_file) as f:
        data = yaml.safe_load(f)

    results = []
    for task in data.get("tasks", []):
        if task.get("status") != "pending":
            continue
        prediction = predict_budget(task)
        prediction["task_id"] = task.get("id", "?")
        prediction["duration_min"] = task.get("duration_min", 60)
        prediction["description"] = str(task.get("description", ""))[:80]
        results.append(prediction)

    return results


def calibrate() -> dict:
    """Compare predicted vs actual budget consumption and compute error metrics.

    Returns calibration stats that can be used to adjust model weights.
    """
    history = load_history()
    if not history:
        return {"message": "No history data for calibration."}

    # Find entries that have both planned and actual data
    calibration_pairs = []
    for h in history:
        planned = h.get("duration_planned_min")
        actual_five = h.get("five_hour_delta")
        if planned and actual_five is not None and actual_five > 0:
            # Re-predict what we would have estimated
            predicted = heuristic_predict({"duration_min": planned, "description": h.get("task", "")})
            calibration_pairs.append({
                "predicted_five": predicted["five_hour_pct"],
                "actual_five": actual_five,
                "error": abs(predicted["five_hour_pct"] - actual_five),
                "task": h.get("task", "")[:60],
            })

    if not calibration_pairs:
        return {"message": "No paired prediction/actual data yet.", "pairs": 0}

    errors = [p["error"] for p in calibration_pairs]
    mean_error = sum(errors) / len(errors)

    # Compute adjustment factor: actual / predicted ratio
    ratios = [
        p["actual_five"] / max(p["predicted_five"], 0.1)
        for p in calibration_pairs
    ]
    mean_ratio = sum(ratios) / len(ratios)

    return {
        "pairs": len(calibration_pairs),
        "mean_absolute_error": round(mean_error, 2),
        "adjustment_ratio": round(mean_ratio, 3),
        "suggestion": (
            f"Multiply heuristic base_rate by {mean_ratio:.2f} "
            f"(current: 0.5, suggested: {0.5 * mean_ratio:.3f})"
        ),
        "worst_predictions": sorted(calibration_pairs, key=lambda p: -p["error"])[:3],
    }


def main():
    if "--stats" in sys.argv:
        stats = get_accuracy_stats()
        print(json.dumps(stats, indent=2))
        return

    if "--queue" in sys.argv:
        results = predict_queue()
        print(json.dumps(results, indent=2))
        return

    if "--calibrate" in sys.argv:
        results = calibrate()
        print(json.dumps(results, indent=2))
        return

    # Predict for a task given as JSON argument
    if len(sys.argv) > 1 and sys.argv[1] not in ("--stats", "--queue", "--calibrate"):
        try:
            task = json.loads(sys.argv[1])
        except json.JSONDecodeError:
            # Try as simple description
            task = {"description": sys.argv[1], "duration_min": 60}
    else:
        task = {"description": "generic task", "duration_min": 60}

    prediction = predict_budget(task)
    print(json.dumps(prediction, indent=2))


if __name__ == "__main__":
    main()
