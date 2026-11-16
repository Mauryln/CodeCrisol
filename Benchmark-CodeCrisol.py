import argparse
import csv
import hashlib
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def question(text):
    return [{"role": "user", "content": text}]


def history(rows):
    records = "".join(
        f"case {index:05d}: read patch test build run branch check file status log.\n"
        for index in range(rows)
    )
    return question(f"El siguiente registro es solo material de prueba.\n{records}\nResponde exactamente LISTO.")


def stream_sample(args, name, messages, max_tokens, cache_prompt):
    messages_json = json.dumps(messages, ensure_ascii=False, separators=(",", ":"))
    sample = {
        "name": name, "started_utc": utc_now(), "cache_prompt": cache_prompt,
        "messages_sha256": hashlib.sha256(messages_json.encode()).hexdigest(),
        "max_tokens": max_tokens, "http_status": None, "completion_id": None,
        "first_event_ms": None, "first_text_ms": None, "last_text_ms": None,
        "client_ms": None, "finish_reason": None, "done": False,
        "prompt_tokens": None, "cached_tokens": None, "completion_tokens": None,
        "total_tokens": None, "output_tok_s_end_to_end": None, "usage": None, "text": "", "error": None,
    }
    body = json.dumps({
        "model": "local", "messages": messages, "max_tokens": max_tokens,
        "cache_prompt": cache_prompt, "stream": True,
        "stream_options": {"include_usage": True},
    }, ensure_ascii=False).encode()
    start = time.perf_counter()

    def elapsed():
        return round((time.perf_counter() - start) * 1000, 1)

    try:
        request = Request(args.base_url + "/chat/completions", body, {"Content-Type": "application/json"})
        with urlopen(request, timeout=args.timeout) as response:
            sample["http_status"] = response.status
            for line in response:
                if not line.startswith(b"data:"):
                    continue
                if sample["first_event_ms"] is None:
                    sample["first_event_ms"] = elapsed()
                data = line[5:].strip()
                if data == b"[DONE]":
                    sample["done"] = True
                    break
                event = json.loads(data)
                if "error" in event:
                    sample["error"] = event["error"]
                    break
                if event.get("id"):
                    sample["completion_id"] = event["id"]
                if usage := event.get("usage"):
                    sample.update(usage=usage, prompt_tokens=usage.get("prompt_tokens"),
                                  cached_tokens=usage.get("prompt_tokens_details", {}).get("cached_tokens"),
                                  completion_tokens=usage.get("completion_tokens"), total_tokens=usage.get("total_tokens"))
                for choice in event.get("choices", []):
                    if fragment := choice.get("delta", {}).get("content"):
                        sample["last_text_ms"] = elapsed()
                        if sample["first_text_ms"] is None:
                            sample["first_text_ms"] = sample["last_text_ms"]
                        sample["text"] += fragment
                    if choice.get("finish_reason"):
                        sample["finish_reason"] = choice["finish_reason"]
            if not sample["error"] and (not sample["done"] or sample["usage"] is None):
                sample["error"] = "SSE terminó sin estadísticas de uso o sin [DONE]."
    except HTTPError as error:
        with error:
            sample.update(http_status=error.code, error=error.read().decode("utf-8", errors="replace"))
    except (OSError, ValueError) as error:
        sample["error"] = str(error)
    sample["client_ms"] = elapsed()
    if sample["completion_tokens"] is not None and sample["client_ms"] > 0:
        sample["output_tok_s_end_to_end"] = round(1000 * sample["completion_tokens"] / sample["client_ms"], 2)
    return sample


def save(report, output):
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output.with_suffix(".json"))
    if report["samples"]:
        fields = [field for field in report["samples"][0] if field not in ("usage", "text")]
        with output.with_suffix(".csv").open("w", encoding="utf-8-sig", newline="") as target:
            writer = csv.DictWriter(target, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(report["samples"])


def benchmark(args, report, output):
    def run(name, messages, max_tokens=16, cache_prompt=False):
        print(f"{utc_now()} {name}…", flush=True)
        sample = stream_sample(args, name, messages, max_tokens, cache_prompt)
        report["samples"].append(sample)
        save(report, output)
        print(f"  HTTP {sample['http_status']} · primer texto {sample['first_text_ms']} ms · "
              f"entrada {sample['prompt_tokens']} · reutilizados {sample['cached_tokens']} · "
              f"salida {sample['completion_tokens']} · total {sample['client_ms']} ms", flush=True)
        if sample["error"]:
            print(f"  {sample['error']}", flush=True)
        return sample

    with urlopen(args.base_url + "/models", timeout=min(args.timeout, 15)) as response:
        report["models"] = json.load(response)
    model = next((model for model in report["models"]["data"] if model.get("id") == "local"), None)
    if model is None or model.get("context_length", 0) < 4096:
        raise ValueError("Carga el modelo local con al menos 4.096 tokens de contexto.")
    context = model["context_length"]
    safe_target = context - 1024
    if args.target_tokens is not None and not 2048 <= args.target_tokens <= safe_target:
        raise ValueError(f"--target-tokens debe estar entre 2048 y {safe_target} para este contexto.")
    target = args.target_tokens if args.target_tokens is not None else min(30_000, context // 2)
    report["target_prompt_tokens"] = target

    short = question("Enumera 30 reglas breves para revisar cambios de software, una por línea.")
    warmup = run("calentamiento", short, max_tokens=128)
    samples = [run(f"corta-{index + 1}", short, max_tokens=128) for index in range(args.repeats)]
    timings = [sample["first_text_ms"] for sample in samples
               if not sample["error"] and sample["first_text_ms"] is not None]
    report["short_median_first_text_ms"] = statistics.median(timings) if timings else None
    if args.short_only:
        return not warmup["error"] and len(timings) == len(samples)

    calibration = run("calibración-historial", history(64))
    count = calibration["prompt_tokens"]
    if not count:
        raise ValueError("La calibración no devolvió el recuento de tokens de entrada.")
    rows = max(64, target * 64 // count)
    seed = history(rows)
    continuation = seed + [{"role": "assistant", "content": "LISTO"}] + question("Responde exactamente LISTO.")
    initial = run("historial", seed, cache_prompt=True)
    if initial["error"]:
        raise ValueError("Falló la petición que prepara la caché del historial.")
    cached = run("continuación-con-caché", continuation, cache_prompt=True)
    cold = run("continuación-sin-caché", continuation)
    report["checks"]["cache"] = {
        "same_prompt_tokens": cached["prompt_tokens"] is not None and cached["prompt_tokens"] == cold["prompt_tokens"],
        "same_answer": all(sample["text"].strip() == "LISTO" for sample in (cached, cold)),
        "reused_prefix": (cached["cached_tokens"] or 0) > 0 if model.get("supports_tools") else None,
        "cold_without_cache": cold["cached_tokens"] == 0,
    }

    if args.check_cancellation:
        print("En el iPad, pulsa Detener generación mientras procesa la entrada. La petición comienza en 5 s.", flush=True)
        time.sleep(5)
        cancelled = run("cancelación", seed, max_tokens=128)
        recovery = run("recuperación", question("Responde exactamente LISTO."))
        report["checks"]["cancellation"] = {
            "reported_cancelled": cancelled["http_status"] == 409 or "cancel" in str(cancelled["error"]).lower(),
            "recovered": recovery["done"] and recovery["text"].strip() == "LISTO",
        }

    checks = [value for suite in report["checks"].values() for value in suite.values() if value is not None]
    errors = [sample for sample in report["samples"] if sample["error"] and sample["name"] != "cancelación"]
    return all(checks) and not errors


def main():
    parser = argparse.ArgumentParser(description="Captura de rendimiento LAN para CodeCrisol desde Windows.")
    parser.add_argument("base_url", help="URL de la API que muestra el iPad, terminada en /v1")
    parser.add_argument("--label", required=True, help="Identifica ajustes, por ejemplo metal-q8-32k-medio")
    parser.add_argument("--output-dir", type=Path, default=Path("capture-codecrisol"))
    parser.add_argument("--target-tokens", type=int, help="Objetivo aproximado del historial, fuera de la reserva de salida")
    parser.add_argument("--repeats", type=int, default=3, help="Mediciones cortas después del calentamiento")
    parser.add_argument("--timeout", type=int, default=1800, help="Espera máxima de una lectura en segundos")
    parser.add_argument("--short-only", action="store_true", help="Limita la captura a las respuestas cortas")
    parser.add_argument("--check-cancellation", action="store_true", help="Incluye cancelación manual desde el iPad y recuperación")
    args = parser.parse_args()
    args.base_url = args.base_url.rstrip("/")
    parsed = urlsplit(args.base_url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.path != "/v1"
            or parsed.query or parsed.fragment or parsed.username is not None):
        parser.error("Usa la URL de la API terminada en /v1.")
    if args.repeats < 1 or args.timeout < 1:
        parser.error("--repeats y --timeout deben ser positivos.")
    if args.short_only and (args.target_tokens is not None or args.check_cancellation):
        parser.error("--short-only excluye --target-tokens y --check-cancellation.")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    label = "".join(char if char.isalnum() or char in "-_" else "-" for char in args.label)[:64]
    output = args.output_dir / f"{stamp}-{label}"
    report = {"started_utc": utc_now(), "url": args.base_url, "label": args.label, "samples": [], "checks": {}}
    try:
        report["passed"] = benchmark(args, report, output)
    except (OSError, ValueError, KeyboardInterrupt) as error:
        report.update(passed=False, error=str(error) or type(error).__name__)
        print(report["error"], flush=True)
    report["finished_utc"] = utc_now()
    save(report, output)
    print(f"JSON: {output.with_suffix('.json').resolve()}")
    if report["samples"]:
        print(f"CSV: {output.with_suffix('.csv').resolve()}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
