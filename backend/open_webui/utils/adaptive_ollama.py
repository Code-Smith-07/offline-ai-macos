from __future__ import annotations

import json
import logging
import re
from collections.abc import AsyncIterator

log = logging.getLogger(__name__)

_HIGH_RISK_NAME_MARKERS = (
    'abliterated',
    'uncensored',
    'dolphin',
    'lexi',
    'q2_',
    'q3_',
)
_REPETITION_NOTICE = '\n\n_[Generation stopped because the model began repeating itself.]_'


def _parameter_size_billions(model: dict) -> float | None:
    raw = str((model.get('details') or {}).get('parameter_size') or '').strip().upper()
    match = re.search(r'(\d+(?:\.\d+)?)\s*([BM])', raw)
    if not match:
        # Some providers omit details from their lightweight model-list API,
        # but still encode the size in a conventional model tag (for example
        # ``qwen:4b-mlx``). Richer /api/show data remains the first choice.
        model_id = str(model.get('model') or model.get('name') or '').upper()
        match = re.search(r'(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*([BM])(?![A-Z])', model_id)
    if not match:
        return None
    value = float(match.group(1))
    return value if match.group(2) == 'B' else value / 1000


def _quantization_bits(model: dict) -> int | None:
    raw = str((model.get('details') or {}).get('quantization_level') or '').upper()
    match = re.search(r'(?:^|[^A-Z0-9])Q(\d+)', raw)
    if not match:
        match = re.search(r'(?:NV|MX)?FP(\d+)', raw)
    return int(match.group(1)) if match else None


def _modelfile_parameter_keys(model: dict) -> set[str]:
    keys: set[str] = set()
    for line in str(model.get('parameters') or '').splitlines():
        line = line.strip()
        if not line:
            continue
        key = line.split(maxsplit=1)[0].lower()
        if key == 'parameter' and len(line.split()) > 1:
            key = line.split()[1].lower()
        keys.add(key)
    return keys


def adaptive_generation_profile(model: dict) -> tuple[str, dict]:
    """Return conservative Ollama defaults derived from model metadata.

    Small, aggressively quantized, or community fine-tuned models are more
    prone to repetition collapse. Larger/base and reasoning models retain more
    room for long answers. These are fallbacks only: caller and Modelfile
    values take precedence in ``apply_adaptive_generation_options``.
    """

    model_id = str(model.get('model') or model.get('name') or '').lower()
    size_b = _parameter_size_billions(model)
    quant_bits = _quantization_bits(model)
    capabilities = set(model.get('capabilities') or [])

    risk = 0
    if size_b is not None and size_b <= 4.5:
        risk += 1
    if quant_bits is not None:
        if quant_bits <= 2:
            risk += 2
        elif quant_bits <= 4:
            risk += 1
    if any(marker in model_id for marker in _HIGH_RISK_NAME_MARKERS):
        risk += 2

    if risk >= 3:
        name = 'high-repetition-risk'
        options = {
            'temperature': 0.6,
            'top_p': 0.9,
            'top_k': 40,
            'repeat_penalty': 1.18,
            'repeat_last_n': 512,
            'num_predict': 1024,
        }
    elif risk >= 1:
        name = 'balanced-small-or-quantized'
        options = {
            'temperature': 0.65,
            'top_p': 0.9,
            'top_k': 40,
            'repeat_penalty': 1.14,
            'repeat_last_n': 384,
            'num_predict': 1536,
        }
    else:
        name = 'balanced-general'
        options = {
            'temperature': 0.7,
            'top_p': 0.9,
            'top_k': 40,
            'repeat_penalty': 1.12,
            'repeat_last_n': 256,
            'num_predict': 2048,
        }

    # Reasoning traces legitimately need more output room. Repetition controls
    # remain active, while the cap is relaxed to avoid clipping useful thought.
    if 'thinking' in capabilities:
        options['num_predict'] = max(options['num_predict'], 2048)
        name += '-thinking'

    return name, options


def apply_adaptive_generation_options(payload: dict, model: dict) -> tuple[dict, str, dict]:
    """Fill missing Ollama options without overriding intentional settings."""

    profile_name, defaults = adaptive_generation_profile(model)
    baked_keys = _modelfile_parameter_keys(model)
    options = dict(payload.get('options') or {})
    applied: dict = {}

    for key, value in defaults.items():
        if (key not in options or options[key] is None) and key not in baked_keys:
            options[key] = value
            applied[key] = value

    if options:
        payload['options'] = options
    return payload, profile_name, applied


def _normalized_repetition_units(text: str) -> list[str]:
    units = re.split(r'\n\s*\n|(?<=[.!?])\s+(?=(?:\d+[.)]|[-*•]|[A-Z]))', text)
    normalized: list[str] = []
    for unit in units:
        unit = re.sub(r'^\s*(?:\d+[.)]|[-*•])\s*', '', unit)
        unit = re.sub(r'[`*_>#]+', '', unit)
        unit = re.sub(r'\s+', ' ', unit).strip().casefold()
        if len(unit) >= 80:
            normalized.append(unit)
    return normalized


def has_repetition_loop(text: str, consecutive_limit: int = 3) -> bool:
    units = _normalized_repetition_units(text)
    if len(units) < consecutive_limit:
        return False
    tail = units[-consecutive_limit:]
    return len(set(tail)) == 1


def trim_repetition_loop(text: str) -> tuple[str, bool]:
    """Trim non-streaming output at the second unit of a detected exact loop."""

    raw_units = list(re.finditer(r'(?s)(?:^|\n\s*\n)(.*?)(?=\n\s*\n|$)', text))
    normalized: list[tuple[str, int]] = []
    for match in raw_units:
        unit = re.sub(r'^\s*(?:\d+[.)]|[-*•])\s*', '', match.group(1))
        unit = re.sub(r'[`*_>#]+', '', unit)
        unit = re.sub(r'\s+', ' ', unit).strip().casefold()
        if len(unit) >= 80:
            normalized.append((unit, match.start(1)))

    for index in range(2, len(normalized)):
        if normalized[index][0] == normalized[index - 1][0] == normalized[index - 2][0]:
            cut_at = normalized[index - 1][1]
            return text[:cut_at].rstrip() + _REPETITION_NOTICE, True
    return text, False


async def guard_ollama_chat_stream(content, model_id: str) -> AsyncIterator[bytes]:
    """Stop an Ollama NDJSON stream after three identical long output units."""

    accumulated = ''
    async for raw_line in content:
        try:
            data = json.loads(raw_line)
            message = data.get('message') or {}
            chunk_text = message.get('content') or ''
        except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
            yield raw_line
            continue

        candidate = accumulated + chunk_text
        if chunk_text and has_repetition_loop(candidate):
            log.warning('Stopped repetitive Ollama generation for model %s', model_id)
            final = {
                **data,
                'message': {
                    'role': 'assistant',
                    'content': _REPETITION_NOTICE,
                },
                'done': True,
                'done_reason': 'repetition',
            }
            yield (json.dumps(final, separators=(',', ':')) + '\n').encode()
            return

        accumulated = candidate
        yield raw_line
