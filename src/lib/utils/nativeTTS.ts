type NativeSpeechHandler = {
	postMessage: (message: Record<string, unknown>) => void;
};

declare global {
	interface Window {
		webkit?: {
			messageHandlers?: {
				offlineAI?: NativeSpeechHandler;
			};
		};
	}
}

const NATIVE_TTS_EVENT = 'offline-ai-native-tts';
let requestSequence = 0;

export const isNativeTTSAvailable = () =>
	typeof window !== 'undefined' && Boolean(window.webkit?.messageHandlers?.offlineAI);

export const stopNativeTTS = () => {
	window.webkit?.messageHandlers?.offlineAI?.postMessage({ action: 'stopSpeech' });
};

export const speakNativeTTS = (text: string, playbackRate = 1): Promise<void> => {
	const handler = window.webkit?.messageHandlers?.offlineAI;
	if (!handler) {
		return Promise.reject(new Error('Native macOS speech is unavailable'));
	}

	const requestId = `${Date.now()}-${++requestSequence}`;

	return new Promise((resolve, reject) => {
		const timeout = window.setTimeout(
			() => {
				cleanup();
				reject(new Error('Native macOS speech timed out'));
			},
			Math.max(60_000, text.length * 250)
		);

		const onStatus = (event: Event) => {
			const detail = (event as CustomEvent).detail ?? {};
			if (detail.requestId !== requestId) return;

			if (detail.status === 'finished' || detail.status === 'cancelled') {
				cleanup();
				resolve();
			} else if (detail.status === 'failed') {
				cleanup();
				reject(new Error(detail.message ?? 'Native macOS speech failed'));
			}
		};

		const cleanup = () => {
			window.clearTimeout(timeout);
			window.removeEventListener(NATIVE_TTS_EVENT, onStatus);
		};

		window.addEventListener(NATIVE_TTS_EVENT, onStatus);
		handler.postMessage({
			action: 'speak',
			requestId,
			text,
			playbackRate
		});
	});
};
