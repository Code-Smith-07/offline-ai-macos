import { KokoroTTS } from 'kokoro-js';

const KOKORO_REMOTE_PREFIX =
	'https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/';
const KOKORO_LOCAL_PREFIX = `${self.location.origin}/models/kokoro/`;
const nativeFetch = self.fetch.bind(self);

// Kokoro.js hard-codes Hugging Face URLs for both its ONNX weights and voice
// embeddings. Redirect only this model to the copy bundled with Offline AI.
self.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
	const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
	if (url.startsWith(KOKORO_REMOTE_PREFIX)) {
		return nativeFetch(`${KOKORO_LOCAL_PREFIX}${url.slice(KOKORO_REMOTE_PREFIX.length)}`, init);
	}
	return nativeFetch(input, init);
}) as typeof fetch;

let tts;
let isInitialized = false; // Flag to track initialization status
const DEFAULT_MODEL_ID = 'onnx-community/Kokoro-82M-v1.0-ONNX'; // Default model

self.onmessage = async (event) => {
	const { type, payload } = event.data;

	if (type === 'init') {
		let { model_id, dtype } = payload;
		model_id = model_id || DEFAULT_MODEL_ID; // Use default model if none provided

		self.postMessage({ status: 'init:start' });

		try {
			tts = await KokoroTTS.from_pretrained(model_id, {
				dtype,
				// q8 WASM is faster than q8 WebGPU in the packaged browser runtime,
				// and remains consistent across supported macOS releases.
				device: 'wasm'
			});
			isInitialized = true; // Mark as initialized after successful loading
			self.postMessage({ status: 'init:complete' });
		} catch (error) {
			isInitialized = false; // Ensure it's marked as false on failure
			self.postMessage({ status: 'init:error', error: error.message });
		}
	}

	if (type === 'generate') {
		if (!isInitialized || !tts) {
			// Ensure model is initialized
			self.postMessage({ status: 'generate:error', error: 'TTS model not initialized' });
			return;
		}

		const { text, voice } = payload;
		self.postMessage({ status: 'generate:start' });

		try {
			const rawAudio = await tts.generate(text, { voice });
			const blob = await rawAudio.toBlob();
			// Transfer the audio data to the window. The window creates the object
			// URL so WebKit resolves it in the same context as the audio element.
			self.postMessage({ status: 'generate:complete', audioBlob: blob });
		} catch (error) {
			self.postMessage({ status: 'generate:error', error: error.message });
		}
	}

	if (type === 'status') {
		// Respond with the current initialization status
		self.postMessage({ status: 'status:check', initialized: isInitialized });
	}
};
